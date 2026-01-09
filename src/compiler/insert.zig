const std = @import("std");
const Compiler = @import("compiler.zig").Compiler;
const ast = @import("../parser/ast.zig");
const InsertStatement = ast.InsertStatement;
const Expression = ast.Expression;
const CompilerError = @import("errors.zig").CompilerError;

pub fn compile_insert(c: *Compiler, stmt: InsertStatement) !void {
    const table = c.db.get_table(stmt.table) catch return CompilerError.TableNotFound;
    const schema = table.schema;

    _ = try c.emit(.open_write, 0, 0, 0, stmt.table, null);

    const start_reg = c.next_reg;

    for (schema.columns, 0..) |col, i| {
        const reg = c.alloc_reg();

        var found = false;
        if (stmt.columns.len > 0) {
            for (stmt.columns, 0..) |col_name, val_idx| {
                if (std.mem.eql(u8, col_name, col.name) and val_idx < stmt.values.len) {
                    try compile_value_expression(c, stmt.values[val_idx], reg);
                    found = true;
                    break;
                }
            }
        } else if (i < stmt.values.len) {
            try compile_value_expression(c, stmt.values[i], reg);
            found = true;
        }

        if (!found) {
            _ = try c.emit(.null, reg, 0, 0, "", null);
        }
    }

    _ = try c.emit(.insert, 0, start_reg, @intCast(schema.columns.len), "", null);
    _ = try c.emit(.close, 0, 0, 0, "", null);
}

pub fn compile_value_expression(c: *Compiler, expr: Expression, dest_reg: i32) !void {
    switch (expr) {
        .integer_literal => |int_lit| {
            _ = try c.emit(.integer, dest_reg, @intCast(int_lit.value), 0, "", null);
        },
        .float_literal => |_| {
            _ = try c.emit(.real, dest_reg, 0, 0, "", null);
        },
        .string_literal => |str_lit| {
            _ = try c.emit(.string, dest_reg, 0, 0, str_lit.value, null);
        },
        .null_literal => {
            _ = try c.emit(.null, dest_reg, 0, 0, "", null);
        },
        else => {
            _ = try c.emit(.null, dest_reg, 0, 0, "", null);
        },
    }
}
