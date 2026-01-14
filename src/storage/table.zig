const std = @import("std");
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const btree_mod = @import("btree.zig");
const Btree = btree_mod.Btree;
const pager_mod = @import("pager.zig");
const Pager = pager_mod.Pager;
const row_mod = @import("row.zig");
const DynamicRow = row_mod.DynamicRow;
const Cursor = @import("cursor.zig").Cursor;
const StorageError = @import("errors.zig").StorageError;

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
};

pub const Database = struct {
    pager: *Pager,
    tables: std.StringHashMap(*Table),
    next_page: u32,
    allocator: std.mem.Allocator,

    const MAGIC: *const [4]u8 = "ZSQL";
    const VERSION: u32 = 1;

    pub fn init(allocator: std.mem.Allocator, pager: *Pager) !Database {
        var db = Database{
            .pager = pager,
            .tables = std.StringHashMap(*Table).init(allocator),
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
            // Free schema data
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
