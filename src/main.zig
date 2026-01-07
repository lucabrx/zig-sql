const std = @import("std");
const greeter = @import("greeter.zig");

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined; // 4kb
    var stdin_buffer: [1024]u8 = undefined; // 1kb

    var stdout = std.fs.File.stdout().writer(&stdout_buffer);
    var stdin = std.fs.File.stdin().reader(&stdin_buffer);

    const writer = &stdout.interface;
    var reader = &stdin.interface;

    _ = try writer.write(greeter.greet());
    _ = try writer.write("\n");
    try writer.flush();

    while (true) {
        _ = try writer.write(">zql ");
        try writer.flush(); // Flush the prompt to the output and clear the buffer

        const line = try reader.takeDelimiter('\n') orelse break;
        // enter = \r\n = if not that we would get exit\r
        const trimmed = std.mem.trimRight(u8, line, "\r");

        if (std.mem.eql(u8, trimmed, ".exit")) {
            _ = try writer.write("Goodbye!\n");
            try writer.flush();
            break;
        }

        _ = try writer.write(trimmed);
        _ = try writer.write("\n");
        try writer.flush();
    }
}
