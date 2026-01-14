const std = @import("std");
const Compiler = @import("compiler.zig").Compiler;
const ast = @import("../parser/ast.zig");
const Expression = ast.Expression;
const Schema = @import("../storage/schema.zig").Schema;

const CompileError = error{OutOfMemory};

pub fn compile_expression(c: *Compiler, expr: Expression, dest_reg: i32, schema: ?*const Schema) CompileError!void {
    _ = schema;

    switch (expr) {
        .identifier => |ident| {
            const col_idx = get_column_index(ident.name);
            _ = try c.emit(.column, 0, col_idx, dest_reg, "", null);
        },
        .integer_literal => |int_lit| {
            _ = try c.emit(.integer, dest_reg, @intCast(int_lit.value), 0, "", null);
        },
        .float_literal => |float_lit| {
            const float_ptr = c.allocator.create(f64) catch return CompileError.OutOfMemory;
            float_ptr.* = float_lit.value;
            _ = try c.emit(.real, dest_reg, 0, 0, "", @ptrCast(float_ptr));
        },
        .string_literal => |str_lit| {
            _ = try c.emit(.string, dest_reg, 0, 0, str_lit.value, null);
        },
        .boolean_literal => |bool_lit| {
            _ = try c.emit(.integer, dest_reg, if (bool_lit.value) 1 else 0, 0, "", null);
        },
        .null_literal => {
            _ = try c.emit(.null, dest_reg, 0, 0, "", null);
        },
        .star_expression => {
            // Not valid in WHERE clause
            _ = try c.emit(.null, dest_reg, 0, 0, "", null);
        },
        .binary_expression => |bin_expr| {
            try compile_binary_expression(c, bin_expr, dest_reg);
        },
        .unary_expression => |unary_expr| {
            try compile_unary_expression(c, unary_expr, dest_reg);
        },
    }
}

fn compile_binary_expression(c: *Compiler, bin_expr: *ast.BinaryExpression, dest_reg: i32) CompileError!void {
    const left_reg = c.alloc_reg();
    const right_reg = c.alloc_reg();

    try compile_expression(c, bin_expr.left, left_reg, null);
    try compile_expression(c, bin_expr.right, right_reg, null);

    const op = bin_expr.operator;
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
        _ = try c.emit(.eq, left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, "!=") or std.mem.eql(u8, op, "<>")) {
        _ = try c.emit(.ne, left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, "<")) {
        _ = try c.emit(.lt, left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, "<=")) {
        _ = try c.emit(.le, left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, ">")) {
        _ = try c.emit(.gt, left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, ">=")) {
        _ = try c.emit(.ge, left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, "AND")) {
        _ = try c.emit(.@"and", left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, "OR")) {
        _ = try c.emit(.@"or", left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, "+")) {
        _ = try c.emit(.add, left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, "-")) {
        _ = try c.emit(.sub, left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, "*")) {
        _ = try c.emit(.mul, left_reg, right_reg, dest_reg, "", null);
    } else if (std.mem.eql(u8, op, "/")) {
        _ = try c.emit(.div, left_reg, right_reg, dest_reg, "", null);
    }
}

fn compile_unary_expression(c: *Compiler, unary_expr: *ast.UnaryExpression, dest_reg: i32) CompileError!void {
    const operand_reg = c.alloc_reg();
    try compile_expression(c, unary_expr.right, operand_reg, null);

    const op = unary_expr.operator;
    if (std.mem.eql(u8, op, "NOT")) {
        _ = try c.emit(.not, operand_reg, dest_reg, 0, "", null);
    } else if (std.mem.eql(u8, op, "-")) {
        _ = try c.emit(.integer, dest_reg, 0, 0, "", null);
        _ = try c.emit(.sub, dest_reg, operand_reg, dest_reg, "", null);
    }
}

fn get_column_index(name: []const u8) i32 {
    // TODO: Look up in schema
    if (std.mem.eql(u8, name, "id")) return 0;
    if (std.mem.eql(u8, name, "username")) return 1;
    if (std.mem.eql(u8, name, "email")) return 2;
    return 0;
}
