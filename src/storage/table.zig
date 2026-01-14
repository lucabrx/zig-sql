const std = @import("std");
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const Column = schema_mod.Column;
const btree_mod = @import("btree.zig");
const Btree = btree_mod.Btree;
const pager_mod = @import("pager.zig");
const Pager = pager_mod.Pager;
const PAGE_SIZE = pager_mod.PAGE_SIZE;
const row_mod = @import("row.zig");
const DynamicRow = row_mod.DynamicRow;
const RowValue = row_mod.RowValue;
const Cursor = @import("cursor.zig").Cursor;
const StorageError = @import("errors.zig").StorageError;
const IndexBtree = @import("index_btree.zig").IndexBtree;
const index_btree = @import("index_btree.zig");
const Transaction = @import("transaction.zig").Transaction;
const Wal = @import("wal.zig").Wal;
const Catalog = @import("catalog.zig").Catalog;

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
    transaction: Transaction,
    wal: ?*Wal,
    db_filename: []const u8,
    catalog: ?Catalog,

    const MAGIC: *const [4]u8 = "ZSQL";
    const VERSION: u32 = 1;
    const CATALOG_PAGE: u32 = 1;

    pub fn init(allocator: std.mem.Allocator, pager: *Pager) !Database {
        return try initWithFilename(allocator, pager, ":memory:");
    }

    pub fn initWithFilename(allocator: std.mem.Allocator, pager: *Pager, filename: []const u8) !Database {
        var wal: ?*Wal = null;
        const is_file_db = !std.mem.eql(u8, filename, ":memory:");
        if (is_file_db) {
            const wal_ptr = try allocator.create(Wal);
            wal_ptr.* = try Wal.init(allocator, filename);
            wal = wal_ptr;
        }

        var db = Database{
            .pager = pager,
            .tables = std.StringHashMap(*Table).init(allocator),
            .indexes = std.StringHashMap(*schema_mod.IndexDef).init(allocator),
            .index_btrees = std.StringHashMap(*IndexBtree).init(allocator),
            .next_page = 2,
            .allocator = allocator,
            .transaction = Transaction.init(allocator, pager),
            .wal = wal,
            .db_filename = filename,
            .catalog = if (is_file_db) Catalog.init(allocator, pager, CATALOG_PAGE) else null,
        };

        if (wal) |w| {
            const recovered = try w.recover(pager);
            if (recovered > 0) {
                print("[DB] Recovered {} pages from WAL\n", .{recovered});
            }
        }

        if (pager.num_pages > 0) {
            try db.load_metadata();
            if (db.catalog) |*cat| {
                try db.load_from_catalog(cat);
            }
        } else {
            try db.init_metadata();
        }

        return db;
    }

    fn load_from_catalog(self: *Database, cat: *Catalog) !void {
        const data = try cat.load_schemas();
        defer self.allocator.free(data.tables);
        defer self.allocator.free(data.indexes);

        for (data.tables) |table_info| {
            const table_ptr = try self.allocator.create(Table);
            table_ptr.* = Table.init(self.pager, table_info.schema, table_info.root_page);
            const owned_name = try self.allocator.dupe(u8, table_info.schema.table_name);
            try self.tables.put(owned_name, table_ptr);
        }

        for (data.indexes) |idx_info| {
            defer {
                self.allocator.free(idx_info.name);
                self.allocator.free(idx_info.table);
                for (idx_info.columns) |col| {
                    self.allocator.free(col);
                }
                self.allocator.free(idx_info.columns);
            }

            const index_def = try self.allocator.create(schema_mod.IndexDef);
            index_def.* = schema_mod.IndexDef{
                .name = try self.allocator.dupe(u8, idx_info.name),
                .table = try self.allocator.dupe(u8, idx_info.table),
                .columns = blk: {
                    var cols = try self.allocator.alloc([]const u8, idx_info.columns.len);
                    for (idx_info.columns, 0..) |col, i| {
                        cols[i] = try self.allocator.dupe(u8, col);
                    }
                    break :blk cols;
                },
                .unique = idx_info.unique,
                .root_page = idx_info.root_page,
                .column_indices = &[_]usize{},
            };

            if (self.tables.get(idx_info.table)) |table| {
                const col_indices = try self.allocator.alloc(usize, index_def.columns.len);
                for (index_def.columns, 0..) |col_name, i| {
                    col_indices[i] = try table.schema.get_column_index(col_name);
                }
                index_def.column_indices = col_indices;
            }

            const idx_btree = try self.allocator.create(IndexBtree);
            idx_btree.* = IndexBtree.init(self.pager, idx_info.root_page);

            const owned_idx_name = try self.allocator.dupe(u8, idx_info.name);
            try self.indexes.put(owned_idx_name, index_def);
            try self.index_btrees.put(owned_idx_name, idx_btree);
        }
    }

    fn init_metadata(self: *Database) !void {
        const page = try self.pager.get_page(0);
        @memcpy(page.data[0..4], MAGIC);
        std.mem.writeInt(u32, page.data[4..8], VERSION, .little);
        std.mem.writeInt(u32, page.data[8..12], 0, .little);
        std.mem.writeInt(u32, page.data[12..16], 2, .little);
        self.pager.mark_dirty(0);

        _ = try self.pager.get_page(CATALOG_PAGE);
        self.pager.mark_dirty(CATALOG_PAGE);

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
        try self.save_catalog();

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
        try self.save_catalog();
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
        try self.save_catalog();

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
        try self.save_catalog();
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
        if (self.wal) |w| {
            try w.log_page_write(0, &page.data);
        }
    }

    fn save_catalog(self: *Database) !void {
        if (self.catalog) |*cat| {
            try cat.save_schemas(&self.tables, &self.indexes);
            if (self.wal) |w| {
                const page = try self.pager.get_page(CATALOG_PAGE);
                try w.log_page_write(CATALOG_PAGE, &page.data);
            }
        }
    }

    pub fn wal_log_page(self: *Database, page_num: u32) !void {
        if (self.wal) |w| {
            const page = try self.pager.get_page(page_num);
            try w.log_page_write(page_num, &page.data);
        }
    }

    pub fn wal_commit(self: *Database) !void {
        if (self.wal) |w| {
            try w.log_commit();
        }
    }

    pub fn wal_checkpoint(self: *Database) !void {
        if (self.wal) |w| {
            try w.checkpoint(self.pager);
        }
    }

    pub fn alter_add_column(self: *Database, table_name: []const u8, col: schema_mod.Column) !void {
        const table = try self.get_table(table_name);
        const old_schema = table.schema;

        var new_columns = try self.allocator.alloc(schema_mod.Column, old_schema.columns.len + 1);
        for (old_schema.columns, 0..) |old_col, i| {
            new_columns[i] = old_col;
        }
        new_columns[old_schema.columns.len] = schema_mod.Column{
            .name = try self.allocator.dupe(u8, col.name),
            .type = col.type,
            .primary_key = col.primary_key,
            .not_null = col.not_null,
        };

        const new_schema = try self.allocator.create(Schema);
        new_schema.* = Schema.init(old_schema.table_name, new_columns);

        self.allocator.free(old_schema.columns);
        self.allocator.destroy(@constCast(old_schema));

        table.schema = new_schema;
        try self.save_catalog();
    }

    pub fn alter_drop_column(self: *Database, table_name: []const u8, col_name: []const u8) !void {
        const table = try self.get_table(table_name);
        const old_schema = table.schema;

        var col_idx: ?usize = null;
        for (old_schema.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, col_name)) {
                col_idx = i;
                break;
            }
        }
        if (col_idx == null) return StorageError.ColumnNotFound;

        if (old_schema.columns.len <= 1) return;

        var new_columns = try self.allocator.alloc(schema_mod.Column, old_schema.columns.len - 1);
        var j: usize = 0;
        for (old_schema.columns, 0..) |col, i| {
            if (i == col_idx.?) {
                self.allocator.free(col.name);
                continue;
            }
            new_columns[j] = col;
            j += 1;
        }

        const new_schema = try self.allocator.create(Schema);
        new_schema.* = Schema.init(old_schema.table_name, new_columns);

        self.allocator.free(old_schema.columns);
        self.allocator.destroy(@constCast(old_schema));

        table.schema = new_schema;
        try self.save_catalog();
    }

    pub fn alter_rename_table(self: *Database, old_name: []const u8, new_name: []const u8) !void {
        const kv = self.tables.fetchRemove(old_name) orelse return StorageError.TableNotFound;
        const table = kv.value;

        const owned_new_name = try self.allocator.dupe(u8, new_name);
        self.allocator.free(table.schema.table_name);

        const new_schema = try self.allocator.create(Schema);
        new_schema.* = Schema.init(owned_new_name, table.schema.columns);
        self.allocator.destroy(@constCast(table.schema));
        table.schema = new_schema;

        self.allocator.free(kv.key);
        try self.tables.put(owned_new_name, table);
        try self.save_catalog();
    }

    pub fn alter_rename_column(self: *Database, table_name: []const u8, old_col_name: []const u8, new_col_name: []const u8) !void {
        const table = try self.get_table(table_name);

        for (table.schema.columns) |*col| {
            if (std.mem.eql(u8, col.name, old_col_name)) {
                self.allocator.free(col.name);
                col.name = try self.allocator.dupe(u8, new_col_name);
                break;
            }
        }
        try self.save_catalog();
    }

    pub fn close(self: *Database) void {
        self.save_metadata() catch {};

        if (self.wal) |w| {
            w.checkpoint(self.pager) catch {};
            w.deinit();
            self.allocator.destroy(w);
        }

        self.transaction.deinit();

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
