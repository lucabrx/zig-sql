const std = @import("std");
const Compiler = @import("compiler.zig").Compiler;
const ast = @import("../parser/ast.zig");
const SelectStatement = ast.SelectStatement;
const Expression = ast.Expression;
const CompilerError = @import("errors.zig").CompilerError;
const expression = @import("expression.zig");
const Schema = @import("../storage/schema.zig").Schema;
const IndexDef = @import("../storage/schema.zig").IndexDef;

const IndexCandidate = struct {
    index_name: []const u8,
    column_name: []const u8,
    value: Expression,
};

pub fn compile_select(c: *Compiler, stmt: SelectStatement) !void {
    const table = c.db.get_table(stmt.from) catch return CompilerError.TableNotFound;
    const schema = table.schema;

    const output_cols = try resolve_select_columns(c, stmt.columns, schema);

    const index_candidate = if (stmt.where) |where_expr|
        try find_usable_index(c, where_expr, stmt.from, schema)
    else
        null;

    if (index_candidate) |candidate| {
        try compile_index_scan(c, stmt, schema, output_cols, candidate);
    } else {
        try compile_full_scan(c, stmt, schema, output_cols);
    }

    c.allocator.free(output_cols);
}

fn compile_full_scan(c: *Compiler, stmt: SelectStatement, schema: *const Schema, output_cols: []i32) !void {
    _ = try c.emit(.open_read, 0, 0, 0, stmt.from, null);

    const rewind_addr = try c.emit(.rewind, 0, 0, 0, "", null);

    const loop_start = c.current_addr();

    var skip_addr: ?usize = null;
    if (stmt.where) |where_expr| {
        const cond_reg = c.alloc_reg();
        try expression.compile_expression(c, where_expr, cond_reg, schema);
        skip_addr = try c.emit(.if_zero, cond_reg, 0, 0, "", null);
    }

    const start_reg = c.next_reg;
    for (output_cols) |col_idx| {
        const reg = c.alloc_reg();
        _ = try c.emit(.column, 0, col_idx, reg, "", null);
    }

    _ = try c.emit(.result_row, start_reg, @intCast(output_cols.len), 0, "", null);

    _ = try c.emit(.next, 0, @intCast(loop_start), 0, "", null);

    if (skip_addr) |addr| {
        c.patch(addr, @intCast(c.current_addr()));
        _ = try c.emit(.next, 0, @intCast(loop_start), 0, "", null);
    }

    const close_addr = c.current_addr();
    _ = try c.emit(.close, 0, 0, 0, "", null);
    c.patch(rewind_addr, @intCast(close_addr));
}

fn compile_index_scan(c: *Compiler, stmt: SelectStatement, schema: *const Schema, output_cols: []i32, candidate: IndexCandidate) !void {
    const value_reg = c.alloc_reg();
    try expression.compile_expression(c, candidate.value, value_reg, schema);

    _ = try c.emit(.open_read, 0, 0, 0, stmt.from, null);
    const scan_addr = try c.emit(.index_scan, 0, 0, value_reg, candidate.index_name, null);

    const loop_start = c.current_addr();

    const start_reg = c.next_reg;
    for (output_cols) |col_idx| {
        const reg = c.alloc_reg();
        _ = try c.emit(.column, 0, col_idx, reg, "", null);
    }

    _ = try c.emit(.result_row, start_reg, @intCast(output_cols.len), 0, "", null);

    _ = try c.emit(.index_next, 0, @intCast(loop_start), 0, "", null);

    const close_addr = c.current_addr();
    _ = try c.emit(.close, 0, 0, 0, "", null);
    c.patch(scan_addr, @intCast(close_addr));
}

fn find_usable_index(c: *Compiler, where_expr: Expression, table_name: []const u8, schema: *const Schema) !?IndexCandidate {
    switch (where_expr) {
        .binary_expression => |bin_expr| {
            const op = bin_expr.operator;
            if (!std.mem.eql(u8, op, "=") and !std.mem.eql(u8, op, "==")) {
                return null;
            }

            var col_name: ?[]const u8 = null;
            var value_expr: ?Expression = null;

            switch (bin_expr.left) {
                .identifier => |ident| {
                    col_name = ident.name;
                    value_expr = bin_expr.right;
                },
                else => {},
            }

            if (col_name == null) {
                switch (bin_expr.right) {
                    .identifier => |ident| {
                        col_name = ident.name;
                        value_expr = bin_expr.left;
                    },
                    else => {},
                }
            }

            if (col_name == null or value_expr == null) return null;

            _ = schema.get_column_index(col_name.?) catch return null;

            const index_name = try find_index_for_column(c, table_name, col_name.?);
            if (index_name) |idx_name| {
                return IndexCandidate{
                    .index_name = idx_name,
                    .column_name = col_name.?,
                    .value = value_expr.?,
                };
            }
        },
        else => {},
    }

    return null;
}

fn find_index_for_column(c: *Compiler, table_name: []const u8, column_name: []const u8) !?[]const u8 {
    var idx_iter = c.db.indexes.iterator();
    while (idx_iter.next()) |entry| {
        const index_def = entry.value_ptr.*;
        if (!std.mem.eql(u8, index_def.table, table_name)) continue;

        if (index_def.columns.len == 1 and std.mem.eql(u8, index_def.columns[0], column_name)) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

fn resolve_select_columns(c: *Compiler, cols: []const Expression, schema: *const Schema) ![]i32 {
    var indices = std.ArrayList(i32){};

    for (cols) |col| {
        switch (col) {
            .star_expression => {
                for (0..schema.columns.len) |i| {
                    try indices.append(c.allocator, @intCast(i));
                }
            },
            .identifier => |ident| {
                const idx = get_column_index(schema, ident.name);
                if (idx >= 0) {
                    try indices.append(c.allocator, idx);
                }
            },
            else => {},
        }
    }

    return try indices.toOwnedSlice(c.allocator);
}

fn get_column_index(schema: *const Schema, name: []const u8) i32 {
    for (schema.columns, 0..) |col, i| {
        if (std.mem.eql(u8, col.name, name)) {
            return @intCast(i);
        }
    }
    return -1;
}
