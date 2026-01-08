const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const token = @import("lexer/token.zig");
const parser = @import("parser/parser.zig");
const ast = @import("parser/ast.zig");

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
        }

        var p = parser.Parser.init(tokens, allocator);
        const stmt = p.parse() catch |err| {
            try self.writer.print("Parse error: {s}\n", .{@errorName(err)});
            if (p.hasErrors()) {
                try p.printErrors(self.writer);
            }
            return;
        };

        try self.print_ast(stmt);
        try self.writer.flush();
    }

    fn print_ast(self: *REPL, stmt: ast.Statement) !void {
        switch (stmt) {
            .create_table_stmt => |create_stmt| {
                try self.writer.print("CREATE TABLE {s}\n", .{create_stmt.table});
                try self.writer.writeAll("Columns:\n");
                for (create_stmt.columns) |col| {
                    try self.writer.print("  - {s} {s}", .{ col.name, col.type_name });
                    if (col.primary_key) {
                        try self.writer.writeAll(" PRIMARY KEY");
                    }
                    if (col.not_null) {
                        try self.writer.writeAll(" NOT NULL");
                    }
                    try self.writer.writeAll("\n");
                }
            },
            .insert_stmt => |insert_stmt| {
                try self.writer.print("INSERT INTO {s}\n", .{insert_stmt.table});
                try self.writer.writeAll("Columns:\n");
                for (insert_stmt.columns) |col| {
                    try self.writer.print("  - {s}\n", .{col});
                }
                try self.writer.writeAll("Values:\n");
                for (insert_stmt.values) |val| {
                    switch (val) {
                        .integer_literal => |int_lit| try self.writer.print("  - {d}\n", .{int_lit.value}),
                        .float_literal => |float_lit| try self.writer.print("  - {d}\n", .{float_lit.value}),
                        .string_literal => |str_lit| try self.writer.print("  - '{s}'\n", .{str_lit.value}),
                        .null_literal => try self.writer.writeAll("  - NULL\n"),
                        .identifier => |ident| try self.writer.print("  - {s}\n", .{ident.name}),
                        else => try self.writer.print("  - {any}\n", .{val}),
                    }
                }
            },
            else => {
                try self.writer.writeAll("Statement type not yet supported in REPL\n");
            },
        }
    }
};
