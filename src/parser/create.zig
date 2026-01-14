const std = @import("std");
const ast = @import("ast.zig");
const token = @import("../lexer/token.zig");
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;

pub const CreateResult = union(enum) {
    table: ast.CreateTableStatement,
    index: ast.CreateIndexStatement,
};

pub fn parse_create(self: *Parser) ParseError!CreateResult {
    self.advance(); // consume CREATE

    var is_unique = false;
    if (self.current.type == token.TokenType.unique) {
        is_unique = true;
        self.advance();
    }

    if (self.current.type == token.TokenType.index) {
        return CreateResult{ .index = try parse_create_index(self, is_unique) };
    }

    if (self.current.type != token.TokenType.table) {
        return error.ExpectedTable;
    }

    return CreateResult{ .table = try parse_create_table(self) };
}

fn parse_create_table(self: *Parser) ParseError!ast.CreateTableStatement {
    const stmt = self.allocator.create(ast.CreateTableStatement) catch return error.OutOfMemory;

    self.advance(); // consume TABLE

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected table name, got '{s}'", .{@tagName(self.current.type)});
        return error.ExpectedIdentifier;
    }
    stmt.table = self.current.literal;
    self.advance();

    if (!self.expect(token.TokenType.lparen)) {
        return error.ExpectedOpenParen;
    }

    stmt.columns = try parse_column_defs(self);

    if (!self.expect(token.TokenType.rparen)) {
        return error.ExpectedCloseParen;
    }

    if (self.current.type == token.TokenType.semicolon) {
        self.advance();
    }

    return stmt.*;
}

fn parse_create_index(self: *Parser, is_unique: bool) ParseError!ast.CreateIndexStatement {
    self.advance();

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected index name, got '{s}'", .{@tagName(self.current.type)});
        return error.ExpectedIdentifier;
    }
    const index_name = self.current.literal;
    self.advance();

    if (self.current.type != token.TokenType.on) {
        self.addError("Expected ON, got '{s}'", .{@tagName(self.current.type)});
        return error.UnexpectedToken;
    }
    self.advance();

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected table name, got '{s}'", .{@tagName(self.current.type)});
        return error.ExpectedIdentifier;
    }
    const table_name = self.current.literal;
    self.advance();

    if (!self.expect(token.TokenType.lparen)) {
        return error.ExpectedOpenParen;
    }

    var columns = std.ArrayList([]const u8){};
    while (self.current.type == token.TokenType.ident) {
        columns.append(self.allocator, self.current.literal) catch return error.OutOfMemory;
        self.advance();
        if (self.current.type == token.TokenType.comma) {
            self.advance();
        } else {
            break;
        }
    }

    if (!self.expect(token.TokenType.rparen)) {
        return error.ExpectedCloseParen;
    }

    if (self.current.type == token.TokenType.semicolon) {
        self.advance();
    }

    return ast.CreateIndexStatement{
        .index_name = index_name,
        .table = table_name,
        .columns = columns.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
        .unique = is_unique,
    };
}

fn parse_column_defs(self: *Parser) ParseError![]ast.ColumnDef {
    var cols = std.ArrayList(ast.ColumnDef){};
    defer cols.deinit(self.allocator);

    while (true) {
        const col = try parse_column_def(self);
        if (col.name.len == 0) {
            break;
        }
        cols.append(self.allocator, col) catch return error.OutOfMemory;

        if (self.current.type == token.TokenType.comma) {
            self.advance();
        } else {
            break;
        }
    }

    return cols.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

fn parse_column_def(self: *Parser) ParseError!ast.ColumnDef {
    if (self.current.type != .ident) {
        return ast.ColumnDef{
            .name = "",
            .type_name = "",
            .primary_key = false,
            .not_null = false,
        };
    }

    var col = ast.ColumnDef{
        .name = self.current.literal,
        .type_name = "",
        .primary_key = false,
        .not_null = false,
    };
    self.advance();

    switch (self.current.type) {
        token.TokenType.integer => {
            col.type_name = "INTEGER";
            self.advance();
        },
        token.TokenType.text => {
            col.type_name = "TEXT";
            self.advance();
        },
        token.TokenType.real => {
            col.type_name = "REAL";
            self.advance();
        },
        token.TokenType.blob => {
            col.type_name = "BLOB";
            self.advance();
        },
        token.TokenType.boolean => {
            col.type_name = "BOOLEAN";
            self.advance();
        },
        token.TokenType.date => {
            col.type_name = "DATE";
            self.advance();
        },
        token.TokenType.time => {
            col.type_name = "TIME";
            self.advance();
        },
        token.TokenType.datetime => {
            col.type_name = "DATETIME";
            self.advance();
        },
        else => {
            if (self.current.type == .ident) {
                col.type_name = self.current.literal;
                self.advance();
            } else {
                self.addError("Expected column type, got '{s}'", .{@tagName(self.current.type)});
                return error.ExpectedColumnType;
            }
        },
    }

    if (self.current.type == token.TokenType.primary) {
        self.advance();
        if (self.current.type == token.TokenType.key) {
            col.primary_key = true;
            self.advance();
        } else {
            self.addError("Expected 'KEY' after 'PRIMARY', got '{s}'", .{@tagName(self.current.type)});
            return error.ExpectedKeyKeyword;
        }
    }

    if (self.current.type == token.TokenType.not) {
        self.advance();
        if (self.current.type == token.TokenType.null) {
            col.not_null = true;
            self.advance();
        } else {
            self.addError("Expected 'NULL' after 'NOT', got '{s}'", .{@tagName(self.current.type)});
            return error.ExpectedNullKeyword;
        }
    }

    return col;
}

const lexer = @import("../lexer/lexer.zig");

test "parse create table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const ColCheck = struct {
        name: []const u8,
        type_name: []const u8,
        primary_key: bool,
        not_null: bool,
    };

    const TestCase = struct {
        input: []const u8,
        table: []const u8,
        columns: []const ColCheck,
    };

    const tests = [_]TestCase{
        .{
            .input = "CREATE TABLE users (id INTEGER);",
            .table = "users",
            .columns = &[_]ColCheck{
                .{ .name = "id", .type_name = "INTEGER", .primary_key = false, .not_null = false },
            },
        },
        .{
            .input = "CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT NOT NULL, price REAL);",
            .table = "products",
            .columns = &[_]ColCheck{
                .{ .name = "id", .type_name = "INTEGER", .primary_key = true, .not_null = false },
                .{ .name = "name", .type_name = "TEXT", .primary_key = false, .not_null = true },
                .{ .name = "price", .type_name = "REAL", .primary_key = false, .not_null = false },
            },
        },
    };

    for (tests) |t| {
        var l = lexer.Lexer.init(t.input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const result = try parse_create(&p);
        const stmt = result.table;

        try std.testing.expectEqualStrings(t.table, stmt.table);
        try std.testing.expectEqual(t.columns.len, stmt.columns.len);

        for (t.columns, 0..) |expected_col, i| {
            const actual_col = stmt.columns[i];
            try std.testing.expectEqualStrings(expected_col.name, actual_col.name);
            try std.testing.expectEqualStrings(expected_col.type_name, actual_col.type_name);
            try std.testing.expectEqual(expected_col.primary_key, actual_col.primary_key);
            try std.testing.expectEqual(expected_col.not_null, actual_col.not_null);
        }
    }
}

test "parse create index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var l = lexer.Lexer.init("CREATE INDEX idx_email ON users (email);");
    const tokens = try l.tokenize(allocator);

    var p = Parser.init(tokens, allocator);
    const result = try parse_create(&p);
    const stmt = result.index;

    try std.testing.expectEqualStrings("idx_email", stmt.index_name);
    try std.testing.expectEqualStrings("users", stmt.table);
    try std.testing.expectEqual(1, stmt.columns.len);
    try std.testing.expectEqualStrings("email", stmt.columns[0]);
    try std.testing.expect(!stmt.unique);
}

test "parse create unique index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var l = lexer.Lexer.init("CREATE UNIQUE INDEX idx_email ON users (email);");
    const tokens = try l.tokenize(allocator);

    var p = Parser.init(tokens, allocator);
    const result = try parse_create(&p);
    const stmt = result.index;

    try std.testing.expectEqualStrings("idx_email", stmt.index_name);
    try std.testing.expect(stmt.unique);
}
