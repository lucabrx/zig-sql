const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const token = @import("lexer/token.zig");
const parser = @import("parser/parser.zig");
const ast = @import("parser/ast.zig");
const Compiler = @import("compiler/compiler.zig").Compiler;
const VM = @import("vm/vm.zig").VM;
const RegisterValue = @import("vm/vm.zig").RegisterValue;
const Instruction = @import("vm/opcode.zig").Instruction;
const Pager = @import("storage/pager.zig").Pager;
const Database = @import("storage/table.zig").Database;
const posix = std.posix;

const HISTORY_SIZE = 100;
const STMT_CACHE_SIZE = 64;
const RESULT_CACHE_SIZE = 32;

const CachedStatement = struct {
    sql_hash: u64,
    instructions: []Instruction,
    strings: [][]const u8,
};

const CachedResult = struct {
    sql_hash: u64,
    rows: [][]RegisterValue,
    strings: [][]const u8,
};

const ResultCache = struct {
    entries: [RESULT_CACHE_SIZE]?CachedResult,
    allocator: std.mem.Allocator,
    hits: u64,
    misses: u64,
    enabled: bool,

    fn init(allocator: std.mem.Allocator) ResultCache {
        return .{
            .entries = [_]?CachedResult{null} ** RESULT_CACHE_SIZE,
            .allocator = allocator,
            .hits = 0,
            .misses = 0,
            .enabled = true,
        };
    }

    fn deinit(self: *ResultCache) void {
        self.clear();
    }

    fn clear(self: *ResultCache) void {
        for (&self.entries) |*entry| {
            if (entry.*) |cached| {
                for (cached.strings) |s| {
                    self.allocator.free(s);
                }
                self.allocator.free(cached.strings);
                for (cached.rows) |row| {
                    self.allocator.free(row);
                }
                self.allocator.free(cached.rows);
            }
            entry.* = null;
        }
    }

    fn get(self: *ResultCache, sql: []const u8) ?[][]RegisterValue {
        if (!self.enabled) return null;
        const hash = std.hash.Wyhash.hash(0, sql);
        const idx = hash % RESULT_CACHE_SIZE;
        if (self.entries[idx]) |cached| {
            if (cached.sql_hash == hash) {
                self.hits += 1;
                return cached.rows;
            }
        }
        self.misses += 1;
        return null;
    }

    fn put(self: *ResultCache, sql: []const u8, results: [][]RegisterValue) !void {
        if (!self.enabled) return;
        const hash = std.hash.Wyhash.hash(0, sql);
        const idx = hash % RESULT_CACHE_SIZE;

        if (self.entries[idx]) |old| {
            for (old.strings) |s| {
                self.allocator.free(s);
            }
            self.allocator.free(old.strings);
            for (old.rows) |row| {
                self.allocator.free(row);
            }
            self.allocator.free(old.rows);
        }

        var strings = std.ArrayList([]const u8){};
        const new_rows = try self.allocator.alloc([]RegisterValue, results.len);
        for (results, 0..) |row, i| {
            new_rows[i] = try self.allocator.alloc(RegisterValue, row.len);
            for (row, 0..) |val, j| {
                new_rows[i][j] = val;
                if (val.type == .text and val.text.len > 0) {
                    const owned = try self.allocator.dupe(u8, val.text);
                    try strings.append(self.allocator, owned);
                    new_rows[i][j].text = owned;
                }
            }
        }

        self.entries[idx] = .{
            .sql_hash = hash,
            .rows = new_rows,
            .strings = try strings.toOwnedSlice(self.allocator),
        };
    }

    fn invalidate(self: *ResultCache) void {
        self.clear();
    }
};

const StmtCache = struct {
    entries: [STMT_CACHE_SIZE]?CachedStatement,
    allocator: std.mem.Allocator,
    hits: u64,
    misses: u64,

    fn init(allocator: std.mem.Allocator) StmtCache {
        return .{
            .entries = [_]?CachedStatement{null} ** STMT_CACHE_SIZE,
            .allocator = allocator,
            .hits = 0,
            .misses = 0,
        };
    }

    fn deinit(self: *StmtCache) void {
        for (&self.entries) |*entry| {
            if (entry.*) |cached| {
                for (cached.strings) |s| {
                    self.allocator.free(s);
                }
                self.allocator.free(cached.strings);
                self.allocator.free(cached.instructions);
            }
            entry.* = null;
        }
    }

    fn get(self: *StmtCache, sql: []const u8) ?[]const Instruction {
        const hash = std.hash.Wyhash.hash(0, sql);
        const idx = hash % STMT_CACHE_SIZE;
        if (self.entries[idx]) |cached| {
            if (cached.sql_hash == hash) {
                self.hits += 1;
                return cached.instructions;
            }
        }
        self.misses += 1;
        return null;
    }

    fn put(self: *StmtCache, sql: []const u8, instructions: []const Instruction) !void {
        const hash = std.hash.Wyhash.hash(0, sql);
        const idx = hash % STMT_CACHE_SIZE;

        if (self.entries[idx]) |old| {
            for (old.strings) |s| {
                self.allocator.free(s);
            }
            self.allocator.free(old.strings);
            self.allocator.free(old.instructions);
        }

        var strings = std.ArrayList([]const u8){};
        const new_insts = try self.allocator.alloc(Instruction, instructions.len);
        for (instructions, 0..) |inst, i| {
            new_insts[i] = inst;
            if (inst.p4.len > 0) {
                const owned = try self.allocator.dupe(u8, inst.p4);
                try strings.append(self.allocator, owned);
                new_insts[i].p4 = owned;
            }
        }

        self.entries[idx] = .{
            .sql_hash = hash,
            .instructions = new_insts,
            .strings = try strings.toOwnedSlice(self.allocator),
        };
    }
};

const LineEditor = struct {
    allocator: std.mem.Allocator,
    history: std.ArrayList([]const u8),
    history_pos: usize,
    line_buf: std.ArrayList(u8),
    cursor_pos: usize,
    orig_termios: ?posix.termios,
    tty: ?std.fs.File,

    const keywords = [_][]const u8{
        "SELECT",   "FROM",   "WHERE",  "INSERT",   "INTO",       "VALUES", "UPDATE",  "SET",
        "DELETE",   "CREATE", "TABLE",  "INDEX",    "DROP",       "ALTER",  "BEGIN",   "COMMIT",
        "ROLLBACK", "ORDER",  "BY",     "ASC",      "DESC",       "LIMIT",  "OFFSET",  "JOIN",
        "INNER",    "LEFT",   "RIGHT",  "ON",       "AND",        "OR",     "NOT",     "NULL",
        "PRIMARY",  "KEY",    "UNIQUE", "FOREIGN",  "REFERENCES", "CHECK",  "DEFAULT", "INTEGER",
        "TEXT",     "REAL",   "BLOB",   "BOOLEAN",  "COUNT",      "SUM",    "AVG",     "MIN",
        "MAX",      "GROUP",  "HAVING", "DISTINCT", "AS",         "LIKE",   "IN",      "BETWEEN",
        "CASE",     "WHEN",   "THEN",   "ELSE",     "END",        "UNION",  "VIEW",    "VACUUM",
    };

    const meta_commands = [_][]const u8{
        ".exit",  ".help",  ".tables", ".indexes", ".schema", ".views",      ".stats",
        ".table", ".debug", ".dump",   ".read",    ".import", ".checkpoint", ".sync",
        ".cache",
    };

    pub fn init(allocator: std.mem.Allocator) LineEditor {
        return .{
            .allocator = allocator,
            .history = std.ArrayList([]const u8){},
            .history_pos = 0,
            .line_buf = std.ArrayList(u8){},
            .cursor_pos = 0,
            .orig_termios = null,
            .tty = null,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        for (self.history.items) |h| {
            self.allocator.free(h);
        }
        self.history.deinit(self.allocator);
        self.line_buf.deinit(self.allocator);
        self.disableRawMode();
        if (self.tty) |tty| tty.close();
    }

    fn enableRawMode(self: *LineEditor) !void {
        if (self.tty == null) {
            self.tty = std.fs.cwd().openFile("/dev/tty", .{ .mode = .read_write }) catch |err| {
                return err;
            };
            const fd = self.tty.?.handle;
            self.orig_termios = posix.tcgetattr(fd) catch |err| {
                return err;
            };
        }
        const fd = self.tty.?.handle;
        var raw = self.orig_termios.?;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        posix.tcsetattr(fd, .FLUSH, raw) catch |err| {
            return err;
        };
    }

    fn disableRawMode(self: *LineEditor) void {
        if (self.orig_termios) |orig| {
            if (self.tty) |tty| {
                posix.tcsetattr(tty.handle, .FLUSH, orig) catch {};
            }
        }
    }

    pub fn readLine(self: *LineEditor, writer: anytype, prompt: []const u8) !?[]const u8 {
        const stdin_file = std.fs.File.stdin();
        if (!posix.isatty(stdin_file.handle)) {
            return self.readLineSimple(writer, prompt);
        }

        self.enableRawMode() catch {
            return self.readLineSimple(writer, prompt);
        };
        defer self.disableRawMode();

        const tty = self.tty orelse return self.readLineSimple(writer, prompt);

        self.line_buf.clearRetainingCapacity();
        self.cursor_pos = 0;
        self.history_pos = self.history.items.len;

        try writer.writeAll(prompt);
        try writer.flush();

        while (true) {
            var buf: [4]u8 = undefined;
            const n = tty.read(&buf) catch break;
            if (n == 0) break;

            if (buf[0] == '\n' or buf[0] == '\r') {
                try writer.writeAll("\n");
                try writer.flush();
                if (self.line_buf.items.len > 0) {
                    try self.addHistory(self.line_buf.items);
                }
                return try self.allocator.dupe(u8, self.line_buf.items);
            } else if (buf[0] == 4) {
                if (self.line_buf.items.len == 0) return null;
            } else if (buf[0] == 127 or buf[0] == 8) {
                if (self.cursor_pos > 0) {
                    _ = self.line_buf.orderedRemove(self.cursor_pos - 1);
                    self.cursor_pos -= 1;
                    try self.refreshLine(writer, prompt);
                }
            } else if (buf[0] == 27 and n >= 3 and buf[1] == '[') {
                switch (buf[2]) {
                    'A' => try self.historyPrev(writer, prompt),
                    'B' => try self.historyNext(writer, prompt),
                    'C' => {
                        if (self.cursor_pos < self.line_buf.items.len) {
                            self.cursor_pos += 1;
                            try writer.writeAll("\x1b[C");
                            try writer.flush();
                        }
                    },
                    'D' => {
                        if (self.cursor_pos > 0) {
                            self.cursor_pos -= 1;
                            try writer.writeAll("\x1b[D");
                            try writer.flush();
                        }
                    },
                    else => {},
                }
            } else if (buf[0] == '\t') {
                try self.handleTab(writer, prompt);
            } else if (buf[0] == 1) {
                self.cursor_pos = 0;
                try self.refreshLine(writer, prompt);
            } else if (buf[0] == 5) {
                self.cursor_pos = self.line_buf.items.len;
                try self.refreshLine(writer, prompt);
            } else if (buf[0] == 21) {
                self.line_buf.clearRetainingCapacity();
                self.cursor_pos = 0;
                try self.refreshLine(writer, prompt);
            } else if (buf[0] >= 32 and buf[0] < 127) {
                try self.line_buf.insert(self.allocator, self.cursor_pos, buf[0]);
                self.cursor_pos += 1;
                try self.refreshLine(writer, prompt);
            }
        }
        return null;
    }

    fn readLineSimple(self: *LineEditor, writer: anytype, prompt: []const u8) !?[]const u8 {
        try writer.writeAll(prompt);
        try writer.flush();

        var line_buf: [4096]u8 = undefined;
        var pos: usize = 0;
        const stdin = std.fs.File.stdin();

        while (pos < line_buf.len) {
            var byte: [1]u8 = undefined;
            const n = stdin.read(&byte) catch return null;
            if (n == 0) {
                if (pos == 0) return null;
                break;
            }
            if (byte[0] == '\n') break;
            if (byte[0] != '\r') {
                line_buf[pos] = byte[0];
                pos += 1;
            }
        }

        if (pos > 0) {
            try self.addHistory(line_buf[0..pos]);
        }
        return try self.allocator.dupe(u8, line_buf[0..pos]);
    }

    fn refreshLine(self: *LineEditor, writer: anytype, prompt: []const u8) !void {
        try writer.writeAll("\r\x1b[K");
        try writer.writeAll(prompt);
        try writer.writeAll(self.line_buf.items);
        const back = self.line_buf.items.len - self.cursor_pos;
        if (back > 0) {
            try writer.print("\x1b[{d}D", .{back});
        }
        try writer.flush();
    }

    fn addHistory(self: *LineEditor, line: []const u8) !void {
        if (line.len == 0) return;
        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, line)) return;
        }
        const copy = try self.allocator.dupe(u8, line);
        if (self.history.items.len >= HISTORY_SIZE) {
            self.allocator.free(self.history.items[0]);
            _ = self.history.orderedRemove(0);
        }
        try self.history.append(self.allocator, copy);
    }

    fn historyPrev(self: *LineEditor, writer: anytype, prompt: []const u8) !void {
        if (self.history.items.len == 0 or self.history_pos == 0) return;
        self.history_pos -= 1;
        self.line_buf.clearRetainingCapacity();
        try self.line_buf.appendSlice(self.allocator, self.history.items[self.history_pos]);
        self.cursor_pos = self.line_buf.items.len;
        try self.refreshLine(writer, prompt);
    }

    fn historyNext(self: *LineEditor, writer: anytype, prompt: []const u8) !void {
        if (self.history_pos >= self.history.items.len) return;
        self.history_pos += 1;
        self.line_buf.clearRetainingCapacity();
        if (self.history_pos < self.history.items.len) {
            try self.line_buf.appendSlice(self.allocator, self.history.items[self.history_pos]);
        }
        self.cursor_pos = self.line_buf.items.len;
        try self.refreshLine(writer, prompt);
    }

    fn handleTab(self: *LineEditor, writer: anytype, prompt: []const u8) !void {
        if (self.line_buf.items.len == 0) return;

        var word_start: usize = self.cursor_pos;
        while (word_start > 0 and self.line_buf.items[word_start - 1] != ' ') {
            word_start -= 1;
        }
        const prefix = self.line_buf.items[word_start..self.cursor_pos];
        if (prefix.len == 0) return;

        var matches = std.ArrayList([]const u8){};
        defer matches.deinit(self.allocator);

        if (std.mem.startsWith(u8, prefix, ".")) {
            for (meta_commands) |cmd| {
                if (startsWithIgnoreCase(cmd, prefix)) {
                    try matches.append(self.allocator, cmd);
                }
            }
        } else {
            for (keywords) |kw| {
                if (startsWithIgnoreCase(kw, prefix)) {
                    try matches.append(self.allocator, kw);
                }
            }
        }

        if (matches.items.len == 0) {
            return;
        } else if (matches.items.len == 1) {
            const completion = matches.items[0][prefix.len..];
            for (completion) |c| {
                try self.line_buf.insert(self.allocator, self.cursor_pos, c);
                self.cursor_pos += 1;
            }
            try self.line_buf.insert(self.allocator, self.cursor_pos, ' ');
            self.cursor_pos += 1;
            try self.refreshLine(writer, prompt);
        } else {
            const common = findCommonPrefix(matches.items, prefix.len);
            if (common.len > prefix.len) {
                const to_add = common[prefix.len..];
                for (to_add) |c| {
                    try self.line_buf.insert(self.allocator, self.cursor_pos, c);
                    self.cursor_pos += 1;
                }
                try self.refreshLine(writer, prompt);
            } else {
                try writer.writeAll("\r\n");
                for (matches.items) |m| {
                    try writer.print("{s}  ", .{m});
                }
                try writer.writeAll("\r\n");
                try writer.flush();
                try self.refreshLine(writer, prompt);
            }
        }
    }

    fn findCommonPrefix(items: []const []const u8, start: usize) []const u8 {
        if (items.len == 0) return "";
        if (items.len == 1) return items[0];

        const first = items[0];
        var common_len = first.len;

        for (items[1..]) |item| {
            var i: usize = start;
            while (i < common_len and i < item.len) {
                if (std.ascii.toLower(first[i]) != std.ascii.toLower(item[i])) {
                    break;
                }
                i += 1;
            }
            common_len = @min(common_len, i);
        }

        return first[0..common_len];
    }

    fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        for (haystack[0..needle.len], needle) |h, n| {
            if (std.ascii.toLower(h) != std.ascii.toLower(n)) return false;
        }
        return true;
    }
};

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
    stats_mode: bool,
    table_mode: bool,
    line_editor: LineEditor,
    stmt_cache: StmtCache,
    result_cache: ResultCache,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8, writer: *std.Io.Writer, reader: *std.Io.Reader) REPL {
        return REPL{
            .db_path = db_path,
            .writer = writer,
            .reader = reader,
            .allocator = allocator,
            .pager = null,
            .db = null,
            .debug_mode = false,
            .stats_mode = false,
            .table_mode = false,
            .line_editor = LineEditor.init(allocator),
            .stmt_cache = StmtCache.init(allocator),
            .result_cache = ResultCache.init(allocator),
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
        self.stmt_cache.deinit();
        self.result_cache.deinit();
        self.line_editor.deinit();
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

        var stmt_buffer = std.ArrayList(u8){};
        defer stmt_buffer.deinit(self.allocator);

        while (true) {
            const prompt = if (stmt_buffer.items.len == 0) "zql> " else "...> ";

            const line = self.line_editor.readLine(self.writer, prompt) catch |err| {
                if (err == error.EndOfStream) break;
                continue;
            } orelse break;
            defer self.allocator.free(line);

            const trimmed = std.mem.trimRight(u8, line, "\r\n");

            if (trimmed.len == 0) continue;

            if (stmt_buffer.items.len == 0 and std.mem.startsWith(u8, trimmed, ".")) {
                const result = try self.execute_meta_command(trimmed);
                try self.writer.flush();
                if (result == .Exit) {
                    break;
                }
                continue;
            }

            if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\\') {
                try stmt_buffer.appendSlice(self.allocator, trimmed[0 .. trimmed.len - 1]);
                try stmt_buffer.append(self.allocator, ' ');
                continue;
            }

            try stmt_buffer.appendSlice(self.allocator, trimmed);

            if (std.mem.endsWith(u8, trimmed, ";")) {
                const full_stmt = stmt_buffer.items;
                self.execute_statement(full_stmt) catch |err| {
                    try self.writer.print("Error: {s}\n", .{@errorName(err)});
                };
                try self.writer.flush();
                stmt_buffer.clearRetainingCapacity();
            } else {
                try stmt_buffer.append(self.allocator, ' ');
            }
        }
    }

    fn print_help(self: *REPL) !void {
        _ = try self.writer.writeAll(
            \\Meta commands:
            \\ .exit         - Exit this program
            \\ .help         - Show this help message
            \\ .tables       - List all tables
            \\ .indexes      - List all indexes
            \\ .schema T     - Show schema for table T
            \\ .views        - List all views
            \\ .stats        - Toggle query timing
            \\ .table        - Toggle table format output
            \\ .debug        - Toggle debug mode
            \\ .dump         - Export database as SQL
            \\ .read FILE    - Execute SQL from file
            \\ .import T F   - Import CSV file F into table T
            \\ .checkpoint   - Force WAL checkpoint
            \\ .sync         - Sync all pages to disk
            \\ .cache        - Show cache statistics
            \\
            \\Multi-line: End statement with ; or use \ to continue
            \\
        );
    }

    fn execute_meta_command(self: *REPL, cmd: []const u8) !MetaCommandResult {
        if (std.mem.startsWith(u8, cmd, ".schema ")) {
            const table_name = std.mem.trim(u8, cmd[8..], " ");
            try self.show_schema(table_name);
            return .Success;
        }

        if (std.mem.startsWith(u8, cmd, ".read ")) {
            const filename = std.mem.trim(u8, cmd[6..], " ");
            try self.execute_file(filename);
            return .Success;
        }

        if (std.mem.startsWith(u8, cmd, ".import ")) {
            const args = std.mem.trim(u8, cmd[8..], " ");
            var iter = std.mem.splitScalar(u8, args, ' ');
            const table_name = iter.next() orelse {
                try self.writer.writeAll("Usage: .import TABLE FILE\n");
                return .Success;
            };
            const rest = iter.rest();
            const filename = std.mem.trim(u8, rest, " ");
            if (filename.len == 0) {
                try self.writer.writeAll("Usage: .import TABLE FILE\n");
                return .Success;
            }
            try self.import_csv(table_name, filename);
            return .Success;
        }

        const MetaCmd = enum {
            exit,
            help,
            tables,
            indexes,
            views,
            debug,
            stats,
            table,
            dump,
            checkpoint,
            sync,
            cache,
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
            .views => {
                try self.list_views();
                return .Success;
            },
            .debug => {
                self.debug_mode = !self.debug_mode;
                try self.writer.print("Debug mode: {s}\n", .{if (self.debug_mode) "ON" else "OFF"});
                return .Success;
            },
            .stats => {
                self.stats_mode = !self.stats_mode;
                try self.writer.print("Query timing: {s}\n", .{if (self.stats_mode) "ON" else "OFF"});
                return .Success;
            },
            .table => {
                self.table_mode = !self.table_mode;
                try self.writer.print("Table format: {s}\n", .{if (self.table_mode) "ON" else "OFF"});
                return .Success;
            },
            .dump => {
                try self.dump_database();
                return .Success;
            },
            .cache => {
                try self.show_cache_stats();
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

    fn list_views(self: *REPL) !void {
        const db = self.db orelse return;
        var count: usize = 0;
        var iter = db.views.iterator();
        while (iter.next()) |entry| {
            if (count == 0) {
                try self.writer.writeAll("Views:\n");
            }
            try self.writer.print("  {s}\n", .{entry.key_ptr.*});
            count += 1;
        }
        if (count == 0) {
            try self.writer.writeAll("No views found.\n");
        }
    }

    fn show_schema(self: *REPL, table_name: []const u8) !void {
        const db = self.db orelse return;
        const table = db.get_table(table_name) catch {
            try self.writer.print("Table '{s}' not found.\n", .{table_name});
            return;
        };
        const schema = table.schema;

        try self.writer.print("CREATE TABLE {s} (\n", .{schema.table_name});
        for (schema.columns, 0..) |col, i| {
            try self.writer.print("  {s} ", .{col.name});
            const type_str = switch (col.type) {
                .Integer => "INTEGER",
                .Text => "TEXT",
                .Real => "REAL",
                .Blob => "BLOB",
                .Boolean => "BOOLEAN",
                .Date => "DATE",
                .Time => "TIME",
                .Datetime => "DATETIME",
            };
            try self.writer.print("{s}", .{type_str});
            if (col.primary_key) try self.writer.writeAll(" PRIMARY KEY");
            if (col.not_null) try self.writer.writeAll(" NOT NULL");
            if (col.unique) try self.writer.writeAll(" UNIQUE");
            if (col.foreign_key) |fk| {
                try self.writer.print(" REFERENCES {s}({s})", .{ fk.ref_table, fk.ref_column });
            }
            if (i < schema.columns.len - 1) {
                try self.writer.writeAll(",");
            }
            try self.writer.writeAll("\n");
        }
        try self.writer.writeAll(");\n");
    }

    fn show_cache_stats(self: *REPL) !void {
        const pager = self.pager orelse return;
        const stats = pager.get_cache_stats();
        try self.writer.print("Page Cache:\n", .{});
        try self.writer.print("  Hits:   {d}\n", .{stats.hits});
        try self.writer.print("  Misses: {d}\n", .{stats.misses});
        try self.writer.print("  Ratio:  {d:.1}%\n", .{stats.ratio * 100});

        const stmt_total = self.stmt_cache.hits + self.stmt_cache.misses;
        const stmt_ratio: f64 = if (stmt_total > 0) @as(f64, @floatFromInt(self.stmt_cache.hits)) / @as(f64, @floatFromInt(stmt_total)) else 0;
        try self.writer.print("Statement Cache:\n", .{});
        try self.writer.print("  Hits:   {d}\n", .{self.stmt_cache.hits});
        try self.writer.print("  Misses: {d}\n", .{self.stmt_cache.misses});
        try self.writer.print("  Ratio:  {d:.1}%\n", .{stmt_ratio * 100});

        const result_total = self.result_cache.hits + self.result_cache.misses;
        const result_ratio: f64 = if (result_total > 0) @as(f64, @floatFromInt(self.result_cache.hits)) / @as(f64, @floatFromInt(result_total)) else 0;
        try self.writer.print("Result Cache:\n", .{});
        try self.writer.print("  Hits:   {d}\n", .{self.result_cache.hits});
        try self.writer.print("  Misses: {d}\n", .{self.result_cache.misses});
        try self.writer.print("  Ratio:  {d:.1}%\n", .{result_ratio * 100});
        try self.writer.print("  Enabled: {s}\n", .{if (self.result_cache.enabled) "yes" else "no"});
    }

    fn dump_database(self: *REPL) !void {
        const db = self.db orelse return;

        try self.writer.writeAll("-- ZQL Database Dump\n");
        try self.writer.writeAll("BEGIN TRANSACTION;\n\n");

        const tables = db.list_tables() catch return;
        defer self.allocator.free(tables);

        for (tables) |table_name| {
            const table = db.get_table(table_name) catch continue;
            const schema = table.schema;

            try self.writer.print("CREATE TABLE {s} (\n", .{table_name});
            for (schema.columns, 0..) |col, i| {
                try self.writer.print("  {s} {s}", .{ col.name, @tagName(col.type) });
                if (col.primary_key) try self.writer.writeAll(" PRIMARY KEY");
                if (col.not_null) try self.writer.writeAll(" NOT NULL");
                if (col.unique) try self.writer.writeAll(" UNIQUE");
                if (i < schema.columns.len - 1) {
                    try self.writer.writeAll(",\n");
                } else {
                    try self.writer.writeAll("\n");
                }
            }
            try self.writer.writeAll(");\n\n");

            var cursor = table.select_all() catch continue;
            while (!cursor.is_end()) {
                const page = db.pager.get_page(cursor.page_num) catch break;
                try self.writer.print("INSERT INTO {s} VALUES (", .{table_name});

                for (schema.columns, 0..) |col, col_idx| {
                    _ = col; // autofix
                    if (col_idx > 0) try self.writer.writeAll(", ");
                    const val = @import("storage/row.zig").get_value_from_page(page, cursor.cell_num, schema, col_idx);
                    switch (val) {
                        .integer => |v| try self.writer.print("{d}", .{v}),
                        .real => |v| try self.writer.print("{d}", .{v}),
                        .text => |v| try self.writer.print("'{s}'", .{v}),
                        .boolean => |v| try self.writer.print("{s}", .{if (v) "TRUE" else "FALSE"}),
                        .null_val => try self.writer.writeAll("NULL"),
                        else => try self.writer.writeAll("NULL"),
                    }
                }
                try self.writer.writeAll(");\n");
                cursor.advance() catch break;
            }
            try self.writer.writeAll("\n");
        }

        try self.writer.writeAll("COMMIT;\n");
    }

    fn execute_file(self: *REPL, filename: []const u8) !void {
        const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
            try self.writer.print("Error opening file '{s}': {s}\n", .{ filename, @errorName(err) });
            return;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
            try self.writer.print("Error reading file: {s}\n", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(content);

        var stmt_start: usize = 0;
        var i: usize = 0;
        var in_string = false;

        while (i < content.len) : (i += 1) {
            if (content[i] == '\'' and (i == 0 or content[i - 1] != '\\')) {
                in_string = !in_string;
            }
            if (!in_string and content[i] == ';') {
                const stmt = std.mem.trim(u8, content[stmt_start .. i + 1], " \t\n\r");
                if (stmt.len > 0) {
                    self.execute_statement(stmt) catch |err| {
                        try self.writer.print("Error: {s}\n", .{@errorName(err)});
                    };
                }
                stmt_start = i + 1;
            }
        }

        if (stmt_start < content.len) {
            const stmt = std.mem.trim(u8, content[stmt_start..], " \t\n\r");
            if (stmt.len > 0) {
                self.execute_statement(stmt) catch |err| {
                    try self.writer.print("Error: {s}\n", .{@errorName(err)});
                };
            }
        }

        try self.writer.print("Executed file: {s}\n", .{filename});
    }

    fn import_csv(self: *REPL, table_name: []const u8, filename: []const u8) !void {
        const db = self.db orelse return;

        _ = db.get_table(table_name) catch {
            try self.writer.print("Table '{s}' not found.\n", .{table_name});
            return;
        };

        const file = std.fs.cwd().openFile(filename, .{}) catch |err| {
            try self.writer.print("Error opening file '{s}': {s}\n", .{ filename, @errorName(err) });
            return;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch |err| {
            try self.writer.print("Error reading file: {s}\n", .{@errorName(err)});
            return;
        };
        defer self.allocator.free(content);

        var row_count: usize = 0;
        var error_count: usize = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        var header_cols: ?[][]const u8 = null;
        defer if (header_cols) |cols| self.allocator.free(cols);

        while (lines.next()) |line| {
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;

            const fields = self.parse_csv_line(trimmed) catch |err| {
                try self.writer.print("CSV parse error: {s}\n", .{@errorName(err)});
                error_count += 1;
                continue;
            };
            defer self.allocator.free(fields);

            if (header_cols == null) {
                header_cols = try self.allocator.alloc([]const u8, fields.len);
                for (fields, 0..) |f, i| {
                    header_cols.?[i] = f;
                }
                continue;
            }

            var sql = std.ArrayList(u8){};
            defer sql.deinit(self.allocator);

            try sql.appendSlice(self.allocator, "INSERT INTO ");
            try sql.appendSlice(self.allocator, table_name);
            try sql.appendSlice(self.allocator, " (");

            for (header_cols.?, 0..) |col, i| {
                if (i > 0) try sql.appendSlice(self.allocator, ", ");
                try sql.appendSlice(self.allocator, col);
            }

            try sql.appendSlice(self.allocator, ") VALUES (");

            for (fields, 0..) |field, i| {
                if (i > 0) try sql.appendSlice(self.allocator, ", ");
                if (field.len == 0 or std.mem.eql(u8, field, "NULL")) {
                    try sql.appendSlice(self.allocator, "NULL");
                } else if (self.is_numeric(field)) {
                    try sql.appendSlice(self.allocator, field);
                } else {
                    try sql.append(self.allocator, '\'');
                    for (field) |c| {
                        if (c == '\'') {
                            try sql.appendSlice(self.allocator, "''");
                        } else {
                            try sql.append(self.allocator, c);
                        }
                    }
                    try sql.append(self.allocator, '\'');
                }
            }

            try sql.appendSlice(self.allocator, ");");

            self.execute_statement(sql.items) catch {
                error_count += 1;
                continue;
            };
            row_count += 1;
        }

        try self.writer.print("Imported {d} rows from '{s}' into '{s}'", .{ row_count, filename, table_name });
        if (error_count > 0) {
            try self.writer.print(" ({d} errors)", .{error_count});
        }
        try self.writer.writeAll("\n");
    }

    fn parse_csv_line(self: *REPL, line: []const u8) ![][]const u8 {
        var fields = std.ArrayList([]const u8){};
        errdefer fields.deinit(self.allocator);

        var i: usize = 0;
        while (i < line.len) {
            if (line[i] == '"') {
                i += 1;
                const field_start = i;
                while (i < line.len) {
                    if (line[i] == '"') {
                        if (i + 1 < line.len and line[i + 1] == '"') {
                            i += 2;
                        } else {
                            break;
                        }
                    } else {
                        i += 1;
                    }
                }
                try fields.append(self.allocator, line[field_start..i]);
                if (i < line.len) i += 1;
                if (i < line.len and line[i] == ',') i += 1;
            } else {
                const field_start = i;
                while (i < line.len and line[i] != ',') : (i += 1) {}
                try fields.append(self.allocator, line[field_start..i]);
                if (i < line.len) i += 1;
            }
        }

        return fields.toOwnedSlice(self.allocator);
    }

    fn is_numeric(self: *REPL, s: []const u8) bool {
        _ = self;
        if (s.len == 0) return false;
        var has_dot = false;
        var idx: usize = 0;
        if (s[0] == '-' or s[0] == '+') idx = 1;
        if (idx >= s.len) return false;
        for (s[idx..]) |c| {
            if (c == '.') {
                if (has_dot) return false;
                has_dot = true;
            } else if (c < '0' or c > '9') {
                return false;
            }
        }
        return true;
    }

    fn execute_statement(self: *REPL, input: []const u8) !void {
        const db = self.db orelse return error.DatabaseNotInitialized;

        const start_time = if (self.stats_mode) std.time.nanoTimestamp() else 0;

        const is_select = std.ascii.startsWithIgnoreCase(input, "select");
        const is_write = std.ascii.startsWithIgnoreCase(input, "insert") or
            std.ascii.startsWithIgnoreCase(input, "update") or
            std.ascii.startsWithIgnoreCase(input, "delete") or
            std.ascii.startsWithIgnoreCase(input, "create") or
            std.ascii.startsWithIgnoreCase(input, "drop") or
            std.ascii.startsWithIgnoreCase(input, "alter");

        if (is_write) {
            self.result_cache.invalidate();
        }

        if (is_select and !self.debug_mode) {
            if (self.result_cache.get(input)) |cached_results| {
                try self.print_results(cached_results);
                if (self.stats_mode) {
                    const end_time = std.time.nanoTimestamp();
                    const elapsed_ns = end_time - start_time;
                    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
                    try self.writer.print("Time: {d:.3}ms (result cached)\n", .{elapsed_ms});
                }
                return;
            }

            if (self.stmt_cache.get(input)) |cached_insts| {
                var vm = VM.init(self.allocator, db);
                vm.set_debug(false);
                defer vm.deinit();
                vm.load(cached_insts);
                vm.run() catch |err| {
                    try self.writer.print("Runtime error: {s}\n", .{@errorName(err)});
                    return;
                };
                const results = vm.get_results();
                if (results.len > 0) {
                    self.result_cache.put(input, results) catch {};
                    try self.print_results(results);
                }
                if (self.stats_mode) {
                    const end_time = std.time.nanoTimestamp();
                    const elapsed_ns = end_time - start_time;
                    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
                    try self.writer.print("Time: {d:.3}ms (stmt cached)\n", .{elapsed_ms});
                }
                return;
            }
        }

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
        const stmt = p.parse() catch {
            if (p.hasErrors()) {
                for (p.getErrors()) |err| {
                    try self.writer.print("Error at line {d}, column {d}: {s}\n", .{ err.line, err.column, err.message });
                    if (err.line == 1 and err.column > 0 and err.column <= input.len) {
                        try self.writer.print("  {s}\n", .{input});
                        try self.writer.writeAll("  ");
                        var i: usize = 1;
                        while (i < err.column) : (i += 1) {
                            try self.writer.writeAll(" ");
                        }
                        try self.writer.writeAll("^\n");
                    }
                }
            } else {
                try self.writer.writeAll("Parse error\n");
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

        if (is_select and !self.debug_mode) {
            self.stmt_cache.put(input, instructions) catch {};
        }

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
            const is_constraint_err = (err == error.NullConstraintViolation or
                err == error.TypeMismatch or
                err == error.CheckConstraintViolation or
                err == error.UniqueConstraintViolation or
                err == error.ForeignKeyViolation);

            if (is_constraint_err) {
                const msg = vm.get_error_message() catch @errorName(err);
                defer if (is_constraint_err) self.allocator.free(msg);
                try self.writer.print("Error: {s}\n", .{msg});
            } else {
                try self.writer.print("Runtime error: {s}\n", .{@errorName(err)});
            }
            return;
        };

        const results = vm.get_results();
        if (results.len > 0) {
            if (is_select and !self.debug_mode) {
                self.result_cache.put(input, results) catch {};
            }
            try self.print_results(results);
        } else {
            try self.writer.writeAll("OK\n");
        }

        if (self.stats_mode) {
            const end_time = std.time.nanoTimestamp();
            const elapsed_ns = end_time - start_time;
            const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
            try self.writer.print("Time: {d:.3}ms\n", .{elapsed_ms});
        }
    }

    fn print_results(self: *REPL, results: [][]RegisterValue) !void {
        if (self.table_mode and results.len > 0) {
            try self.print_results_table(results);
        } else {
            try self.print_results_simple(results);
        }
    }

    fn print_results_simple(self: *REPL, results: [][]RegisterValue) !void {
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

    fn print_results_table(self: *REPL, results: [][]RegisterValue) !void {
        if (results.len == 0) return;

        const num_cols = results[0].len;
        var col_widths = try self.allocator.alloc(usize, num_cols);
        defer self.allocator.free(col_widths);

        for (col_widths) |*w| {
            w.* = 4;
        }

        for (results) |row| {
            for (row, 0..) |val, i| {
                const width = self.value_width(val);
                if (width > col_widths[i]) {
                    col_widths[i] = width;
                }
            }
        }

        try self.print_separator(col_widths);

        for (results) |row| {
            try self.writer.writeAll("|");
            for (row, 0..) |val, i| {
                try self.writer.writeAll(" ");
                const width = self.value_width(val);
                try self.print_value(val);
                var padding = col_widths[i] - width;
                while (padding > 0) : (padding -= 1) {
                    try self.writer.writeAll(" ");
                }
                try self.writer.writeAll(" |");
            }
            try self.writer.writeAll("\n");
        }

        try self.print_separator(col_widths);
        try self.writer.print("({d} rows)\n", .{results.len});
    }

    fn print_separator(self: *REPL, col_widths: []usize) !void {
        try self.writer.writeAll("+");
        for (col_widths) |w| {
            var i: usize = 0;
            while (i < w + 2) : (i += 1) {
                try self.writer.writeAll("-");
            }
            try self.writer.writeAll("+");
        }
        try self.writer.writeAll("\n");
    }

    fn value_width(self: *REPL, val: RegisterValue) usize {
        _ = self;
        return switch (val.type) {
            .integer => blk: {
                var n = val.integer;
                if (n == 0) break :blk 1;
                var w: usize = 0;
                if (n < 0) {
                    w = 1;
                    n = -n;
                }
                while (n > 0) : (n = @divTrunc(n, 10)) {
                    w += 1;
                }
                break :blk w;
            },
            .real => 8,
            .text => val.text.len,
            .blob => 6 + val.blob.len * 2,
            .boolean => if (val.boolean) 4 else 5,
            .null => 4,
        };
    }

    fn print_value(self: *REPL, val: RegisterValue) !void {
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
                switch (insert_stmt.source) {
                    .values => |value_rows| {
                        try self.writer.print("Value rows: {d}\n", .{value_rows.len});
                        for (value_rows, 0..) |row, row_idx| {
                            try self.writer.print("  Row {d}:\n", .{row_idx});
                            for (row) |val| {
                                switch (val) {
                                    .integer_literal => |int_lit| try self.writer.print("    - {d}\n", .{int_lit.value}),
                                    .float_literal => |float_lit| try self.writer.print("    - {d}\n", .{float_lit.value}),
                                    .string_literal => |str_lit| try self.writer.print("    - '{s}'\n", .{str_lit.value}),
                                    .null_literal => try self.writer.writeAll("    - NULL\n"),
                                    .identifier => |ident| try self.writer.print("    - {s}\n", .{ident.name}),
                                    else => try self.writer.print("    - {any}\n", .{val}),
                                }
                            }
                        }
                    },
                    .select => |sel| {
                        try self.writer.print("Source: SELECT FROM {s}\n", .{sel.from[0].name});
                    },
                }
            },
            .select_stmt => |select_stmt| {
                try self.writer.print("SELECT Statement\n", .{});
                try self.writer.writeAll("Columns:\n");
                for (select_stmt.columns) |col| {
                    switch (col.expr) {
                        .star_expression => try self.writer.writeAll("  - *"),
                        .identifier => |ident| try self.writer.print("  - {s}", .{ident.name}),
                        else => try self.writer.writeAll("  - <expression>"),
                    }
                    if (col.alias) |alias| {
                        try self.writer.print(" AS {s}", .{alias});
                    }
                    try self.writer.writeAll("\n");
                }
                try self.writer.writeAll("From Tables:\n");
                for (select_stmt.from) |from_table| {
                    try self.writer.print("  - {s}", .{from_table.name});
                    if (from_table.alias) |alias| {
                        try self.writer.print(" AS {s}", .{alias});
                    }
                    try self.writer.writeAll("\n");
                }
                if (select_stmt.joins.len > 0) {
                    try self.writer.writeAll("Joins:\n");
                    for (select_stmt.joins) |join| {
                        const join_type_str = switch (join.join_type) {
                            .inner => "INNER",
                            .left => "LEFT",
                            .right => "RIGHT",
                            .cross => "CROSS",
                        };
                        try self.writer.print("  - {s} JOIN {s}", .{ join_type_str, join.table.name });
                        if (join.table.alias) |alias| {
                            try self.writer.print(" AS {s}", .{alias});
                        }
                        try self.writer.writeAll("\n");
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
            .union_stmt => |union_stmt| {
                try self.writer.print("UNION{s}\n", .{if (union_stmt.all) " ALL" else ""});
            },
            .alter_table_stmt => |alter_stmt| {
                try self.writer.print("ALTER TABLE {s}\n", .{alter_stmt.table});
                switch (alter_stmt.action) {
                    .add_column => |col| try self.writer.print("  ADD COLUMN {s}\n", .{col.name}),
                    .drop_column => |col| try self.writer.print("  DROP COLUMN {s}\n", .{col}),
                    .rename_table => |name| try self.writer.print("  RENAME TO {s}\n", .{name}),
                    .rename_column => |r| try self.writer.print("  RENAME COLUMN {s} TO {s}\n", .{ r.old_name, r.new_name }),
                }
            },
            .vacuum_stmt => {
                try self.writer.writeAll("VACUUM\n");
            },
            .create_view_stmt => |view_stmt| {
                try self.writer.print("CREATE VIEW {s}\n", .{view_stmt.name});
            },
            .drop_view_stmt => |drop_stmt| {
                try self.writer.print("DROP VIEW", .{});
                if (drop_stmt.if_exists) {
                    try self.writer.writeAll(" IF EXISTS");
                }
                try self.writer.print(" {s}\n", .{drop_stmt.name});
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
            .function_call => |func| try self.writer.print("{s}(...)", .{func.name}),
        }
    }
};
