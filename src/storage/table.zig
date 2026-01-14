const std = @import("std");
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const btree_mod = @import("btree.zig");
const Btree = btree_mod.Btree;
const pager_mod = @import("pager.zig");
const Pager = pager_mod.Pager;
const row_mod = @import("row.zig");
const DynamicRow = row_mod.DynamicRow;
const RowValue = row_mod.RowValue;
const Cursor = @import("cursor.zig").Cursor;
const StorageError = @import("errors.zig").StorageError;
const IndexBtree = @import("index_btree.zig").IndexBtree;
const index_btree = @import("index_btree.zig");

const print = std.debug.print;

pub const Table = struct {
    schema: *const Schema,
    root_page: u32,
    btree: Btree,
    pager: *Pager,

    pub fn init(pager: *Pager, s: *const Schema, root_page: u32) Table {
        var btree = Btree.init(pager, root_page);
        btree.set_schema(s);
        return Table{
            .schema = s,
            .root_page = root_page,
            .pager = pager,
            .btree = btree,
        };
    }

    pub fn initialize(self: *Table) !void {
        try self.btree.initialize();
    }

    pub fn insert(self: *Table, key: u32, r: *const DynamicRow) !void {
        try self.btree.insert(key, r);
    }

    pub fn select_all(self: *Table) !Cursor {
        return try Cursor.new_cursor_start(&self.btree);
    }

    pub fn select_end(self: *Table) !Cursor {
        return try Cursor.new_cursor_end(&self.btree);
    }

    pub fn search(self: *Table, key: u32) !Cursor {
        return try self.btree.search(key);
    }

    pub fn print_tree(self: *Table) !void {
        try self.btree.print_tree();
    }

    pub fn debug(self: *Table) void {
        print("[TABLE] name={s}, root_page={}\n", .{ self.schema.table_name, self.root_page });
    }

    pub fn get_row_value_for_index(self: *Table, r: *const DynamicRow, col_idx: usize) RowValue {
        return r.get_value(self.schema, col_idx);
    }
};

pub const Database = struct {
    pager: *Pager,
    tables: std.StringHashMap(*Table),
    indexes: std.StringHashMap(*schema_mod.IndexDef),
    index_btrees: std.StringHashMap(*IndexBtree),
    next_page: u32,
    allocator: std.mem.Allocator,

    const MAGIC: *const [4]u8 = "ZSQL";
    const VERSION: u32 = 1;

    pub fn init(allocator: std.mem.Allocator, pager: *Pager) !Database {
        var db = Database{
            .pager = pager,
            .tables = std.StringHashMap(*Table).init(allocator),
            .indexes = std.StringHashMap(*schema_mod.IndexDef).init(allocator),
            .index_btrees = std.StringHashMap(*IndexBtree).init(allocator),
            .next_page = 1,
            .allocator = allocator,
        };

        if (pager.num_pages > 0) {
            try db.load_metadata();
        } else {
            try db.init_metadata();
        }

        return db;
    }

    fn init_metadata(self: *Database) !void {
        const page = try self.pager.get_page(0);
        @memcpy(page.data[0..4], MAGIC);
        std.mem.writeInt(u32, page.data[4..8], VERSION, .little);
        std.mem.writeInt(u32, page.data[8..12], 0, .little);
        std.mem.writeInt(u32, page.data[12..16], 1, .little);
        self.pager.mark_dirty(0);
        print("[DB] Initialized metadata page\n", .{});
    }

    fn load_metadata(self: *Database) !void {
        const page = try self.pager.get_page(0);
        if (!std.mem.eql(u8, page.data[0..4], MAGIC)) {
            return StorageError.InvalidDatabaseFile;
        }
        self.next_page = std.mem.readInt(u32, page.data[12..16], .little);
        print("[DB] Loaded metadata, next page: {}\n", .{self.next_page});
    }

    pub fn create_table(self: *Database, s: *const Schema) !*Table {
        const owned_name = try self.allocator.dupe(u8, s.table_name);
        errdefer self.allocator.free(owned_name);

        if (self.tables.contains(owned_name)) {
            self.allocator.free(owned_name);
            return StorageError.TableAlreadyExists;
        }

        const root_page = self.next_page;
        self.next_page += 1;

        const table_ptr = try self.allocator.create(Table);
        table_ptr.* = Table.init(self.pager, s, root_page);
        try table_ptr.initialize();

        try self.tables.put(owned_name, table_ptr);
        try self.save_metadata();

        print("[DB] Created table '{s}' at page {}\n", .{ owned_name, root_page });
        return table_ptr;
    }

    pub fn get_table(self: *Database, name: []const u8) !*Table {
        return self.tables.get(name) orelse StorageError.TableNotFound;
    }

    pub fn drop_table(self: *Database, name: []const u8) !void {
        const kv = self.tables.fetchRemove(name) orelse return StorageError.TableNotFound;
        const table = kv.value;

        const schema = table.schema;
        for (schema.columns) |col| {
            self.allocator.free(col.name);
        }
        self.allocator.free(schema.columns);
        self.allocator.free(schema.table_name);
        self.allocator.destroy(@constCast(schema));

        self.allocator.destroy(table);
        self.allocator.free(kv.key);
        print("[DB] Dropped table '{s}'\n", .{name});
    }

    pub fn list_tables(self: *Database) ![][]const u8 {
        var names = std.ArrayList([]const u8){};
        var iter = self.tables.keyIterator();
        while (iter.next()) |key| {
            try names.append(self.allocator, key.*);
        }
        return try names.toOwnedSlice(self.allocator);
    }

    pub fn create_index(self: *Database, index_def: *schema_mod.IndexDef) !void {
        const owned_name = try self.allocator.dupe(u8, index_def.name);
        errdefer self.allocator.free(owned_name);

        if (self.indexes.contains(owned_name)) {
            self.allocator.free(owned_name);
            return StorageError.IndexAlreadyExists;
        }

        const table = try self.get_table(index_def.table);

        const col_indices = try self.allocator.alloc(usize, index_def.columns.len);
        for (index_def.columns, 0..) |col_name, i| {
            col_indices[i] = try table.schema.get_column_index(col_name);
        }
        index_def.column_indices = col_indices;

        const root_page = self.next_page;
        self.next_page += 1;
        index_def.root_page = root_page;

        const idx_btree = try self.allocator.create(IndexBtree);
        idx_btree.* = IndexBtree.init(self.pager, root_page);
        _ = try self.pager.get_page(root_page);
        try idx_btree.initialize();

        try self.indexes.put(owned_name, index_def);
        try self.index_btrees.put(owned_name, idx_btree);
        try self.save_metadata();

        print("[DB] Created index '{s}' on table '{s}' at page {}\n", .{ owned_name, index_def.table, root_page });
    }

    pub fn get_index(self: *Database, name: []const u8) !*schema_mod.IndexDef {
        return self.indexes.get(name) orelse StorageError.IndexNotFound;
    }

    pub fn list_indexes(self: *Database) ![][]const u8 {
        var names = std.ArrayList([]const u8){};
        var iter = self.indexes.keyIterator();
        while (iter.next()) |key| {
            try names.append(self.allocator, key.*);
        }
        return try names.toOwnedSlice(self.allocator);
    }

    pub fn drop_index(self: *Database, name: []const u8) !void {
        const kv = self.indexes.fetchRemove(name) orelse return StorageError.IndexNotFound;
        const index_def = kv.value;

        if (self.index_btrees.fetchRemove(name)) |btree_kv| {
            self.allocator.destroy(btree_kv.value);
        }

        self.allocator.free(index_def.name);
        self.allocator.free(index_def.table);
        for (index_def.columns) |col| {
            self.allocator.free(col);
        }
        self.allocator.free(index_def.columns);
        if (index_def.column_indices.len > 0) {
            self.allocator.free(index_def.column_indices);
        }
        self.allocator.destroy(index_def);
        self.allocator.free(kv.key);
        print("[DB] Dropped index '{s}'\n", .{name});
    }

    pub fn insert_into_indexes(self: *Database, table_name: []const u8, rowid: u32, row: *const DynamicRow) !void {
        const table = try self.get_table(table_name);

        var idx_iter = self.indexes.iterator();
        while (idx_iter.next()) |entry| {
            const index_def = entry.value_ptr.*;
            if (!std.mem.eql(u8, index_def.table, table_name)) continue;

            const idx_btree = self.index_btrees.get(entry.key_ptr.*) orelse continue;

            const key_hash = compute_index_hash(row, table.schema, index_def.column_indices);

            if (index_def.unique) {
                if (try idx_btree.contains(key_hash)) {
                    return StorageError.UniqueConstraintViolation;
                }
            }

            try idx_btree.insert(key_hash, rowid);
        }
    }

    pub fn delete_from_indexes(self: *Database, table_name: []const u8, rowid: u32, row: *const DynamicRow) !void {
        const table = try self.get_table(table_name);

        var idx_iter = self.indexes.iterator();
        while (idx_iter.next()) |entry| {
            const index_def = entry.value_ptr.*;
            if (!std.mem.eql(u8, index_def.table, table_name)) continue;

            const idx_btree = self.index_btrees.get(entry.key_ptr.*) orelse continue;

            const key_hash = compute_index_hash(row, table.schema, index_def.column_indices);
            try idx_btree.delete(key_hash, rowid);
        }
    }

    pub fn find_by_index(self: *Database, index_name: []const u8, value_hash: u32, results: *std.ArrayList(u32)) !void {
        const idx_btree = self.index_btrees.get(index_name) orelse return StorageError.IndexNotFound;
        try idx_btree.find(value_hash, self.allocator, results);
    }

    pub fn get_index_btree(self: *Database, index_name: []const u8) !*IndexBtree {
        return self.index_btrees.get(index_name) orelse StorageError.IndexNotFound;
    }

    fn save_metadata(self: *Database) !void {
        const page = try self.pager.get_page(0);
        std.mem.writeInt(u32, page.data[12..16], self.next_page, .little);
        std.mem.writeInt(u32, page.data[8..12], @intCast(self.tables.count()), .little);
        self.pager.mark_dirty(0);
    }

    pub fn close(self: *Database) void {
        self.save_metadata() catch {};

        var iter = self.tables.iterator();
        while (iter.next()) |entry| {
            const table = entry.value_ptr.*;
            const schema = table.schema;
            for (schema.columns) |col| {
                self.allocator.free(col.name);
            }
            self.allocator.free(schema.columns);
            self.allocator.free(schema.table_name);
            self.allocator.destroy(@constCast(schema));

            self.allocator.destroy(table);
            self.allocator.free(entry.key_ptr.*);
        }
        self.tables.deinit();

        var idx_iter = self.indexes.iterator();
        while (idx_iter.next()) |entry| {
            const index_def = entry.value_ptr.*;
            self.allocator.free(index_def.name);
            self.allocator.free(index_def.table);
            for (index_def.columns) |col| {
                self.allocator.free(col);
            }
            self.allocator.free(index_def.columns);
            if (index_def.column_indices.len > 0) {
                self.allocator.free(index_def.column_indices);
            }
            self.allocator.destroy(index_def);
            self.allocator.free(entry.key_ptr.*);
        }
        self.indexes.deinit();

        var btree_iter = self.index_btrees.iterator();
        while (btree_iter.next()) |entry| {
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.index_btrees.deinit();
    }

    pub fn debug(self: *Database) void {
        print("[DB] tables={}, next_page={}\n", .{ self.tables.count(), self.next_page });
    }
};

test "table initialization" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    var columns = [_]schema_mod.Column{
        .{ .name = "id", .type = .Integer, .primary_key = true, .not_null = true },
    };
    const s = Schema.init("test", &columns);

    var table = Table.init(&pager, &s, 0);
    try table.initialize();

    try std.testing.expectEqual(@as(u32, 0), table.root_page);
    try std.testing.expectEqualStrings("test", table.schema.table_name);
}

fn compute_index_hash(row: *const DynamicRow, schema: *const Schema, col_indices: []const usize) u32 {
    var hash: u32 = 0;
    for (col_indices) |col_idx| {
        const val = row.get_value(schema, col_idx);
        const val_hash: u32 = switch (val) {
            .integer => |v| index_btree.hash_int(v),
            .real => |v| index_btree.hash_float(v),
            .text => |v| index_btree.hash_bytes(v),
            .blob => |v| index_btree.hash_bytes(v),
            .boolean => |v| if (v) @as(u32, 1) else @as(u32, 0),
            .null_val => 0,
        };
        hash = hash *% 31 +% val_hash;
    }
    return hash;
}
