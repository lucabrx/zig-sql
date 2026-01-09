const std = @import("std");
const Compiler = @import("compiler.zig").Compiler;
const ast = @import("../parser/ast.zig");
const SelectStatement = ast.SelectStatement;
const Expression = ast.Expression;
const CompilerError = @import("errors.zig").CompilerError;
const expression = @import("expression.zig");
const Schema = @import("../storage/schema.zig").Schema;

pub fn compile_select(c: *Compiler, stmt: SelectStatement) !void {
    const table = c.db.get_table(stmt.from) catch return CompilerError.TableNotFound;
    const schema = table.schema;

    const output_cols = try resolve_select_columns(c, stmt.columns, schema);

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

    c.allocator.free(output_cols);
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
