const std = @import("std");

pub fn main() !void {
    var buffer: [100]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    const writer = &stdout.interface;
    _ = try writer.write("hello, world!\n");
    try writer.flush();
}
