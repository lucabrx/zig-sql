const std = @import("std");
const ast = @import("ast.zig");
const token = @import("../lexer/token.zig");
const Parser = @import("parser.zig").Parser;
const ParserError = @import("parser.zig").ParseError;

pub fn parse_insert(self: *Parser) ParserError!ast.InsertStatement {
    const stmt = self.allocator.create(ast.InsertStatement) catch return error.OutOfMemory;

    self.advance();

    if (!self.expect(token.TokenType.into)) {
        return error.UnexpectedToken;
    }

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected table name, got '{s}'", .{@tagName(self.current.type)});
        return error.ExpectedIdentifier;
    }
    stmt.table = self.current.literal;
    self.advance();

    if (self.current.type == token.TokenType.lparen) {
        self.advance();
        stmt.columns = try parse_identifier_list(self);

        if (!self.expect(token.TokenType.rparen)) {
            return error.ExpectedCloseParen;
        }
    } else {
        stmt.columns = &[_][]const u8{};
    }

    if (!self.expect(token.TokenType.values)) {
        return error.UnexpectedToken;
    }

    if (!self.expect(token.TokenType.lparen)) {
        return error.ExpectedOpenParen;
    }

    stmt.values = try parse_expression_list(self);

    if (!self.expect(token.TokenType.rparen)) {
        return error.ExpectedCloseParen;
    }

    if (self.current.type == token.TokenType.semicolon) {
        self.advance();
    }

    return stmt.*;
}

fn parse_identifier_list(self: *Parser) ParserError![][]const u8 {
    var idents = std.ArrayList([]const u8){};
    defer idents.deinit(self.allocator);

    while (true) {
        if (self.current.type != token.TokenType.ident) {
            break;
        }
        idents.append(self.allocator, self.current.literal) catch return error.OutOfMemory;
        self.advance();

        if (self.current.type == token.TokenType.comma) {
            self.advance();
        } else {
            break;
        }
    }

    return idents.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

fn parse_expression_list(self: *Parser) ParserError![]ast.Expression {
    var expers = std.ArrayList(ast.Expression){};
    defer expers.deinit(self.allocator);

    while (true) {
        if (self.current.type == token.TokenType.rparen) {
            break;
        }

        const expr = try self.parse_primary_expression();
        expers.append(self.allocator, expr) catch return error.OutOfMemory;

        if (self.current.type == token.TokenType.comma) {
            self.advance();
        } else {
            break;
        }
    }

    return expers.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

const lexer = @import("../lexer/lexer.zig");

test "parse insert statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    {
        const input = "INSERT INTO users (name, age) VALUES ('Alice', 30);";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_insert(&p);

        try std.testing.expectEqualStrings("users", stmt.table);
        try std.testing.expectEqual(2, stmt.columns.len);
        try std.testing.expectEqualStrings("name", stmt.columns[0]);
        try std.testing.expectEqualStrings("age", stmt.columns[1]);

        try std.testing.expectEqual(2, stmt.values.len);
        try std.testing.expectEqualStrings("Alice", stmt.values[0].string_literal.value);
        try std.testing.expectEqual(30, stmt.values[1].integer_literal.value);
    }

    {
        const input = "INSERT INTO products VALUES (1, 'Apple', 9.99);";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_insert(&p);

        try std.testing.expectEqualStrings("products", stmt.table);
        try std.testing.expectEqual(0, stmt.columns.len);

        try std.testing.expectEqual(3, stmt.values.len);
        try std.testing.expectEqual(1, stmt.values[0].integer_literal.value);
        try std.testing.expectEqualStrings("Apple", stmt.values[1].string_literal.value);
        try std.testing.expectApproxEqAbs(9.99, stmt.values[2].float_literal.value, 0.0001);
    }
}
