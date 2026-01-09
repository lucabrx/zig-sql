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

test "compile value expressions" {
    const allocator = std.testing.allocator;
    const Pager = @import("../storage/pager.zig").Pager;
    const DB = @import("../storage/table.zig").Database;
    const Opcode = @import("../vm/opcode.zig").Opcode;

    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try DB.init(allocator, &pager);
    defer db.close();

    var compiler = Compiler.init(allocator, &db);
    defer compiler.deinit();

    // Test integer literal
    try compile_value_expression(&compiler, .{ .integer_literal = .{ .value = 42 } }, 0);
    try std.testing.expectEqual(Opcode.integer, compiler.instructions.items[0].op);
    try std.testing.expectEqual(42, compiler.instructions.items[0].p2);

    // Test string literal
    try compile_value_expression(&compiler, .{ .string_literal = .{ .value = "hello" } }, 1);
    try std.testing.expectEqual(Opcode.string, compiler.instructions.items[1].op);
    try std.testing.expectEqualStrings("hello", compiler.instructions.items[1].p4);

    // Test null literal
    try compile_value_expression(&compiler, .{ .null_literal = .{} }, 2);
    try std.testing.expectEqual(Opcode.null, compiler.instructions.items[2].op);
}
