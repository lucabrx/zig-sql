const std = @import("std");
const Pager = @import("pager.zig").Pager;
const Page = @import("pager.zig").Page;
const PAGE_SIZE = @import("pager.zig").PAGE_SIZE;
const schema_mod = @import("schema.zig");
const Schema = schema_mod.Schema;
const Type = schema_mod.Type;
const row_mod = @import("row.zig");
const RowValue = row_mod.RowValue;

const builtin = @import("builtin");
const DEBUG = builtin.mode == .Debug;

fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (DEBUG) {
        std.debug.print(fmt, args);
    }
}

pub const COLUMNAR_MAGIC: u32 = 0x434F4C53;
const HEADER_SIZE: usize = 64;
const VALUES_PER_PAGE: usize = 512;

pub const ColumnType = enum(u8) {
    int64 = 0,
    float64 = 1,
    bool8 = 2,
    string = 3,
    null_bitmap = 4,
};

pub const ColumnChunk = struct {
    col_index: u32,
    start_row: u32,
    num_values: u32,
    page_num: u32,
    null_bitmap_page: u32,
    min_value: i64,
    max_value: i64,
    has_nulls: bool,
};

pub const ColumnarTable = struct {
    allocator: std.mem.Allocator,
    pager: *Pager,
    schema: *const Schema,
    name: []const u8,
    header_page: u32,
    num_rows: u32,
    chunks: std.ArrayList(ColumnChunk),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, pager: *Pager, s: *const Schema, header_page: u32) Self {
        return Self{
            .allocator = allocator,
            .pager = pager,
            .schema = s,
            .name = s.table_name,
            .header_page = header_page,
            .num_rows = 0,
            .chunks = std.ArrayList(ColumnChunk).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.chunks.deinit();
    }

    pub fn initialize(self: *Self) !void {
        const page = try self.pager.get_page(self.header_page);
        std.mem.writeInt(u32, page.data[0..4], COLUMNAR_MAGIC, .little);
        std.mem.writeInt(u32, page.data[4..8], @intCast(self.schema.columns.len), .little);
        std.mem.writeInt(u32, page.data[8..12], 0, .little);
        std.mem.writeInt(u32, page.data[12..16], 0, .little);
        self.pager.mark_dirty(self.header_page);
        debugPrint("[COLUMNAR] Initialized table '{s}' at page {}\n", .{ self.name, self.header_page });
    }

    pub fn bulk_insert(self: *Self, rows: []const []const RowValue) !u32 {
        if (rows.len == 0) return 0;

        const num_cols = self.schema.columns.len;
        var inserted: u32 = 0;

        for (0..num_cols) |col_idx| {
            const col = self.schema.columns[col_idx];
            const chunk = try self.write_column_chunk(@intCast(col_idx), col.type, rows, self.num_rows);
            try self.chunks.append(chunk);
        }

        inserted = @intCast(rows.len);
        self.num_rows += inserted;
        try self.save_header();

        debugPrint("[COLUMNAR] Bulk inserted {} rows into '{s}'\n", .{ inserted, self.name });
        return inserted;
    }

    fn write_column_chunk(self: *Self, col_idx: u32, col_type: Type, rows: []const []const RowValue, start_row: u32) !ColumnChunk {
        const page_num = try self.pager.allocate_page();
        const page = try self.pager.get_page(page_num);

        var null_bitmap_page: u32 = 0;
        var has_nulls = false;
        var min_val: i64 = std.math.maxInt(i64);
        var max_val: i64 = std.math.minInt(i64);

        var null_bits: [VALUES_PER_PAGE / 8]u8 = std.mem.zeroes([VALUES_PER_PAGE / 8]u8);

        for (rows, 0..) |row, i| {
            const val = if (col_idx < row.len) row[col_idx] else RowValue{ .null_val = {} };

            if (val == .null_val) {
                has_nulls = true;
                const byte_idx = i / 8;
                const bit_idx: u3 = @intCast(i % 8);
                null_bits[byte_idx] |= (@as(u8, 1) << bit_idx);
            }

            switch (col_type) {
                .Integer, .Date, .Time, .Datetime => {
                    const int_val: i64 = switch (val) {
                        .integer => |v| v,
                        else => 0,
                    };
                    const offset = HEADER_SIZE + i * 8;
                    std.mem.writeInt(i64, page.data[offset..][0..8], int_val, .little);
                    if (val != .null_val) {
                        min_val = @min(min_val, int_val);
                        max_val = @max(max_val, int_val);
                    }
                },
                .Real => {
                    const real_val: f64 = switch (val) {
                        .real => |v| v,
                        .integer => |v| @floatFromInt(v),
                        else => 0.0,
                    };
                    const offset = HEADER_SIZE + i * 8;
                    @memcpy(page.data[offset..][0..8], std.mem.asBytes(&real_val));
                    if (val != .null_val) {
                        const int_repr: i64 = @bitCast(real_val);
                        min_val = @min(min_val, int_repr);
                        max_val = @max(max_val, int_repr);
                    }
                },
                .Boolean => {
                    const bool_val: u8 = switch (val) {
                        .boolean => |v| if (v) 1 else 0,
                        .integer => |v| if (v != 0) 1 else 0,
                        else => 0,
                    };
                    const offset = HEADER_SIZE + i;
                    page.data[offset] = bool_val;
                },
                .Text, .Blob => {
                    const str_val: []const u8 = switch (val) {
                        .text => |v| v,
                        .blob => |v| v,
                        else => "",
                    };
                    const offset = HEADER_SIZE + i * 260;
                    const len: u32 = @intCast(@min(str_val.len, 256));
                    std.mem.writeInt(u32, page.data[offset..][0..4], len, .little);
                    if (len > 0) {
                        @memcpy(page.data[offset + 4 ..][0..len], str_val[0..len]);
                    }
                },
            }
        }

        std.mem.writeInt(u32, page.data[0..4], col_idx, .little);
        std.mem.writeInt(u32, page.data[4..8], @intCast(rows.len), .little);
        std.mem.writeInt(u8, page.data[8..9], @intFromEnum(type_to_column_type(col_type)), .little);
        self.pager.mark_dirty(page_num);

        if (has_nulls) {
            null_bitmap_page = try self.pager.allocate_page();
            const null_page = try self.pager.get_page(null_bitmap_page);
            @memcpy(null_page.data[0..null_bits.len], &null_bits);
            self.pager.mark_dirty(null_bitmap_page);
        }

        return ColumnChunk{
            .col_index = col_idx,
            .start_row = start_row,
            .num_values = @intCast(rows.len),
            .page_num = page_num,
            .null_bitmap_page = null_bitmap_page,
            .min_value = min_val,
            .max_value = max_val,
            .has_nulls = has_nulls,
        };
    }

    pub fn scan_column(self: *Self, col_idx: usize, allocator: std.mem.Allocator) ![]RowValue {
        var results = std.ArrayList(RowValue).init(allocator);
        errdefer results.deinit();

        const col_type = self.schema.columns[col_idx].type;

        for (self.chunks.items) |chunk| {
            if (chunk.col_index != col_idx) continue;

            const page = try self.pager.get_page(chunk.page_num);
            var null_bits: ?[]const u8 = null;

            if (chunk.has_nulls and chunk.null_bitmap_page != 0) {
                const null_page = try self.pager.get_page(chunk.null_bitmap_page);
                null_bits = null_page.data[0 .. VALUES_PER_PAGE / 8];
            }

            for (0..chunk.num_values) |i| {
                const is_null = if (null_bits) |bits| blk: {
                    const byte_idx = i / 8;
                    const bit_idx: u3 = @intCast(i % 8);
                    break :blk (bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
                } else false;

                if (is_null) {
                    try results.append(RowValue{ .null_val = {} });
                    continue;
                }

                const val = switch (col_type) {
                    .Integer, .Date, .Time, .Datetime => blk: {
                        const offset = HEADER_SIZE + i * 8;
                        break :blk RowValue{ .integer = std.mem.readInt(i64, page.data[offset..][0..8], .little) };
                    },
                    .Real => blk: {
                        const offset = HEADER_SIZE + i * 8;
                        break :blk RowValue{ .real = @bitCast(page.data[offset..][0..8].*) };
                    },
                    .Boolean => blk: {
                        const offset = HEADER_SIZE + i;
                        break :blk RowValue{ .boolean = page.data[offset] != 0 };
                    },
                    .Text, .Blob => blk: {
                        const offset = HEADER_SIZE + i * 260;
                        const len = std.mem.readInt(u32, page.data[offset..][0..4], .little);
                        const str = try allocator.dupe(u8, page.data[offset + 4 ..][0..len]);
                        break :blk if (col_type == .Text) RowValue{ .text = str } else RowValue{ .blob = str };
                    },
                };
                try results.append(val);
            }
        }

        return results.toOwnedSlice();
    }

    pub fn aggregate_column(self: *Self, col_idx: usize, agg_type: AggregateType) !AggregateResult {
        var result = AggregateResult{
            .count = 0,
            .sum = 0,
            .min = std.math.maxInt(i64),
            .max = std.math.minInt(i64),
        };

        for (self.chunks.items) |chunk| {
            if (chunk.col_index != col_idx) continue;

            if (agg_type == .count) {
                result.count += chunk.num_values;
                if (chunk.has_nulls) {
                    const null_page = try self.pager.get_page(chunk.null_bitmap_page);
                    for (0..chunk.num_values) |i| {
                        const byte_idx = i / 8;
                        const bit_idx: u3 = @intCast(i % 8);
                        if ((null_page.data[byte_idx] & (@as(u8, 1) << bit_idx)) != 0) {
                            result.count -= 1;
                        }
                    }
                }
                continue;
            }

            if (agg_type == .min or agg_type == .max) {
                if (!chunk.has_nulls) {
                    result.min = @min(result.min, chunk.min_value);
                    result.max = @max(result.max, chunk.max_value);
                    result.count += chunk.num_values;
                    continue;
                }
            }

            const page = try self.pager.get_page(chunk.page_num);
            var null_bits: ?[]const u8 = null;
            if (chunk.has_nulls and chunk.null_bitmap_page != 0) {
                const null_page = try self.pager.get_page(chunk.null_bitmap_page);
                null_bits = null_page.data[0 .. VALUES_PER_PAGE / 8];
            }

            for (0..chunk.num_values) |i| {
                const is_null = if (null_bits) |bits| blk: {
                    const byte_idx = i / 8;
                    const bit_idx: u3 = @intCast(i % 8);
                    break :blk (bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
                } else false;

                if (is_null) continue;

                const offset = HEADER_SIZE + i * 8;
                const val = std.mem.readInt(i64, page.data[offset..][0..8], .little);

                result.count += 1;
                result.sum += val;
                result.min = @min(result.min, val);
                result.max = @max(result.max, val);
            }
        }

        return result;
    }

    pub fn scan_with_filter(self: *Self, col_idx: usize, op: FilterOp, value: i64, allocator: std.mem.Allocator) ![]u32 {
        var matching_rows = std.ArrayList(u32).init(allocator);
        errdefer matching_rows.deinit();

        for (self.chunks.items) |chunk| {
            if (chunk.col_index != col_idx) continue;

            if (!chunk.has_nulls) {
                const dominated = switch (op) {
                    .eq => chunk.min_value > value or chunk.max_value < value,
                    .lt => chunk.min_value >= value,
                    .le => chunk.min_value > value,
                    .gt => chunk.max_value <= value,
                    .ge => chunk.max_value < value,
                    .ne => chunk.min_value == value and chunk.max_value == value,
                };
                if (dominated) continue;
            }

            const page = try self.pager.get_page(chunk.page_num);
            var null_bits: ?[]const u8 = null;
            if (chunk.has_nulls and chunk.null_bitmap_page != 0) {
                const null_page = try self.pager.get_page(chunk.null_bitmap_page);
                null_bits = null_page.data[0 .. VALUES_PER_PAGE / 8];
            }

            for (0..chunk.num_values) |i| {
                const is_null = if (null_bits) |bits| blk: {
                    const byte_idx = i / 8;
                    const bit_idx: u3 = @intCast(i % 8);
                    break :blk (bits[byte_idx] & (@as(u8, 1) << bit_idx)) != 0;
                } else false;

                if (is_null) continue;

                const offset = HEADER_SIZE + i * 8;
                const val = std.mem.readInt(i64, page.data[offset..][0..8], .little);

                const matches = switch (op) {
                    .eq => val == value,
                    .ne => val != value,
                    .lt => val < value,
                    .le => val <= value,
                    .gt => val > value,
                    .ge => val >= value,
                };

                if (matches) {
                    try matching_rows.append(chunk.start_row + @as(u32, @intCast(i)));
                }
            }
        }

        return matching_rows.toOwnedSlice();
    }

    fn save_header(self: *Self) !void {
        const page = try self.pager.get_page(self.header_page);
        std.mem.writeInt(u32, page.data[8..12], self.num_rows, .little);
        std.mem.writeInt(u32, page.data[12..16], @intCast(self.chunks.items.len), .little);
        self.pager.mark_dirty(self.header_page);
    }

    pub fn get_stats(self: *Self) ColumnarStats {
        var total_pages: u32 = 1;
        var null_pages: u32 = 0;

        for (self.chunks.items) |chunk| {
            total_pages += 1;
            if (chunk.null_bitmap_page != 0) {
                null_pages += 1;
                total_pages += 1;
            }
        }

        return ColumnarStats{
            .num_rows = self.num_rows,
            .num_columns = @intCast(self.schema.columns.len),
            .num_chunks = @intCast(self.chunks.items.len),
            .total_pages = total_pages,
            .null_bitmap_pages = null_pages,
        };
    }
};

pub const AggregateType = enum {
    count,
    sum,
    min,
    max,
    avg,
};

pub const AggregateResult = struct {
    count: i64,
    sum: i64,
    min: i64,
    max: i64,

    pub fn avg(self: AggregateResult) f64 {
        if (self.count == 0) return 0;
        return @as(f64, @floatFromInt(self.sum)) / @as(f64, @floatFromInt(self.count));
    }
};

pub const FilterOp = enum {
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
};

pub const ColumnarStats = struct {
    num_rows: u32,
    num_columns: u32,
    num_chunks: u32,
    total_pages: u32,
    null_bitmap_pages: u32,
};

fn type_to_column_type(t: Type) ColumnType {
    return switch (t) {
        .Integer, .Date, .Time, .Datetime => .int64,
        .Real => .float64,
        .Boolean => .bool8,
        .Text, .Blob => .string,
    };
}

test "columnar table initialization" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var columns = [_]schema_mod.Column{
        .{ .name = "id", .type = .Integer, .primary_key = true, .not_null = true },
        .{ .name = "value", .type = .Integer, .primary_key = false, .not_null = false },
    };
    const schema = Schema.init("test_columnar", &columns);

    var table = ColumnarTable.init(allocator, &pager, &schema, 0);
    defer table.deinit();
    try table.initialize();

    try std.testing.expectEqual(@as(u32, 0), table.num_rows);
}

test "columnar bulk insert and scan" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var columns = [_]schema_mod.Column{
        .{ .name = "id", .type = .Integer, .primary_key = true, .not_null = true },
        .{ .name = "value", .type = .Integer, .primary_key = false, .not_null = false },
    };
    const schema = Schema.init("test", &columns);

    var table = ColumnarTable.init(allocator, &pager, &schema, 0);
    defer table.deinit();
    try table.initialize();

    var rows: [3][]const RowValue = undefined;
    var row0 = [_]RowValue{ RowValue{ .integer = 1 }, RowValue{ .integer = 100 } };
    var row1 = [_]RowValue{ RowValue{ .integer = 2 }, RowValue{ .integer = 200 } };
    var row2 = [_]RowValue{ RowValue{ .integer = 3 }, RowValue{ .integer = 300 } };
    rows[0] = &row0;
    rows[1] = &row1;
    rows[2] = &row2;

    const inserted = try table.bulk_insert(&rows);
    try std.testing.expectEqual(@as(u32, 3), inserted);
    try std.testing.expectEqual(@as(u32, 3), table.num_rows);

    const col0_values = try table.scan_column(0, allocator);
    defer allocator.free(col0_values);
    try std.testing.expectEqual(@as(usize, 3), col0_values.len);
    try std.testing.expectEqual(@as(i64, 1), col0_values[0].integer);
    try std.testing.expectEqual(@as(i64, 2), col0_values[1].integer);
    try std.testing.expectEqual(@as(i64, 3), col0_values[2].integer);
}

test "columnar aggregate" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var columns = [_]schema_mod.Column{
        .{ .name = "value", .type = .Integer, .primary_key = false, .not_null = true },
    };
    const schema = Schema.init("test", &columns);

    var table = ColumnarTable.init(allocator, &pager, &schema, 0);
    defer table.deinit();
    try table.initialize();

    var rows: [4][]const RowValue = undefined;
    var r0 = [_]RowValue{RowValue{ .integer = 10 }};
    var r1 = [_]RowValue{RowValue{ .integer = 20 }};
    var r2 = [_]RowValue{RowValue{ .integer = 30 }};
    var r3 = [_]RowValue{RowValue{ .integer = 40 }};
    rows[0] = &r0;
    rows[1] = &r1;
    rows[2] = &r2;
    rows[3] = &r3;

    _ = try table.bulk_insert(&rows);

    const result = try table.aggregate_column(0, .sum);
    try std.testing.expectEqual(@as(i64, 100), result.sum);
    try std.testing.expectEqual(@as(i64, 4), result.count);
    try std.testing.expectEqual(@as(i64, 10), result.min);
    try std.testing.expectEqual(@as(i64, 40), result.max);
}

test "columnar filter scan" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var columns = [_]schema_mod.Column{
        .{ .name = "value", .type = .Integer, .primary_key = false, .not_null = true },
    };
    const schema = Schema.init("test", &columns);

    var table = ColumnarTable.init(allocator, &pager, &schema, 0);
    defer table.deinit();
    try table.initialize();

    var rows: [5][]const RowValue = undefined;
    var r0 = [_]RowValue{RowValue{ .integer = 10 }};
    var r1 = [_]RowValue{RowValue{ .integer = 20 }};
    var r2 = [_]RowValue{RowValue{ .integer = 30 }};
    var r3 = [_]RowValue{RowValue{ .integer = 40 }};
    var r4 = [_]RowValue{RowValue{ .integer = 50 }};
    rows[0] = &r0;
    rows[1] = &r1;
    rows[2] = &r2;
    rows[3] = &r3;
    rows[4] = &r4;

    _ = try table.bulk_insert(&rows);

    const gt_25 = try table.scan_with_filter(0, .gt, 25, allocator);
    defer allocator.free(gt_25);
    try std.testing.expectEqual(@as(usize, 3), gt_25.len);

    const eq_30 = try table.scan_with_filter(0, .eq, 30, allocator);
    defer allocator.free(eq_30);
    try std.testing.expectEqual(@as(usize, 1), eq_30.len);
    try std.testing.expectEqual(@as(u32, 2), eq_30[0]);
}

test "columnar stats" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var columns = [_]schema_mod.Column{
        .{ .name = "a", .type = .Integer, .primary_key = false, .not_null = true },
        .{ .name = "b", .type = .Integer, .primary_key = false, .not_null = true },
    };
    const schema = Schema.init("test", &columns);

    var table = ColumnarTable.init(allocator, &pager, &schema, 0);
    defer table.deinit();
    try table.initialize();

    var rows: [2][]const RowValue = undefined;
    var r0 = [_]RowValue{ RowValue{ .integer = 1 }, RowValue{ .integer = 2 } };
    var r1 = [_]RowValue{ RowValue{ .integer = 3 }, RowValue{ .integer = 4 } };
    rows[0] = &r0;
    rows[1] = &r1;

    _ = try table.bulk_insert(&rows);

    const stats = table.get_stats();
    try std.testing.expectEqual(@as(u32, 2), stats.num_rows);
    try std.testing.expectEqual(@as(u32, 2), stats.num_columns);
    try std.testing.expectEqual(@as(u32, 2), stats.num_chunks);
}
