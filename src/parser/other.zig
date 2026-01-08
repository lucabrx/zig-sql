const std = @import("std");
const ast = @import("ast.zig");
const token = @import("../lexer/token.zig");
const Parser = @import("parser.zig").Parser;
const ParserError = @import("parser.zig").ParseError;

pub fn parse_Delete(self: *Parser) ParserError!ast.DeleteStatement {
    const stmt = self.allocator.create(ast.DeleteStatement) catch return error.OutOfMemory;

    self.advance();

    if (!self.expect(token.TokenType.from)) {
        return error.UnexpectedToken;
    }

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected table name, got '{s}'", .{@tagName(self.current.type)});
        return error.ExpectedIdentifier;
    }
    stmt.table = self.current.literal;
    self.advance();

    if (self.current.type == token.TokenType.where) {
        self.advance();
        stmt.where = try self.parse_or_expression();
    } else {
        stmt.where = null;
    }

    if (self.current.type == token.TokenType.semicolon) {
        self.advance();
    }

    return stmt.*;
}

pub fn parse_update(self: *Parser) ParserError!ast.UpdateStatement {
    const stmt = self.allocator.create(ast.UpdateStatement) catch return error.OutOfMemory;

    self.advance();

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected table name, got '{s}'", .{@tagName(self.current.type)});
        return error.ExpectedIdentifier;
    }
    stmt.table = self.current.literal;
    self.advance();

    if (!self.expect(token.TokenType.set)) {
        return error.UnexpectedToken;
    }

    stmt.set = try parse_assignments(self);

    if (self.current.type == token.TokenType.where) {
        self.advance();
        stmt.where = try self.parse_or_expression();
    } else {
        stmt.where = null;
    }

    if (self.current.type == token.TokenType.semicolon) {
        self.advance();
    }

    return stmt.*;
}
pub fn parse_drop(self: *Parser) ParserError!ast.DropTableStatement {
    const stmt = self.allocator.create(ast.DropTableStatement) catch return error.OutOfMemory;
    stmt.if_exists = false;

    self.advance();

    if (!self.expect(token.TokenType.table)) {
        return error.UnexpectedToken;
    }

    if (self.current.type == token.TokenType.@"if") {
        self.advance();
        if (self.current.type == token.TokenType.exists) {
            stmt.if_exists = true;
            self.advance();
        }
    }

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected table name, got '{s}'", .{@tagName(self.current.type)});
        return error.ExpectedIdentifier;
    }
    stmt.table = self.current.literal;
    self.advance();

    if (self.current.type == token.TokenType.semicolon) {
        self.advance();
    }

    return stmt.*;
}

fn parse_assignments(self: *Parser) ParserError![]ast.Assignment {
    var assignments = std.ArrayList(ast.Assignment){};
    defer assignments.deinit(self.allocator);

    while (true) {
        const assign = self.allocator.create(ast.Assignment) catch return error.OutOfMemory;
        defer self.allocator.destroy(assign);

        if (self.current.type != token.TokenType.ident) {
            self.addError("Expected identifier, got '{s}'", .{@tagName(self.current.type)});
            return error.ExpectedIdentifier;
        }
        assign.column = self.current.literal;
        self.advance();

        if (!self.expect(token.TokenType.eq)) {
            return error.UnexpectedToken;
        }

        assign.value = try self.parse_or_expression();

        try assignments.append(self.allocator, assign.*);

        if (self.current.type == token.TokenType.comma) {
            self.advance();
            continue;
        } else {
            break;
        }
    }

    return assignments.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

const lexer = @import("../lexer/lexer.zig");

test "parse delete statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    {
        const input = "DELETE FROM users;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_Delete(&p);

        try std.testing.expectEqualStrings("users", stmt.table);
        try std.testing.expect(stmt.where == null);
    }

    {
        const input = "DELETE FROM users WHERE id = 1;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_Delete(&p);

        try std.testing.expectEqualStrings("users", stmt.table);
        try std.testing.expect(stmt.where != null);
    }
}

test "parse update statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    {
        const input = "UPDATE users SET name = 'Alice';";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_update(&p);

        try std.testing.expectEqualStrings("users", stmt.table);
        try std.testing.expectEqual(1, stmt.set.len);
        try std.testing.expectEqualStrings("name", stmt.set[0].column);
        try std.testing.expect(stmt.where == null);
    }

    {
        const input = "UPDATE users SET name = 'Bob', age = 30 WHERE id = 1;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_update(&p);

        try std.testing.expectEqualStrings("users", stmt.table);
        try std.testing.expectEqual(2, stmt.set.len);
        try std.testing.expectEqualStrings("name", stmt.set[0].column);
        try std.testing.expectEqualStrings("age", stmt.set[1].column);
        try std.testing.expect(stmt.where != null);
    }
}

test "parse drop table statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    {
        const input = "DROP TABLE users;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_drop(&p);

        try std.testing.expectEqualStrings("users", stmt.table);
        try std.testing.expect(!stmt.if_exists);
    }

    {
        const input = "DROP TABLE IF EXISTS users;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_drop(&p);

        try std.testing.expectEqualStrings("users", stmt.table);
        try std.testing.expect(stmt.if_exists);
    }
}
