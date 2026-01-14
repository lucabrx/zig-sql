const std = @import("std");
const ast = @import("ast.zig");
const token = @import("../lexer/token.zig");
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;

pub fn parse_select(self: *Parser) ParseError!ast.SelectStatement {
    const stmt = self.allocator.create(ast.SelectStatement) catch return error.OutOfMemory;
    self.advance();

    var is_distinct = false;
    if (self.current.type == token.TokenType.distinct) {
        is_distinct = true;
        self.advance();
    }

    stmt.* = ast.SelectStatement{
        .distinct = is_distinct,
        .columns = try parse_select_columns(self),
        .from = "",
        .joins = &[_]ast.JoinClause{},
        .where = null,
        .group_by = &[_][]const u8{},
        .order_by = &[_]ast.OrderBy{},
        .limit = null,
        .offset = null,
    };

    if (!self.expect(token.TokenType.from)) {
        return error.ExpectedFrom;
    }

    if (self.current.type != token.TokenType.ident) {
        self.addError("Expected table name, got '{s}'", .{@tagName(self.current.type)});
        return error.ExpectedIdentifier;
    }
    stmt.from = self.current.literal;
    self.advance();

    stmt.joins = try parse_joins(self);

    if (self.current.type == token.TokenType.where) {
        self.advance();
        stmt.where = try self.parse_or_expression();
    }

    if (self.current.type == token.TokenType.group) {
        self.advance();
        if (!self.expect(token.TokenType.by)) {
            return error.ExpectedBy;
        }
        stmt.group_by = try parse_group_by(self);
    }

    if (self.current.type == token.TokenType.order) {
        self.advance();
        if (!self.expect(token.TokenType.by)) {
            return error.ExpectedBy;
        }
        stmt.order_by = try parse_order_by(self);
    }

    if (self.current.type == token.TokenType.limit) {
        self.advance();
        if (self.current.type != token.TokenType.int) {
            self.addError("Expected integer  for LIMIT, got '{s}'", .{@tagName(self.current.type)});
            return error.UnexpectedToken;
        }
        const limit_value = std.fmt.parseInt(i64, self.current.literal, 10) catch {
            self.addError("Invalid integer literal '{s}'", .{self.current.literal});
            return error.InvalidIntegerLiteral;
        };
        stmt.limit = limit_value;
        self.advance();
    }

    if (self.current.type == token.TokenType.offset) {
        self.advance();
        if (self.current.type != token.TokenType.int) {
            self.addError("Expected integer for OFFSET, got '{s}'", .{@tagName(self.current.type)});
            return error.UnexpectedToken;
        }
        const offset_value = std.fmt.parseInt(i64, self.current.literal, 10) catch {
            self.addError("Invalid integer literal '{s}'", .{self.current.literal});
            return error.InvalidIntegerLiteral;
        };
        stmt.offset = offset_value;
        self.advance();
    }

    if (self.current.type == token.TokenType.semicolon) {
        self.advance();
    }

    return stmt.*;
}

fn parse_joins(self: *Parser) ParseError![]ast.JoinClause {
    var joins = std.ArrayList(ast.JoinClause){};
    defer joins.deinit(self.allocator);

    while (true) {
        var join_type: ?ast.JoinType = null;

        if (self.current.type == token.TokenType.inner) {
            join_type = .inner;
            self.advance();
            if (self.current.type != token.TokenType.join) {
                self.addError("Expected JOIN after INNER", .{});
                return error.UnexpectedToken;
            }
            self.advance();
        } else if (self.current.type == token.TokenType.left) {
            join_type = .left;
            self.advance();
            if (self.current.type == token.TokenType.outer) {
                self.advance();
            }
            if (self.current.type != token.TokenType.join) {
                self.addError("Expected JOIN after LEFT", .{});
                return error.UnexpectedToken;
            }
            self.advance();
        } else if (self.current.type == token.TokenType.right) {
            join_type = .right;
            self.advance();
            if (self.current.type == token.TokenType.outer) {
                self.advance();
            }
            if (self.current.type != token.TokenType.join) {
                self.addError("Expected JOIN after RIGHT", .{});
                return error.UnexpectedToken;
            }
            self.advance();
        } else if (self.current.type == token.TokenType.cross) {
            join_type = .cross;
            self.advance();
            if (self.current.type != token.TokenType.join) {
                self.addError("Expected JOIN after CROSS", .{});
                return error.UnexpectedToken;
            }
            self.advance();
        } else if (self.current.type == token.TokenType.join) {
            join_type = .inner;
            self.advance();
        } else {
            break;
        }

        if (self.current.type != token.TokenType.ident) {
            self.addError("Expected table name after JOIN", .{});
            return error.ExpectedIdentifier;
        }
        const table_name = self.current.literal;
        self.advance();

        var condition: ?ast.Expression = null;
        if (join_type != .cross and self.current.type == token.TokenType.on) {
            self.advance();
            condition = try self.parse_or_expression();
        }

        try joins.append(self.allocator, ast.JoinClause{
            .join_type = join_type.?,
            .table = table_name,
            .condition = condition,
        });
    }

    return joins.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

fn parse_select_columns(self: *Parser) ParseError![]ast.Expression {
    var columns = std.ArrayList(ast.Expression){};
    defer columns.deinit(self.allocator);

    while (true) {
        if (self.current.type == token.TokenType.from or
            self.current.type == token.TokenType.semicolon or
            self.current.type == token.TokenType.eof)
        {
            break;
        }

        const expr = try self.parse_or_expression();
        try columns.append(self.allocator, expr);

        if (self.current.type == token.TokenType.comma) {
            self.advance();
        } else {
            break;
        }
    }
    return columns.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

fn parse_group_by(self: *Parser) ParseError![][]const u8 {
    var cols = std.ArrayList([]const u8){};
    defer cols.deinit(self.allocator);

    while (true) {
        if (self.current.type != token.TokenType.ident) {
            break;
        }
        try cols.append(self.allocator, self.current.literal);
        self.advance();

        if (self.current.type == token.TokenType.comma) {
            self.advance();
        } else {
            break;
        }
    }
    return cols.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

fn parse_order_by(self: *Parser) ParseError![]ast.OrderBy {
    var orders = std.ArrayList(ast.OrderBy){};
    defer orders.deinit(self.allocator);

    while (true) {
        if (self.current.type != token.TokenType.ident) {
            break;
        }

        var order = ast.OrderBy{
            .column = self.current.literal,
            .desc = false,
        };
        self.advance();

        if (self.current.type == token.TokenType.asc) {
            order.desc = false;
            self.advance();
        } else if (self.current.type == token.TokenType.desc) {
            order.desc = true;
            self.advance();
        }
        try orders.append(self.allocator, order);

        if (self.current.type == token.TokenType.comma) {
            self.advance();
        } else {
            break;
        }
    }
    return orders.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

const lexer = @import("../lexer/lexer.zig");

test "parse select statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    {
        const input = "SELECT * FROM users;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqualStrings("users", stmt.from);
        try std.testing.expectEqual(1, stmt.columns.len);
    }

    {
        const input = "SELECT id, name, email FROM users;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqualStrings("users", stmt.from);
        try std.testing.expectEqual(3, stmt.columns.len);
        try std.testing.expectEqualStrings("id", stmt.columns[0].identifier.name);
        try std.testing.expectEqualStrings("name", stmt.columns[1].identifier.name);
        try std.testing.expectEqualStrings("email", stmt.columns[2].identifier.name);
    }

    {
        const input = "SELECT * FROM products LIMIT 10;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqualStrings("products", stmt.from);
        try std.testing.expectEqual(10, stmt.limit.?);
    }

    {
        const input = "SELECT * FROM products LIMIT 10 OFFSET 20;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqualStrings("products", stmt.from);
        try std.testing.expectEqual(10, stmt.limit.?);
        try std.testing.expectEqual(20, stmt.offset.?);
    }
}

test "parse join statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    {
        const input = "SELECT * FROM users INNER JOIN orders ON users.id = orders.user_id;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqualStrings("users", stmt.from);
        try std.testing.expectEqual(1, stmt.joins.len);
        try std.testing.expectEqual(ast.JoinType.inner, stmt.joins[0].join_type);
        try std.testing.expectEqualStrings("orders", stmt.joins[0].table);
    }

    {
        const input = "SELECT * FROM users LEFT JOIN orders ON users.id = orders.user_id;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqual(ast.JoinType.left, stmt.joins[0].join_type);
    }

    {
        const input = "SELECT * FROM users CROSS JOIN products;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqual(ast.JoinType.cross, stmt.joins[0].join_type);
        try std.testing.expect(stmt.joins[0].condition == null);
    }
}
