const std = @import("std");
const Compiler = @import("compiler.zig").Compiler;
const ast = @import("../parser/ast.zig");
const Expression = ast.Expression;
const Schema = @import("../storage/schema.zig").Schema;

const CompileError = error{OutOfMemory};

pub fn compile_expression(c: *Compiler, expr: Expression, dest_reg: i32, schema: ?*const Schema) CompileError!void {
    switch (expr) {
        .identifier => |ident| {
            const col_idx = if (schema) |s| get_schema_column_index(s, ident.name) else get_column_index(ident.name);
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
            _ = try c.emit(.null, dest_reg, 0, 0, "", null);
        },
        .binary_expression => |bin_expr| {
            try compile_binary_expression(c, bin_expr, dest_reg, schema);
        },
        .unary_expression => |unary_expr| {
            try compile_unary_expression(c, unary_expr, dest_reg, schema);
        },
        .subquery => |subq| {
            try compile_subquery(c, subq, dest_reg);
        },
        .aggregate => {
            _ = try c.emit(.null, dest_reg, 0, 0, "", null);
        },
        .between => |bet| {
            try compile_between(c, bet, dest_reg, schema);
        },
        .in_list => |in| {
            try compile_in_list(c, in, dest_reg, schema);
        },
        .in_subquery => |in_sub| {
            try compile_in_subquery(c, in_sub, dest_reg, schema);
        },
        .like => |lk| {
            try compile_like(c, lk, dest_reg, schema);
        },
        .is_null => |isn| {
            try compile_is_null(c, isn, dest_reg, schema);
        },
        .case_expr => |case| {
            try compile_case(c, case, dest_reg, schema);
        },
    }
}

fn compile_subquery(c: *Compiler, subq: *ast.SubqueryExpression, dest_reg: i32) CompileError!void {
    const subq_ptr = c.allocator.create(ast.SubqueryExpression) catch return CompileError.OutOfMemory;
    subq_ptr.* = subq.*;
    _ = try c.emit(.subquery, dest_reg, 0, 0, "", @ptrCast(subq_ptr));
}

fn compile_binary_expression(c: *Compiler, bin_expr: *ast.BinaryExpression, dest_reg: i32, schema: ?*const Schema) CompileError!void {
    const left_reg = c.alloc_reg();
    const right_reg = c.alloc_reg();

    try compile_expression(c, bin_expr.left, left_reg, schema);
    try compile_expression(c, bin_expr.right, right_reg, schema);

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

fn compile_unary_expression(c: *Compiler, unary_expr: *ast.UnaryExpression, dest_reg: i32, schema: ?*const Schema) CompileError!void {
    const operand_reg = c.alloc_reg();
    try compile_expression(c, unary_expr.right, operand_reg, schema);

    const op = unary_expr.operator;
    if (std.mem.eql(u8, op, "NOT")) {
        _ = try c.emit(.not, operand_reg, dest_reg, 0, "", null);
    } else if (std.mem.eql(u8, op, "-")) {
        _ = try c.emit(.integer, dest_reg, 0, 0, "", null);
        _ = try c.emit(.sub, dest_reg, operand_reg, dest_reg, "", null);
    }
}

fn compile_between(c: *Compiler, bet: *ast.BetweenExpression, dest_reg: i32, schema: ?*const Schema) CompileError!void {
    const expr_reg = c.alloc_reg();
    const low_reg = c.alloc_reg();
    const high_reg = c.alloc_reg();
    const temp1 = c.alloc_reg();
    const temp2 = c.alloc_reg();

    try compile_expression(c, bet.expr, expr_reg, schema);
    try compile_expression(c, bet.low, low_reg, schema);
    try compile_expression(c, bet.high, high_reg, schema);

    _ = try c.emit(.ge, expr_reg, low_reg, temp1, "", null);
    _ = try c.emit(.le, expr_reg, high_reg, temp2, "", null);
    _ = try c.emit(.@"and", temp1, temp2, dest_reg, "", null);

    if (bet.negated) {
        _ = try c.emit(.not, dest_reg, dest_reg, 0, "", null);
    }
}

fn compile_in_list(c: *Compiler, in: *ast.InListExpression, dest_reg: i32, schema: ?*const Schema) CompileError!void {
    const expr_reg = c.alloc_reg();
    try compile_expression(c, in.expr, expr_reg, schema);

    const list_ptr = c.allocator.create(ast.InListExpression) catch return CompileError.OutOfMemory;
    list_ptr.* = in.*;

    _ = try c.emit(.in_list, expr_reg, dest_reg, if (in.negated) 1 else 0, "", @ptrCast(list_ptr));
}

fn compile_in_subquery(c: *Compiler, in_sub: *ast.InSubqueryExpression, dest_reg: i32, schema: ?*const Schema) CompileError!void {
    const expr_reg = c.alloc_reg();
    try compile_expression(c, in_sub.expr, expr_reg, schema);

    const sub_ptr = c.allocator.create(ast.InSubqueryExpression) catch return CompileError.OutOfMemory;
    sub_ptr.* = in_sub.*;

    _ = try c.emit(.in_subquery, expr_reg, dest_reg, if (in_sub.negated) 1 else 0, "", @ptrCast(sub_ptr));
}

fn compile_like(c: *Compiler, lk: *ast.LikeExpression, dest_reg: i32, schema: ?*const Schema) CompileError!void {
    const expr_reg = c.alloc_reg();
    const pattern_reg = c.alloc_reg();

    try compile_expression(c, lk.expr, expr_reg, schema);
    try compile_expression(c, lk.pattern, pattern_reg, schema);

    _ = try c.emit(.like, expr_reg, pattern_reg, dest_reg, if (lk.negated) "NOT" else "", null);
}

fn compile_is_null(c: *Compiler, isn: *ast.IsNullExpression, dest_reg: i32, schema: ?*const Schema) CompileError!void {
    const expr_reg = c.alloc_reg();
    try compile_expression(c, isn.expr, expr_reg, schema);

    _ = try c.emit(.is_null, expr_reg, dest_reg, if (isn.negated) 1 else 0, "", null);
}

fn get_column_index(name: []const u8) i32 {
    if (std.mem.eql(u8, name, "id")) return 0;
    if (std.mem.eql(u8, name, "username")) return 1;
    if (std.mem.eql(u8, name, "email")) return 2;
    return 0;
}

fn get_schema_column_index(schema: *const Schema, name: []const u8) i32 {
    for (schema.columns, 0..) |col, i| {
        if (std.mem.eql(u8, col.name, name)) {
            return @intCast(i);
        }
    }
    return 0;
}

fn compile_case(c: *Compiler, case: *ast.CaseExpression, dest_reg: i32, schema: ?*const Schema) CompileError!void {
    var end_jumps = std.ArrayList(usize){};
    defer end_jumps.deinit(c.allocator);

    const operand_reg = if (case.operand) |op| blk: {
        const reg = c.alloc_reg();
        try compile_expression(c, op, reg, schema);
        break :blk reg;
    } else null;

    for (case.when_clauses) |when| {
        const cond_reg = c.alloc_reg();

        if (operand_reg) |op_reg| {
            const when_val_reg = c.alloc_reg();
            try compile_expression(c, when.condition, when_val_reg, schema);
            _ = try c.emit(.eq, op_reg, when_val_reg, cond_reg, "", null);
        } else {
            try compile_expression(c, when.condition, cond_reg, schema);
        }

        const skip_addr = try c.emit(.if_zero, cond_reg, 0, 0, "", null);

        try compile_expression(c, when.result, dest_reg, schema);

        const end_jump = try c.emit(.goto, 0, 0, 0, "", null);
        try end_jumps.append(c.allocator, end_jump);

        c.patch(skip_addr, @intCast(c.instructions.items.len));
    }

    if (case.else_result) |else_expr| {
        try compile_expression(c, else_expr, dest_reg, schema);
    } else {
        _ = try c.emit(.null, dest_reg, 0, 0, "", null);
    }

    const end_addr: i32 = @intCast(c.instructions.items.len);
    for (end_jumps.items) |jump_addr| {
        c.instructions.items[jump_addr].p2 = end_addr;
    }
}
