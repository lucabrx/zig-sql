const std = @import("std");
const Page = @import("pager.zig").Page;
const node = @import("node.zig");
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const Type = schema_mod.Type;

pub const PAGE_SIZE = @import("pager.zig").PAGE_SIZE;

pub const MAX_ROW_SIZE: usize = 1024;
pub const TEXT_MAX_SIZE: usize = 256;
pub const BLOB_MAX_SIZE: usize = 512;

pub const LEAF_KEY_SIZE: usize = 4;
pub const LEAF_VALUE_SIZE: usize = MAX_ROW_SIZE;
pub const LEAF_CELL_SIZE: usize = LEAF_KEY_SIZE + LEAF_VALUE_SIZE;

const print = std.debug.print;

pub const RowValue = union(enum) {
    integer: i64,
    real: f64,
    text: []const u8,
    blob: []const u8,
    boolean: bool,
    null_val: void,

    pub fn is_null(self: RowValue) bool {
        return self == .null_val;
    }
};

pub const DynamicRow = struct {
    data: [MAX_ROW_SIZE]u8,
    size: usize,

    pub fn init() DynamicRow {
        return DynamicRow{
            .data = std.mem.zeroes([MAX_ROW_SIZE]u8),
            .size = 0,
        };
    }

    pub fn serialize_values(self: *DynamicRow, schema: *const Schema, values: []const RowValue) !void {
        var offset: usize = 0;
        for (schema.columns, 0..) |col, i| {
            const val = if (i < values.len) values[i] else RowValue{ .null_val = {} };
            self.data[offset] = if (val.is_null()) 1 else 0;
            offset += 1;

            if (!val.is_null()) {
                switch (col.type) {
                    .Integer, .Date, .Time, .Datetime => {
                        const int_val = switch (val) {
                            .integer => |v| v,
                            else => 0,
                        };
                        std.mem.writeInt(i64, self.data[offset..][0..8], int_val, .little);
                        offset += 8;
                    },
                    .Real => {
                        const real_val = switch (val) {
                            .real => |v| v,
                            .integer => |v| @as(f64, @floatFromInt(v)),
                            else => 0.0,
                        };
                        @memcpy(self.data[offset..][0..8], std.mem.asBytes(&real_val));
                        offset += 8;
                    },
                    .Text => {
                        const text_val = switch (val) {
                            .text => |v| v,
                            else => "",
                        };
                        const len: u32 = @intCast(@min(text_val.len, TEXT_MAX_SIZE));
                        std.mem.writeInt(u32, self.data[offset..][0..4], len, .little);
                        offset += 4;
                        if (len > 0) @memcpy(self.data[offset .. offset + len], text_val[0..len]);
                        offset += TEXT_MAX_SIZE;
                    },
                    .Blob => {
                        const blob_val = switch (val) {
                            .blob => |v| v,
                            .text => |v| v,
                            else => "",
                        };
                        const len: u32 = @intCast(@min(blob_val.len, BLOB_MAX_SIZE));
                        std.mem.writeInt(u32, self.data[offset..][0..4], len, .little);
                        offset += 4;
                        if (len > 0) @memcpy(self.data[offset .. offset + len], blob_val[0..len]);
                        offset += BLOB_MAX_SIZE;
                    },
                    .Boolean => {
                        const bool_val = switch (val) {
                            .boolean => |v| v,
                            .integer => |v| v != 0,
                            else => false,
                        };
                        self.data[offset] = if (bool_val) 1 else 0;
                        offset += 1;
                    },
                }
            } else {
                offset += column_storage_size(col.type);
            }
        }
        self.size = offset;
    }

    pub fn get_value(self: *const DynamicRow, schema: *const Schema, col_index: usize) RowValue {
        var offset: usize = 0;
        for (schema.columns[0..col_index]) |col| {
            offset += 1 + column_storage_size(col.type);
        }
        const col = schema.columns[col_index];
        const is_null_flag = self.data[offset] != 0;
        offset += 1;

        if (is_null_flag) return RowValue{ .null_val = {} };

        return switch (col.type) {
            .Integer, .Date, .Time, .Datetime => RowValue{ .integer = std.mem.readInt(i64, self.data[offset..][0..8], .little) },
            .Real => RowValue{ .real = @bitCast(self.data[offset..][0..8].*) },
            .Text => blk: {
                const len = std.mem.readInt(u32, self.data[offset..][0..4], .little);
                break :blk RowValue{ .text = self.data[offset + 4 .. offset + 4 + len] };
            },
            .Blob => blk: {
                const len = std.mem.readInt(u32, self.data[offset..][0..4], .little);
                break :blk RowValue{ .blob = self.data[offset + 4 .. offset + 4 + len] };
            },
            .Boolean => RowValue{ .boolean = self.data[offset] != 0 },
        };
    }

    pub fn as_bytes(self: *const DynamicRow) []const u8 {
        return self.data[0..self.size];
    }
};

pub fn column_storage_size(col_type: Type) usize {
    return switch (col_type) {
        .Integer, .Date, .Time, .Datetime => 8,
        .Real => 8,
        .Text => 4 + TEXT_MAX_SIZE,
        .Blob => 4 + BLOB_MAX_SIZE,
        .Boolean => 1,
    };
}

pub fn calculate_row_size(schema: *const Schema) usize {
    var size: usize = 0;
    for (schema.columns) |col| {
        size += 1 + column_storage_size(col.type);
    }
    return size;
}

pub fn deserialize_dynamic_row(data: []const u8, schema: *const Schema) DynamicRow {
    var row = DynamicRow.init();
    const size = calculate_row_size(schema);
    @memcpy(row.data[0..size], data[0..size]);
    row.size = size;
    return row;
}

pub fn max_leaf_cells() u32 {
    const available = PAGE_SIZE - node.LEAF_HEADER_SIZE;
    return @as(u32, @intCast(available / LEAF_CELL_SIZE));
}

pub fn leaf_cell_offset(cell_num: u32) usize {
    return node.LEAF_HEADER_SIZE + (cell_num * LEAF_CELL_SIZE);
}

pub fn get_leaf_key(page: *Page, cell_num: u32) u32 {
    const offset = leaf_cell_offset(cell_num);
    return std.mem.readInt(u32, page.data[offset..][0..4], .little);
}

pub fn set_leaf_key(page: *Page, cell_num: u32, key: u32) void {
    const offset = leaf_cell_offset(cell_num);
    std.mem.writeInt(u32, page.data[offset..][0..4], key, .little);
}

pub fn get_leaf_value(page: *Page, cell_num: u32) []u8 {
    const offset = leaf_cell_offset(cell_num) + LEAF_KEY_SIZE;
    return page.data[offset .. offset + LEAF_VALUE_SIZE];
}

pub fn set_leaf_value(page: *Page, cell_num: u32, value: []const u8) void {
    const offset = leaf_cell_offset(cell_num) + LEAF_KEY_SIZE;
    const len = @min(value.len, LEAF_VALUE_SIZE);
    @memcpy(page.data[offset .. offset + len], value[0..len]);
}

pub fn get_leaf_row(page: *Page, cell_num: u32, schema: *const Schema) DynamicRow {
    const val_data = get_leaf_value(page, cell_num);
    return deserialize_dynamic_row(val_data, schema);
}

pub fn get_value_from_page(page: *Page, cell_num: u32, schema: *const Schema, col_index: usize) RowValue {
    const val_data = get_leaf_value(page, cell_num);
    var offset: usize = 0;

    for (schema.columns[0..col_index]) |col| {
        offset += 1 + column_storage_size(col.type);
    }

    const col = schema.columns[col_index];
    const is_null_flag = val_data[offset] != 0;
    offset += 1;

    if (is_null_flag) return RowValue{ .null_val = {} };

    return switch (col.type) {
        .Integer, .Date, .Time, .Datetime => RowValue{ .integer = std.mem.readInt(i64, val_data[offset..][0..8], .little) },
        .Real => RowValue{ .real = @bitCast(val_data[offset..][0..8].*) },
        .Text => blk: {
            const len = std.mem.readInt(u32, val_data[offset..][0..4], .little);
            break :blk RowValue{ .text = val_data[offset + 4 .. offset + 4 + len] };
        },
        .Blob => blk: {
            const len = std.mem.readInt(u32, val_data[offset..][0..4], .little);
            break :blk RowValue{ .blob = val_data[offset + 4 .. offset + 4 + len] };
        },
        .Boolean => RowValue{ .boolean = val_data[offset] != 0 },
    };
}

pub fn set_value_in_page(page: *Page, cell_num: u32, schema: *const Schema, col_index: usize, value: RowValue) void {
    const cell_offset = leaf_cell_offset(cell_num);
    const val_offset = cell_offset + 4;
    var offset: usize = 0;

    for (schema.columns[0..col_index]) |col| {
        offset += 1 + column_storage_size(col.type);
    }

    switch (value) {
        .null_val => {
            page.data[val_offset + offset] = 1;
        },
        .integer => |v| {
            page.data[val_offset + offset] = 0;
            std.mem.writeInt(i64, page.data[val_offset + offset + 1 ..][0..8], v, .little);
        },
        .real => |v| {
            page.data[val_offset + offset] = 0;
            const bytes: [8]u8 = @bitCast(v);
            @memcpy(page.data[val_offset + offset + 1 ..][0..8], &bytes);
        },
        .boolean => |v| {
            page.data[val_offset + offset] = 0;
            page.data[val_offset + offset + 1] = if (v) 1 else 0;
        },
        else => {},
    }
}

pub fn set_leaf_row(page: *Page, cell_num: u32, row: *const DynamicRow) void {
    set_leaf_value(page, cell_num, row.as_bytes());
}

test "dynamic row serialize and deserialize" {
    var columns = [_]schema_mod.Column{
        .{ .name = "id", .type = .Integer, .primary_key = true, .not_null = true },
        .{ .name = "name", .type = .Text, .primary_key = false, .not_null = true },
        .{ .name = "active", .type = .Boolean, .primary_key = false, .not_null = false },
    };
    const schema = Schema.init("test", &columns);

    var row = DynamicRow.init();
    const values = [_]RowValue{
        RowValue{ .integer = 42 },
        RowValue{ .text = "alice" },
        RowValue{ .boolean = true },
    };
    try row.serialize_values(&schema, &values);

    const id_val = row.get_value(&schema, 0);
    try std.testing.expectEqual(@as(i64, 42), id_val.integer);

    const name_val = row.get_value(&schema, 1);
    try std.testing.expectEqualStrings("alice", name_val.text);

    const active_val = row.get_value(&schema, 2);
    try std.testing.expect(active_val.boolean);
}

test "dynamic row with null values" {
    var columns = [_]schema_mod.Column{
        .{ .name = "id", .type = .Integer, .primary_key = true, .not_null = true },
        .{ .name = "email", .type = .Text, .primary_key = false, .not_null = false },
    };
    const schema = Schema.init("test", &columns);

    var row = DynamicRow.init();
    const values = [_]RowValue{
        RowValue{ .integer = 1 },
        RowValue{ .null_val = {} },
    };
    try row.serialize_values(&schema, &values);

    const id_val = row.get_value(&schema, 0);
    try std.testing.expectEqual(@as(i64, 1), id_val.integer);

    const email_val = row.get_value(&schema, 1);
    try std.testing.expect(email_val.is_null());
}

test "leaf cell key operations" {
    var page = Page.init();
    node.initialize_leaf_node(&page);

    set_leaf_key(&page, 0, 100);
    try std.testing.expectEqual(@as(u32, 100), get_leaf_key(&page, 0));

    set_leaf_key(&page, 1, 200);
    try std.testing.expectEqual(@as(u32, 200), get_leaf_key(&page, 1));
}
