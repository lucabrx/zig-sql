const std = @import("std");
const Compiler = @import("compiler.zig").Compiler;
const ast = @import("../parser/ast.zig");
const DeleteStatement = ast.DeleteStatement;
const CompilerError = @import("errors.zig").CompilerError;
const expression = @import("expression.zig");

pub fn compile_delete(c: *Compiler, stmt: DeleteStatement) !void {
    const table = c.db.get_table(stmt.table) catch return CompilerError.TableNotFound;
    const schema = table.schema;

    _ = try c.emit(.open_write, 0, 0, 0, stmt.table, null);

    const rewind_addr = try c.emit(.rewind, 0, 0, 0, "", null);

    const loop_start = c.current_addr();

    var skip_addr: ?usize = null;
    if (stmt.where) |where_expr| {
        const cond_reg = c.alloc_reg();
        try expression.compile_expression(c, where_expr, cond_reg, schema);
        skip_addr = try c.emit(.if_zero, cond_reg, 0, 0, "", null);
    }

    _ = try c.emit(.delete, 0, 0, 0, "", null);

    _ = try c.emit(.next, 0, @intCast(loop_start), 0, "", null);

    if (skip_addr) |addr| {
        c.patch(addr, @intCast(c.current_addr()));
        _ = try c.emit(.next, 0, @intCast(loop_start), 0, "", null);
    }

    const close_addr = c.current_addr();
    _ = try c.emit(.close, 0, 0, 0, "", null);
    c.patch(rewind_addr, @intCast(close_addr));
}

test "compile delete without where" {
    const allocator = std.testing.allocator;
    const Pager = @import("../storage/pager.zig").Pager;
    const DB = @import("../storage/table.zig").Database;
    const Opcode = @import("../vm/opcode.zig").Opcode;
    const schema_mod = @import("../storage/schema.zig");

    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try DB.init(allocator, &pager);
    defer db.close();

    const columns = [_]schema_mod.Column{
        .{ .name = "id", .type = .Integer, .primary_key = true, .not_null = true },
    };
    const cols_slice: []schema_mod.Column = @constCast(&columns);
    const schema = schema_mod.Schema.init("test", cols_slice);
    _ = try db.create_table(&schema);

    var compiler = Compiler.init(allocator, &db);
    defer compiler.deinit();

    const stmt = DeleteStatement{
        .table = "test",
        .where = null,
    };

    try compile_delete(&compiler, stmt);

    try std.testing.expect(compiler.instructions.items.len >= 5);
    try std.testing.expectEqual(Opcode.open_write, compiler.instructions.items[0].op);
    try std.testing.expectEqual(Opcode.rewind, compiler.instructions.items[1].op);
    try std.testing.expectEqual(Opcode.delete, compiler.instructions.items[2].op);
    try std.testing.expectEqual(Opcode.next, compiler.instructions.items[3].op);
    try std.testing.expectEqual(Opcode.close, compiler.instructions.items[4].op);
}
