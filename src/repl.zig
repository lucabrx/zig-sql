const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const token = @import("lexer/token.zig");

pub const MetaCommandResult = enum {
    Success,
    Unrecognized,
    Exit,
};

pub const REPL = struct {
    db_path: []const u8,
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,

    pub fn init(db_path: []const u8, writer: *std.Io.Writer, reader: *std.Io.Reader) REPL {
        return REPL{
            .db_path = db_path,
            .writer = writer,
            .reader = reader,
        };
    }

    pub fn run(self: *REPL) !void {
        while (true) {
            _ = try self.writer.write(">zql ");
            try self.writer.flush();

            const line = try self.reader.takeDelimiter('\n') orelse break;
            const trimmed = std.mem.trimRight(u8, line, "\r");

            if (std.mem.startsWith(u8, trimmed, ".")) {
                const result = try self.execute_meta_command(trimmed);
                try self.writer.flush();
                if (result == .Exit) {
                    break;
                }
            } else {
                try self.execute_statement(trimmed);
            }
        }
    }

    fn print_help(self: *REPL) !void {
        _ = try self.writer.writeAll(
            \\Meta commands:
            \\ .exit - Exit this program
            \\ .help Show this help message
            \\ .tables List all tables
            \\
        );
    }

    fn execute_meta_command(self: *REPL, cmd: []const u8) !MetaCommandResult {
        const MetaCmd = enum {
            exit,
            help,
            tables,
        };

        const command = std.meta.stringToEnum(MetaCmd, cmd[1..]) orelse {
            try self.writer.writeAll("Unrecognized command\n");
            return .Unrecognized;
        };

        switch (command) {
            .exit => {
                try self.writer.writeAll("Goodbye!\n");
                return .Exit;
            },
            .help => {
                try self.print_help();
                return .Success;
            },
            .tables => {
                try self.writer.writeAll("Tables:\n");
                return .Success;
            },
        }
    }

    fn execute_statement(self: *REPL, input: []const u8) !void {
        var l = lexer.Lexer.init(input);
        const allocator = std.heap.page_allocator;

        const tokens = try l.tokenize(allocator);
        defer allocator.free(tokens);

        _ = try self.writer.write("[DEBUG] Tokens: \n");
        for (tokens) |t| {
            if (t.type == token.TokenType.eof) {
                break;
            }
            var buf: [128]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "TYPE: {} - Literal: {s}\n", .{ t.type, t.literal });
            _ = try self.writer.write(msg);

            if (tokens.len == 0) {
                return;
            }

            switch (tokens[0].type) {
                .select => {
                    _ = try self.writer.write("SELECT statement\n");
                },
                .insert => {
                    _ = try self.writer.write("INSERT statement\n");
                },
                else => {
                    var b: [128]u8 = undefined;
                    const m = try std.fmt.bufPrint(&b, "Unrecognized keyword at start of '{s}'.\n", .{input});
                    _ = try self.writer.write(m);
                },
            }
        }
        try self.writer.flush();
    }
};
