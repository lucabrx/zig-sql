const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const token = @import("lexer/token.zig");
const parser = @import("parser/parser.zig");
const ast = @import("parser/ast.zig");
const Compiler = @import("compiler/compiler.zig").Compiler;
const VM = @import("vm/vm.zig").VM;
const RegisterValue = @import("vm/vm.zig").RegisterValue;
const Pager = @import("storage/pager.zig").Pager;
const Database = @import("storage/table.zig").Database;

pub const MetaCommandResult = enum {
    Success,
    Unrecognized,
    Exit,
};

pub const REPL = struct {
    db_path: []const u8,
    writer: *std.Io.Writer,
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
    pager: ?*Pager,
    db: ?*Database,
    debug_mode: bool,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8, writer: *std.Io.Writer, reader: *std.Io.Reader) REPL {
        return REPL{
            .db_path = db_path,
            .writer = writer,
            .reader = reader,
            .allocator = allocator,
            .pager = null,
            .db = null,
            .debug_mode = false,
        };
    }

    pub fn start(self: *REPL) !void {
        const pager = try self.allocator.create(Pager);
        pager.* = try Pager.init(self.allocator, self.db_path);
        self.pager = pager;

        const db = try self.allocator.create(Database);
        db.* = try Database.initWithFilename(self.allocator, pager, self.db_path);
        self.db = db;

        try self.writer.print("ZQL Database v0.1\n", .{});
        try self.writer.print("Connected to: {s}\n", .{self.db_path});
        try self.writer.print("Type .help for commands\n\n", .{});
        try self.writer.flush();
    }

    pub fn shutdown(self: *REPL) void {
        if (self.db) |db| {
            db.close();
            self.allocator.destroy(db);
            self.db = null;
        }
        if (self.pager) |pager| {
            pager.deinit();
            self.allocator.destroy(pager);
            self.pager = null;
        }
    }

    pub fn run(self: *REPL) !void {
        try self.start();
        defer self.shutdown();

        while (true) {
            _ = try self.writer.write("zql> ");
            try self.writer.flush();

            const line = try self.reader.takeDelimiter('\n') orelse break;
            const trimmed = std.mem.trimRight(u8, line, "\r");

            if (trimmed.len == 0) continue;

            if (std.mem.startsWith(u8, trimmed, ".")) {
                const result = try self.execute_meta_command(trimmed);
                try self.writer.flush();
                if (result == .Exit) {
                    break;
                }
            } else {
                self.execute_statement(trimmed) catch |err| {
                    try self.writer.print("Error: {s}\n", .{@errorName(err)});
                };
                try self.writer.flush();
            }
        }
    }

    fn print_help(self: *REPL) !void {
        _ = try self.writer.writeAll(
            \\Meta commands:
            \\ .exit       - Exit this program
            \\ .help       - Show this help message
            \\ .tables     - List all tables
            \\ .indexes    - List all indexes
            \\ .debug      - Toggle debug mode
            \\ .checkpoint - Force WAL checkpoint
            \\ .sync       - Sync all pages to disk
            \\
        );
    }

    fn execute_meta_command(self: *REPL, cmd: []const u8) !MetaCommandResult {
        const MetaCmd = enum {
            exit,
            help,
            tables,
            indexes,
            debug,
            checkpoint,
            sync,
        };

        const command = std.meta.stringToEnum(MetaCmd, cmd[1..]) orelse {
            try self.writer.writeAll("Unrecognized command. Type .help for available commands.\n");
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
            .checkpoint => {
                const db = self.db orelse return .Success;
                db.wal_checkpoint() catch |err| {
                    try self.writer.print("Checkpoint error: {s}\n", .{@errorName(err)});
                    return .Success;
                };
                try self.writer.writeAll("Checkpoint complete.\n");
                return .Success;
            },
            .sync => {
                const pager = self.pager orelse return .Success;
                pager.sync() catch |err| {
                    try self.writer.print("Sync error: {s}\n", .{@errorName(err)});
                    return .Success;
                };
                try self.writer.writeAll("Sync complete.\n");
                return .Success;
            },
            .tables => {
                try self.list_tables();
                return .Success;
            },
            .indexes => {
                try self.list_indexes();
                return .Success;
            },
            .debug => {
                self.debug_mode = !self.debug_mode;
                try self.writer.print("Debug mode: {s}\n", .{if (self.debug_mode) "ON" else "OFF"});
                return .Success;
            },
        }
    }

    fn list_tables(self: *REPL) !void {
        const db = self.db orelse return;
        const tables = try db.list_tables();
        defer self.allocator.free(tables);

        if (tables.len == 0) {
            try self.writer.writeAll("No tables found.\n");
            return;
        }

        try self.writer.writeAll("Tables:\n");
        for (tables) |name| {
            try self.writer.print("  {s}\n", .{name});
        }
    }

    fn list_indexes(self: *REPL) !void {
        const db = self.db orelse return;
        const indexes = try db.list_indexes();
        defer self.allocator.free(indexes);

        if (indexes.len == 0) {
            try self.writer.writeAll("No indexes found.\n");
            return;
        }

        try self.writer.writeAll("Indexes:\n");
        for (indexes) |name| {
            try self.writer.print("  {s}\n", .{name});
        }
    }

    fn execute_statement(self: *REPL, input: []const u8) !void {
        const db = self.db orelse return error.DatabaseNotInitialized;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const temp_allocator = arena.allocator();

        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(temp_allocator);

        if (tokens.len == 0) return;

        if (self.debug_mode) {
            try self.writer.writeAll("[DEBUG] Tokens:\n");
            for (tokens) |t| {
                if (t.type == token.TokenType.eof) break;
                try self.writer.print("  {s}: '{s}'\n", .{ @tagName(t.type), t.literal });
            }
        }

        var p = parser.Parser.init(tokens, temp_allocator);
        const stmt = p.parse() catch |err| {
            try self.writer.print("Parse error: {s}\n", .{@errorName(err)});
            if (p.hasErrors()) {
                try p.printErrors(self.writer);
            }
            return;
        };

        if (self.debug_mode) {
            try self.writer.writeAll("[DEBUG] AST:\n");
            try self.print_ast(stmt);
        }

        var compiler = Compiler.init(temp_allocator, self.allocator, db);
        defer compiler.deinit();

        const instructions = compiler.compile(stmt) catch |err| {
            try self.writer.print("Compile error: {s}\n", .{@errorName(err)});
            return;
        };

        if (self.debug_mode) {
            try self.writer.writeAll("[DEBUG] Bytecode:\n");
            for (instructions, 0..) |inst, i| {
                try self.writer.print("  {d:3}: {s} p1={d} p2={d} p3={d}", .{
                    i,
                    inst.op.to_string(),
                    inst.p1,
                    inst.p2,
                    inst.p3,
                });
                if (inst.p4.len > 0) {
                    try self.writer.print(" p4=\"{s}\"", .{inst.p4});
                }
                try self.writer.writeAll("\n");
            }
        }

        var vm = VM.init(self.allocator, db);
        vm.set_debug(self.debug_mode);
        defer vm.deinit();

        vm.load(instructions);
        vm.run() catch |err| {
            try self.writer.print("Runtime error: {s}\n", .{@errorName(err)});
            return;
        };

        const results = vm.get_results();
        if (results.len > 0) {
            try self.print_results(results);
        } else {
            try self.writer.writeAll("OK\n");
        }
    }

    fn print_results(self: *REPL, results: [][]RegisterValue) !void {
        for (results) |row| {
            for (row, 0..) |val, i| {
                if (i > 0) try self.writer.writeAll(" | ");
                switch (val.type) {
                    .integer => try self.writer.print("{d}", .{val.integer}),
                    .real => try self.writer.print("{d:.2}", .{val.real}),
                    .text => try self.writer.print("{s}", .{val.text}),
                    .blob => {
                        try self.writer.writeAll("BLOB(");
                        for (val.blob) |byte| {
                            try self.writer.print("{X:0>2}", .{byte});
                        }
                        try self.writer.writeAll(")");
                    },
                    .boolean => try self.writer.print("{s}", .{if (val.boolean) "TRUE" else "FALSE"}),
                    .null => try self.writer.writeAll("NULL"),
                }
            }
            try self.writer.writeAll("\n");
        }
        try self.writer.print("({d} rows)\n", .{results.len});
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
            .create_index_stmt => |idx_stmt| {
                try self.writer.print("CREATE{s} INDEX {s} ON {s}\n", .{
                    if (idx_stmt.unique) " UNIQUE" else "",
                    idx_stmt.index_name,
                    idx_stmt.table,
                });
                try self.writer.writeAll("Columns:\n");
                for (idx_stmt.columns) |col| {
                    try self.writer.print("  - {s}\n", .{col});
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
            .select_stmt => |select_stmt| {
                try self.writer.print("SELECT Statement\n", .{});
                try self.writer.writeAll("Columns:\n");
                for (select_stmt.columns) |col| {
                    switch (col) {
                        .star_expression => try self.writer.writeAll("  - *\n"),
                        .identifier => |ident| try self.writer.print("  - {s}\n", .{ident.name}),
                        else => try self.writer.writeAll("  - <expression>\n"),
                    }
                }
                try self.writer.print("From Table: {s}\n", .{select_stmt.from});
                if (select_stmt.joins.len > 0) {
                    try self.writer.writeAll("Joins:\n");
                    for (select_stmt.joins) |join| {
                        const join_type_str = switch (join.join_type) {
                            .inner => "INNER",
                            .left => "LEFT",
                            .right => "RIGHT",
                            .cross => "CROSS",
                        };
                        try self.writer.print("  - {s} JOIN {s}\n", .{ join_type_str, join.table });
                    }
                }
            },
            .update_stmt => |update_stmt| {
                try self.writer.print("UPDATE {s}\n", .{update_stmt.table});
                try self.writer.writeAll("Set:\n");
                for (update_stmt.set) |assignment| {
                    switch (assignment.value) {
                        .integer_literal => |int_lit| try self.writer.print("  - {s} = {d}\n", .{ assignment.column, int_lit.value }),
                        .string_literal => |str_lit| try self.writer.print("  - {s} = '{s}'\n", .{ assignment.column, str_lit.value }),
                        else => try self.writer.print("  - {s} = <expression>\n", .{assignment.column}),
                    }
                }
                if (update_stmt.where) |where| {
                    try self.writer.writeAll("Where: ");
                    try self.format_expression(where);
                    try self.writer.writeAll("\n");
                }
            },
            .delete_stmt => |delete_stmt| {
                try self.writer.print("DELETE FROM {s}\n", .{delete_stmt.table});
                if (delete_stmt.where) |where| {
                    try self.writer.writeAll("Where: ");
                    try self.format_expression(where);
                    try self.writer.writeAll("\n");
                }
            },
            .drop_table_stmt => |drop_stmt| {
                try self.writer.print("DROP TABLE", .{});
                if (drop_stmt.if_exists) {
                    try self.writer.writeAll(" IF EXISTS");
                }
                try self.writer.print(" {s}\n", .{drop_stmt.table});
            },
            .drop_index_stmt => |drop_stmt| {
                try self.writer.print("DROP INDEX", .{});
                if (drop_stmt.if_exists) {
                    try self.writer.writeAll(" IF EXISTS");
                }
                try self.writer.print(" {s}\n", .{drop_stmt.index_name});
            },
            .begin_stmt => {
                try self.writer.writeAll("BEGIN TRANSACTION\n");
            },
            .commit_stmt => {
                try self.writer.writeAll("COMMIT\n");
            },
            .rollback_stmt => |rs| {
                if (rs.savepoint_name) |name| {
                    try self.writer.print("ROLLBACK TO SAVEPOINT {s}\n", .{name});
                } else {
                    try self.writer.writeAll("ROLLBACK\n");
                }
            },
            .savepoint_stmt => |sp| {
                try self.writer.print("SAVEPOINT {s}\n", .{sp.name});
            },
            .release_savepoint_stmt => |sp| {
                try self.writer.print("RELEASE SAVEPOINT {s}\n", .{sp.name});
            },
            .set_transaction_stmt => |st| {
                const level_str = switch (st.isolation_level) {
                    .read_uncommitted => "READ UNCOMMITTED",
                    .read_committed => "READ COMMITTED",
                    .repeatable_read => "REPEATABLE READ",
                    .serializable => "SERIALIZABLE",
                };
                try self.writer.print("SET TRANSACTION ISOLATION LEVEL {s}\n", .{level_str});
            },
        }
    }

    fn format_expression(self: *REPL, expr: ast.Expression) !void {
        switch (expr) {
            .identifier => |ident| try self.writer.print("{s}", .{ident.name}),
            .integer_literal => |int_lit| try self.writer.print("{d}", .{int_lit.value}),
            .float_literal => |float_lit| try self.writer.print("{d}", .{float_lit.value}),
            .string_literal => |str_lit| try self.writer.print("'{s}'", .{str_lit.value}),
            .null_literal => try self.writer.writeAll("NULL"),
            .star_expression => try self.writer.writeAll("*"),
            .boolean_literal => |bool_lit| try self.writer.print("{s}", .{if (bool_lit.value) "TRUE" else "FALSE"}),
            .binary_expression => |bin_expr| {
                try self.format_expression(bin_expr.left);
                try self.writer.print(" {s} ", .{bin_expr.operator});
                try self.format_expression(bin_expr.right);
            },
            .unary_expression => |unary_expr| {
                try self.writer.print("{s} ", .{unary_expr.operator});
                try self.format_expression(unary_expr.right);
            },
            .subquery => try self.writer.writeAll("(SUBQUERY)"),
            .aggregate => |agg| {
                const func_name = switch (agg.function) {
                    .count => "COUNT",
                    .sum => "SUM",
                    .avg => "AVG",
                    .min => "MIN",
                    .max => "MAX",
                };
                try self.writer.print("{s}(...)", .{func_name});
            },
            .between => try self.writer.writeAll("BETWEEN ..."),
            .in_list => try self.writer.writeAll("IN (...)"),
            .in_subquery => try self.writer.writeAll("IN (SUBQUERY)"),
            .like => try self.writer.writeAll("LIKE ..."),
            .is_null => try self.writer.writeAll("IS NULL"),
            .case_expr => try self.writer.writeAll("CASE ... END"),
        }
    }
};
