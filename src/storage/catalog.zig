const std = @import("std");
const Pager = @import("pager.zig").Pager;
const PAGE_SIZE = @import("pager.zig").PAGE_SIZE;
const Schema = @import("schema.zig").Schema;
const Column = @import("schema.zig").Column;
const Type = @import("schema.zig").Type;
const IndexDef = @import("schema.zig").IndexDef;

const print = std.debug.print;

const CATALOG_MAGIC: *const [4]u8 = "ZCAT";
const CATALOG_VERSION: u32 = 1;

pub const Catalog = struct {
    allocator: std.mem.Allocator,
    pager: *Pager,
    catalog_page: u32,

    pub fn init(allocator: std.mem.Allocator, pager: *Pager, catalog_page: u32) Catalog {
        return Catalog{
            .allocator = allocator,
            .pager = pager,
            .catalog_page = catalog_page,
        };
    }

    pub fn save_schemas(
        self: *Catalog,
        tables: *std.StringHashMap(*@import("table.zig").Table),
        indexes: *std.StringHashMap(*IndexDef),
    ) !void {
        const page = try self.pager.get_page(self.catalog_page);
        var offset: usize = 0;

        @memcpy(page.data[offset..][0..4], CATALOG_MAGIC);
        offset += 4;

        std.mem.writeInt(u32, page.data[offset..][0..4], CATALOG_VERSION, .little);
        offset += 4;

        const table_count: u32 = @intCast(tables.count());
        std.mem.writeInt(u32, page.data[offset..][0..4], table_count, .little);
        offset += 4;

        const index_count: u32 = @intCast(indexes.count());
        std.mem.writeInt(u32, page.data[offset..][0..4], index_count, .little);
        offset += 4;

        var table_iter = tables.iterator();
        while (table_iter.next()) |entry| {
            const table = entry.value_ptr.*;
            offset = try self.serialize_schema(page.data[0..PAGE_SIZE], offset, table.schema, table.root_page);
        }

        var idx_iter = indexes.iterator();
        while (idx_iter.next()) |entry| {
            const index_def = entry.value_ptr.*;
            offset = try self.serialize_index(page.data[0..PAGE_SIZE], offset, index_def);
        }

        self.pager.mark_dirty(self.catalog_page);
        print("[CATALOG] Saved {} tables, {} indexes\n", .{ table_count, index_count });
    }

    fn serialize_schema(self: *Catalog, data: *[PAGE_SIZE]u8, start: usize, schema: *const Schema, root_page: u32) !usize {
        _ = self;
        var offset = start;

        if (offset + 256 > PAGE_SIZE) return error.CatalogPageFull;

        std.mem.writeInt(u32, data[offset..][0..4], root_page, .little);
        offset += 4;

        const name_len: u8 = @intCast(@min(schema.table_name.len, 63));
        data[offset] = name_len;
        offset += 1;
        @memcpy(data[offset..][0..name_len], schema.table_name[0..name_len]);
        offset += name_len;

        const col_count: u8 = @intCast(@min(schema.columns.len, 32));
        data[offset] = col_count;
        offset += 1;

        for (schema.columns[0..col_count]) |col| {
            const col_name_len: u8 = @intCast(@min(col.name.len, 63));
            data[offset] = col_name_len;
            offset += 1;
            @memcpy(data[offset..][0..col_name_len], col.name[0..col_name_len]);
            offset += col_name_len;

            data[offset] = @intFromEnum(col.type);
            offset += 1;

            var flags: u8 = 0;
            if (col.primary_key) flags |= 1;
            if (col.not_null) flags |= 2;
            data[offset] = flags;
            offset += 1;
        }

        return offset;
    }

    fn serialize_index(self: *Catalog, data: *[PAGE_SIZE]u8, start: usize, index_def: *const IndexDef) !usize {
        _ = self;
        var offset = start;

        if (offset + 256 > PAGE_SIZE) return error.CatalogPageFull;

        std.mem.writeInt(u32, data[offset..][0..4], index_def.root_page, .little);
        offset += 4;

        data[offset] = if (index_def.unique) 1 else 0;
        offset += 1;

        const name_len: u8 = @intCast(@min(index_def.name.len, 63));
        data[offset] = name_len;
        offset += 1;
        @memcpy(data[offset..][0..name_len], index_def.name[0..name_len]);
        offset += name_len;

        const table_len: u8 = @intCast(@min(index_def.table.len, 63));
        data[offset] = table_len;
        offset += 1;
        @memcpy(data[offset..][0..table_len], index_def.table[0..table_len]);
        offset += table_len;

        const col_count: u8 = @intCast(@min(index_def.columns.len, 16));
        data[offset] = col_count;
        offset += 1;

        for (index_def.columns[0..col_count]) |col_name| {
            const col_name_len: u8 = @intCast(@min(col_name.len, 63));
            data[offset] = col_name_len;
            offset += 1;
            @memcpy(data[offset..][0..col_name_len], col_name[0..col_name_len]);
            offset += col_name_len;
        }

        return offset;
    }

    pub fn load_schemas(self: *Catalog) !CatalogData {
        const page = try self.pager.get_page(self.catalog_page);
        var offset: usize = 0;

        if (!std.mem.eql(u8, page.data[offset..][0..4], CATALOG_MAGIC)) {
            return CatalogData{
                .tables = &[_]TableInfo{},
                .indexes = &[_]IndexInfo{},
            };
        }
        offset += 4;

        const version = std.mem.readInt(u32, page.data[offset..][0..4], .little);
        if (version != CATALOG_VERSION) {
            return error.UnsupportedCatalogVersion;
        }
        offset += 4;

        const table_count = std.mem.readInt(u32, page.data[offset..][0..4], .little);
        offset += 4;

        const index_count = std.mem.readInt(u32, page.data[offset..][0..4], .little);
        offset += 4;

        var tables = try self.allocator.alloc(TableInfo, table_count);
        for (0..table_count) |i| {
            const result = try self.deserialize_schema(page.data[0..PAGE_SIZE], offset);
            tables[i] = result.info;
            offset = result.new_offset;
        }

        var indexes = try self.allocator.alloc(IndexInfo, index_count);
        for (0..index_count) |i| {
            const result = try self.deserialize_index(page.data[0..PAGE_SIZE], offset);
            indexes[i] = result.info;
            offset = result.new_offset;
        }

        print("[CATALOG] Loaded {} tables, {} indexes\n", .{ table_count, index_count });

        return CatalogData{
            .tables = tables,
            .indexes = indexes,
        };
    }

    fn deserialize_schema(self: *Catalog, data: *const [PAGE_SIZE]u8, start: usize) !struct { info: TableInfo, new_offset: usize } {
        var offset = start;

        const root_page = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        const name_len = data[offset];
        offset += 1;
        const table_name = try self.allocator.dupe(u8, data[offset..][0..name_len]);
        offset += name_len;

        const col_count = data[offset];
        offset += 1;

        var columns = try self.allocator.alloc(Column, col_count);
        for (0..col_count) |i| {
            const col_name_len = data[offset];
            offset += 1;
            const col_name = try self.allocator.dupe(u8, data[offset..][0..col_name_len]);
            offset += col_name_len;

            const col_type: Type = @enumFromInt(data[offset]);
            offset += 1;

            const flags = data[offset];
            offset += 1;

            columns[i] = Column{
                .name = col_name,
                .type = col_type,
                .primary_key = (flags & 1) != 0,
                .not_null = (flags & 2) != 0,
            };
        }

        const schema = try self.allocator.create(Schema);
        schema.* = Schema.init(table_name, columns);

        return .{
            .info = TableInfo{
                .schema = schema,
                .root_page = root_page,
            },
            .new_offset = offset,
        };
    }

    fn deserialize_index(self: *Catalog, data: *const [PAGE_SIZE]u8, start: usize) !struct { info: IndexInfo, new_offset: usize } {
        var offset = start;

        const root_page = std.mem.readInt(u32, data[offset..][0..4], .little);
        offset += 4;

        const unique = data[offset] != 0;
        offset += 1;

        const name_len = data[offset];
        offset += 1;
        const name = try self.allocator.dupe(u8, data[offset..][0..name_len]);
        offset += name_len;

        const table_len = data[offset];
        offset += 1;
        const table = try self.allocator.dupe(u8, data[offset..][0..table_len]);
        offset += table_len;

        const col_count = data[offset];
        offset += 1;

        var columns = try self.allocator.alloc([]const u8, col_count);
        for (0..col_count) |i| {
            const col_name_len = data[offset];
            offset += 1;
            columns[i] = try self.allocator.dupe(u8, data[offset..][0..col_name_len]);
            offset += col_name_len;
        }

        return .{
            .info = IndexInfo{
                .name = name,
                .table = table,
                .columns = columns,
                .unique = unique,
                .root_page = root_page,
            },
            .new_offset = offset,
        };
    }
};

pub const TableInfo = struct {
    schema: *Schema,
    root_page: u32,
};

pub const IndexInfo = struct {
    name: []const u8,
    table: []const u8,
    columns: []const []const u8,
    unique: bool,
    root_page: u32,
};

pub const CatalogData = struct {
    tables: []TableInfo,
    indexes: []IndexInfo,
};
