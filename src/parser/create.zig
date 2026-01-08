const std = @import("std");
const ast = @import("ast.zig");
const token = @import("../lexer/token.zig");
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;

pub fn parse_create(self: *Parser) ParseError!ast.CreateTableStatement {
    const stmt = self.allocator.create(ast.CreateTableStatement) catch return error.OutOfMemory;

    self.advance();

    if (!self.expect(token.TokenType.table)) {
        return error.ExpectedTable;
    }

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
        const stmt = try parse_create(&p);

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
