const std = @import("std");

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

    fn execute_statement(self: *REPL, stmt: []const u8) !void {
        const Statement = enum {
            select,
            insert,
            create_table,
        };

        var statement: ?Statement = null;
        inline for (@typeInfo(Statement).@"enum".fields) |f| {
            if (std.ascii.eqlIgnoreCase(stmt, f.name)) {
                statement = @enumFromInt(f.value);
                break;
            }
        }

        if (statement) |s| {
            switch (s) {
                .select => {
                    _ = try self.writer.write("SELECT statement\n");
                },
                .insert => {
                    _ = try self.writer.write("INSERT statement\n");
                },
                .create_table => {
                    _ = try self.writer.write("CREATE TABLE statement\n");
                },
            }
        } else {
            _ = try self.writer.write("Unrecognized statement\n");
        }
        try self.writer.flush();
    }
};
