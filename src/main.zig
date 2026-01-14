const std = @import("std");
const repl = @import("repl.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){}; // not sure if this is best option
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdin_buffer: [1024]u8 = undefined;

    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    var stdin = std.fs.File.stdin().reader(&stdin_buffer);

    const writer = &stdout.interface;
    const reader = &stdin.interface;

    var r = repl.REPL.init(allocator, ":memory:", writer, reader);
    try r.run();
}

test {
    _ = @import("helpers.zig");
    _ = @import("lexer/lexer.zig");
    _ = @import("lexer/token.zig");
    _ = @import("parser/ast.zig");
    _ = @import("parser/parser.zig");
    _ = @import("storage/node.zig");
    _ = @import("storage/pager.zig");
    _ = @import("storage/row.zig");
    _ = @import("storage/cursor.zig");
    _ = @import("storage/btree.zig");
    _ = @import("storage/table.zig");
    _ = @import("vm/opcode.zig");
    _ = @import("vm/vm.zig");
    _ = @import("compiler/compiler.zig");
    _ = @import("compiler/schema.zig");
    _ = @import("compiler/insert.zig");
    _ = @import("compiler/delete.zig");
}
