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
                const stmt = try create.parse_create(self);
                return ast.Statement{
                    .create_table_stmt = stmt,
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
                const stmt = try other.parse_drop(self);
                return ast.Statement{
                    .drop_table_stmt = stmt,
                };
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
