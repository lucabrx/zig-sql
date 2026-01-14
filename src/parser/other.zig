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
pub const DropResult = union(enum) {
    table: ast.DropTableStatement,
    index: ast.DropIndexStatement,
};

pub fn parse_drop(self: *Parser) ParserError!DropResult {
    self.advance();

    if (self.current.type == token.TokenType.index) {
        return DropResult{ .index = try parse_drop_index(self) };
    }

    if (self.current.type != token.TokenType.table) {
        return error.UnexpectedToken;
    }

    return DropResult{ .table = try parse_drop_table(self) };
}

fn parse_drop_table(self: *Parser) ParserError!ast.DropTableStatement {
    const stmt = self.allocator.create(ast.DropTableStatement) catch return error.OutOfMemory;
    stmt.if_exists = false;

    self.advance(); // consume TABLE

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

fn parse_drop_index(self: *Parser) ParserError!ast.DropIndexStatement {
    const stmt = self.allocator.create(ast.DropIndexStatement) catch return error.OutOfMemory;
    stmt.if_exists = false;

    self.advance(); // consume INDEX

    if (self.current.type == token.TokenType.@"if") {
        self.advance();
        if (self.current.type == token.TokenType.exists) {
            stmt.if_exists = true;
            self.advance();
        }
    }

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected index name, got '{s}'", .{@tagName(self.current.type)});
        return error.ExpectedIdentifier;
    }
    stmt.index_name = self.current.literal;
    self.advance();

    if (self.current.type == token.TokenType.semicolon) {
        self.advance();
    }

    return stmt.*;
}

pub fn parse_alter(self: *Parser) ParserError!ast.AlterTableStatement {
    const stmt = self.allocator.create(ast.AlterTableStatement) catch return error.OutOfMemory;

    self.advance(); // consume ALTER

    if (self.current.type != token.TokenType.table) {
        self.addError("Expected TABLE after ALTER", .{});
        return error.UnexpectedToken;
    }
    self.advance();

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected table name", .{});
        return error.ExpectedIdentifier;
    }
    stmt.table = self.current.literal;
    self.advance();

    if (self.current.type == token.TokenType.add) {
        self.advance();
        if (self.current.type == token.TokenType.column) {
            self.advance();
        }
        stmt.action = ast.AlterAction{ .add_column = try parse_column_def(self) };
    } else if (self.current.type == token.TokenType.drop) {
        self.advance();
        if (self.current.type == token.TokenType.column) {
            self.advance();
        }
        if (self.current.type != token.TokenType.ident) {
            self.addError("Expected column name", .{});
            return error.ExpectedIdentifier;
        }
        stmt.action = ast.AlterAction{ .drop_column = self.current.literal };
        self.advance();
    } else if (self.current.type == token.TokenType.rename) {
        self.advance();
        if (self.current.type == token.TokenType.to) {
            self.advance();
            if (self.current.type != token.TokenType.ident) {
                self.addError("Expected new table name", .{});
                return error.ExpectedIdentifier;
            }
            stmt.action = ast.AlterAction{ .rename_table = self.current.literal };
            self.advance();
        } else if (self.current.type == token.TokenType.column) {
            self.advance();
            if (self.current.type != token.TokenType.ident) {
                self.addError("Expected column name", .{});
                return error.ExpectedIdentifier;
            }
            const old_name = self.current.literal;
            self.advance();
            if (self.current.type != token.TokenType.to) {
                self.addError("Expected TO after column name", .{});
                return error.UnexpectedToken;
            }
            self.advance();
            if (self.current.type != token.TokenType.ident) {
                self.addError("Expected new column name", .{});
                return error.ExpectedIdentifier;
            }
            stmt.action = ast.AlterAction{ .rename_column = .{ .old_name = old_name, .new_name = self.current.literal } };
            self.advance();
        } else {
            self.addError("Expected TO or COLUMN after RENAME", .{});
            return error.UnexpectedToken;
        }
    } else {
        self.addError("Expected ADD, DROP, or RENAME", .{});
        return error.UnexpectedToken;
    }

    if (self.current.type == token.TokenType.semicolon) {
        self.advance();
    }

    return stmt.*;
}

fn parse_column_def(self: *Parser) ParserError!ast.ColumnDef {
    var col = ast.ColumnDef{
        .name = "",
        .type_name = "",
        .primary_key = false,
        .not_null = false,
    };

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected column name", .{});
        return error.ExpectedIdentifier;
    }
    col.name = self.current.literal;
    self.advance();

    col.type_name = switch (self.current.type) {
        .integer => "INTEGER",
        .text => "TEXT",
        .real => "REAL",
        .blob => "BLOB",
        .boolean => "BOOLEAN",
        .date => "DATE",
        .time => "TIME",
        .datetime => "DATETIME",
        else => {
            self.addError("Expected column type", .{});
            return error.ExpectedColumnType;
        },
    };
    self.advance();

    while (self.current.type == token.TokenType.primary or
        self.current.type == token.TokenType.not)
    {
        if (self.current.type == token.TokenType.primary) {
            self.advance();
            if (self.current.type != token.TokenType.key) {
                return error.ExpectedKeyKeyword;
            }
            col.primary_key = true;
            self.advance();
        } else if (self.current.type == token.TokenType.not) {
            self.advance();
            if (self.current.type != token.TokenType.null) {
                return error.ExpectedNullKeyword;
            }
            col.not_null = true;
            self.advance();
        }
    }

    return col;
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
        const result = try parse_drop(&p);
        const stmt = result.table;

        try std.testing.expectEqualStrings("users", stmt.table);
        try std.testing.expect(!stmt.if_exists);
    }

    {
        const input = "DROP TABLE IF EXISTS users;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const result = try parse_drop(&p);
        const stmt = result.table;

        try std.testing.expectEqualStrings("users", stmt.table);
        try std.testing.expect(stmt.if_exists);
    }
}

test "parse drop index statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    {
        const input = "DROP INDEX idx_email;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const result = try parse_drop(&p);
        const stmt = result.index;

        try std.testing.expectEqualStrings("idx_email", stmt.index_name);
        try std.testing.expect(!stmt.if_exists);
    }

    {
        const input = "DROP INDEX IF EXISTS idx_email;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const result = try parse_drop(&p);
        const stmt = result.index;

        try std.testing.expectEqualStrings("idx_email", stmt.index_name);
        try std.testing.expect(stmt.if_exists);
    }
}
