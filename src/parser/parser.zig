const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("../lexer/lexer.zig");
const token = @import("../lexer/token.zig");

const expressions = @import("expressions.zig");
const create = @import("create.zig");
const insert = @import("insert.zig");
const select = @import("select.zig");
const other = @import("other.zig");

pub const ParseError = error{
    UnexpectedToken,
    ExpectedTable,
    ExpectedIdentifier,
    ExpectedOpenParen,
    ExpectedCloseParen,
    ExpectedColumnType,
    ExpectedKeyKeyword,
    ExpectedNullKeyword,
    ExpectedFrom,
    ExpectedBy,
    ExpectedAnd,
    ExpectedNull,
    ExpectedThen,
    ExpectedEnd,
    ExpectedAs,
    InvalidInteger,
    InvalidFloat,
    InvalidIntegerLiteral,
    OutOfMemory,
};

pub const ErrorInfo = struct {
    message: []const u8,
    line: usize,
    column: usize,

    pub fn format(self: ErrorInfo, writer: anytype) !void {
        try writer.print("Error at line {d}, column {d}: {s}", .{ self.line, self.column, self.message });
    }
};

pub const Parser = struct {
    tokens: []token.Token,
    pos: usize,
    current: token.Token,
    peek: token.Token,
    errors: std.ArrayList(ErrorInfo),
    allocator: std.mem.Allocator,

    pub fn init(tokens: []token.Token, allocator: std.mem.Allocator) Parser {
        var parser = Parser{
            .tokens = tokens,
            .pos = 0,
            .current = token.Token{ .type = .eof, .literal = "", .line = 0, .column = 0 },
            .peek = token.Token{ .type = .eof, .literal = "", .line = 0, .column = 0 },
            .errors = .{},
            .allocator = allocator,
        };
        if (tokens.len > 0) {
            parser.current = tokens[0];
        }
        if (tokens.len > 1) {
            parser.peek = tokens[1];
        }
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit(self.allocator);
    }

    pub fn addError(self: *Parser, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        self.errors.append(self.allocator, .{
            .message = msg,
            .line = self.current.line,
            .column = self.current.column,
        }) catch {
            self.allocator.free(msg);
        };
    }

    pub fn getErrors(self: *Parser) []const ErrorInfo {
        return self.errors.items;
    }

    pub fn hasErrors(self: *Parser) bool {
        return self.errors.items.len > 0;
    }

    pub fn printErrors(self: *Parser, writer: anytype) !void {
        for (self.errors.items) |err| {
            try writer.print("Error at line {d}, column {d}: {s}\n", .{ err.line, err.column, err.message });
        }
    }

    pub fn advance(self: *Parser) void {
        self.pos += 1;
        if (self.pos < self.tokens.len) {
            self.current = self.tokens[self.pos];
        } else if (self.pos + 1 < self.tokens.len) {
            self.peek = self.tokens[self.pos + 1];
        } else {
            self.peek = token.Token{ .type = .eof, .literal = "", .line = 0, .column = 0 };
        }
    }

    pub fn expect(self: *Parser, expect_token: token.TokenType) bool {
        if (self.current.type == expect_token) {
            self.advance();
            return true;
        }
        self.addError("Expected token '{s}' but got '{s}'", .{ @tagName(expect_token), @tagName(self.current.type) });
        return false;
    }

    pub fn parse(self: *Parser) ParseError!ast.Statement {
        switch (self.current.type) {
            token.TokenType.create => {
                const result = try create.parse_create(self);
                return switch (result) {
                    .table => |stmt| ast.Statement{ .create_table_stmt = stmt },
                    .index => |stmt| ast.Statement{ .create_index_stmt = stmt },
                };
            },
            token.TokenType.insert => {
                const stmt = try insert.parse_insert(self);
                return ast.Statement{
                    .insert_stmt = stmt,
                };
            },
            token.TokenType.select => {
                const stmt = try select.parse_select(self);
                if (self.current.type == token.TokenType.@"union") {
                    return try select.parse_union(self, stmt);
                }
                return ast.Statement{
                    .select_stmt = stmt,
                };
            },
            token.TokenType.update => {
                const stmt = try other.parse_update(self);
                return ast.Statement{
                    .update_stmt = stmt,
                };
            },
            token.TokenType.delete => {
                const stmt = try other.parse_Delete(self);
                return ast.Statement{
                    .delete_stmt = stmt,
                };
            },
            token.TokenType.drop => {
                const result = try other.parse_drop(self);
                return switch (result) {
                    .table => |stmt| ast.Statement{ .drop_table_stmt = stmt },
                    .index => |stmt| ast.Statement{ .drop_index_stmt = stmt },
                };
            },
            token.TokenType.begin => {
                self.advance();
                if (self.current.type == token.TokenType.transaction) {
                    self.advance();
                }
                if (self.current.type == token.TokenType.semicolon) {
                    self.advance();
                }
                return ast.Statement{ .begin_stmt = ast.BeginStatement{} };
            },
            token.TokenType.commit => {
                self.advance();
                if (self.current.type == token.TokenType.semicolon) {
                    self.advance();
                }
                return ast.Statement{ .commit_stmt = ast.CommitStatement{} };
            },
            token.TokenType.rollback => {
                self.advance();
                if (self.current.type == token.TokenType.to) {
                    self.advance();
                    if (self.current.type == token.TokenType.savepoint) {
                        self.advance();
                    }
                    if (self.current.type != token.TokenType.ident) {
                        self.addError("Expected savepoint name after ROLLBACK TO", .{});
                        return error.ExpectedIdentifier;
                    }
                    const name = self.current.literal;
                    self.advance();
                    if (self.current.type == token.TokenType.semicolon) {
                        self.advance();
                    }
                    return ast.Statement{ .rollback_stmt = ast.RollbackStatement{ .savepoint_name = name } };
                }
                if (self.current.type == token.TokenType.semicolon) {
                    self.advance();
                }
                return ast.Statement{ .rollback_stmt = ast.RollbackStatement{} };
            },
            token.TokenType.savepoint => {
                self.advance();
                if (self.current.type != token.TokenType.ident) {
                    self.addError("Expected savepoint name", .{});
                    return error.ExpectedIdentifier;
                }
                const name = self.current.literal;
                self.advance();
                if (self.current.type == token.TokenType.semicolon) {
                    self.advance();
                }
                return ast.Statement{ .savepoint_stmt = ast.SavepointStatement{ .name = name } };
            },
            token.TokenType.release => {
                self.advance();
                if (self.current.type == token.TokenType.savepoint) {
                    self.advance();
                }
                if (self.current.type != token.TokenType.ident) {
                    self.addError("Expected savepoint name after RELEASE", .{});
                    return error.ExpectedIdentifier;
                }
                const name = self.current.literal;
                self.advance();
                if (self.current.type == token.TokenType.semicolon) {
                    self.advance();
                }
                return ast.Statement{ .release_savepoint_stmt = ast.ReleaseSavepointStatement{ .name = name } };
            },
            token.TokenType.set => {
                self.advance();
                if (self.current.type != token.TokenType.transaction) {
                    self.addError("Expected TRANSACTION after SET", .{});
                    return error.UnexpectedToken;
                }
                self.advance();
                if (self.current.type != token.TokenType.isolation) {
                    self.addError("Expected ISOLATION after SET TRANSACTION", .{});
                    return error.UnexpectedToken;
                }
                self.advance();
                if (self.current.type != token.TokenType.level) {
                    self.addError("Expected LEVEL after ISOLATION", .{});
                    return error.UnexpectedToken;
                }
                self.advance();

                const level: ast.IsolationLevel = blk: {
                    if (self.current.type == token.TokenType.read) {
                        self.advance();
                        if (self.current.type == token.TokenType.uncommitted) {
                            self.advance();
                            break :blk .read_uncommitted;
                        } else if (self.current.type == token.TokenType.committed) {
                            self.advance();
                            break :blk .read_committed;
                        } else {
                            self.addError("Expected UNCOMMITTED or COMMITTED after READ", .{});
                            return error.UnexpectedToken;
                        }
                    } else if (self.current.type == token.TokenType.repeatable) {
                        self.advance();
                        if (self.current.type != token.TokenType.read) {
                            self.addError("Expected READ after REPEATABLE", .{});
                            return error.UnexpectedToken;
                        }
                        self.advance();
                        break :blk .repeatable_read;
                    } else if (self.current.type == token.TokenType.serializable) {
                        self.advance();
                        break :blk .serializable;
                    } else {
                        self.addError("Expected isolation level (READ UNCOMMITTED, READ COMMITTED, REPEATABLE READ, SERIALIZABLE)", .{});
                        return error.UnexpectedToken;
                    }
                };

                if (self.current.type == token.TokenType.semicolon) {
                    self.advance();
                }
                return ast.Statement{ .set_transaction_stmt = ast.SetTransactionStatement{ .isolation_level = level } };
            },
            token.TokenType.alter => {
                const stmt = try other.parse_alter(self);
                return ast.Statement{ .alter_table_stmt = stmt };
            },
            else => {
                self.addError("Unexpected token '{s}' at start of statement", .{@tagName(self.current.type)});
                return error.UnexpectedToken;
            },
        }
    }

    pub const parse_or_expression = expressions.parse_or_expression;
    pub const parse_and_expression = expressions.parse_and_expression;
    pub const parse_comparison_expression = expressions.parse_comparison_expression;
    pub const parse_primary_expression = expressions.parse_primary_expression;

    pub const parse_create = create.parse_create;
    pub const parse_insert = insert.parse_insert;
    pub const parse_select = select.parse_select;
};

test "parser tokenization" {
    const input = "SELECT * FROM users WHERE id = 1;";
    var l = lexer.Lexer.init(input);
    const tokens = try l.tokenize(std.testing.allocator);
    defer std.testing.allocator.free(tokens);

    for (tokens) |t| {
        std.debug.print("literal:\t{s}\t", .{t.literal});
        std.debug.print("line:\t{}\t", .{t.line});
        std.debug.print("column:\t{}\t", .{t.column});
        std.debug.print("type:\t{}\n", .{t.type});
    }
}

test "parse create table statement via parse()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "CREATE TABLE items (id INTEGER);";
    var l = lexer.Lexer.init(input);
    const tokens = try l.tokenize(allocator);

    var p = Parser.init(tokens, allocator);
    const stmt = try p.parse();

    try std.testing.expect(std.meta.activeTag(stmt) == .create_table_stmt);
    try std.testing.expectEqualStrings("items", stmt.create_table_stmt.table);
    try std.testing.expectEqual(1, stmt.create_table_stmt.columns.len);
    try std.testing.expectEqualStrings("id", stmt.create_table_stmt.columns[0].name);
}

test "parse create index statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "CREATE INDEX idx_name ON users (name);";
    var l = lexer.Lexer.init(input);
    const tokens = try l.tokenize(allocator);

    var p = Parser.init(tokens, allocator);
    const stmt = try p.parse();

    try std.testing.expect(std.meta.activeTag(stmt) == .create_index_stmt);
    try std.testing.expectEqualStrings("idx_name", stmt.create_index_stmt.index_name);
    try std.testing.expectEqualStrings("users", stmt.create_index_stmt.table);
    try std.testing.expectEqual(1, stmt.create_index_stmt.columns.len);
    try std.testing.expectEqualStrings("name", stmt.create_index_stmt.columns[0]);
    try std.testing.expect(!stmt.create_index_stmt.unique);
}
