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
        .from = &[_]ast.TableRef{},
        .joins = &[_]ast.JoinClause{},
        .where = null,
        .group_by = &[_][]const u8{},
        .having = null,
        .order_by = &[_]ast.OrderBy{},
        .limit = null,
        .offset = null,
    };

    if (!self.expect(token.TokenType.from)) {
        return error.ExpectedFrom;
    }

    stmt.from = try parse_from_tables(self);

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

    if (self.current.type == token.TokenType.having) {
        self.advance();
        stmt.having = try self.parse_or_expression();
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
        var table_ref = ast.TableRef{ .name = self.current.literal, .alias = null };
        self.advance();

        if (self.current.type == token.TokenType.as) {
            self.advance();
            if (self.current.type != token.TokenType.ident) {
                self.addError("Expected alias name after AS", .{});
                return error.ExpectedIdentifier;
            }
            table_ref.alias = self.current.literal;
            self.advance();
        } else if (self.current.type == token.TokenType.ident and self.current.type != token.TokenType.on) {
            table_ref.alias = self.current.literal;
            self.advance();
        }

        var condition: ?ast.Expression = null;
        if (join_type != .cross and self.current.type == token.TokenType.on) {
            self.advance();
            condition = try self.parse_or_expression();
        }

        try joins.append(self.allocator, ast.JoinClause{
            .join_type = join_type.?,
            .table = table_ref,
            .condition = condition,
        });
    }

    return joins.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

fn parse_from_tables(self: *Parser) ParseError![]ast.TableRef {
    var tables = std.ArrayList(ast.TableRef){};
    defer tables.deinit(self.allocator);

    while (true) {
        if (self.current.type != token.TokenType.ident) {
            self.addError("Expected table name, got '{s}'", .{@tagName(self.current.type)});
            return error.ExpectedIdentifier;
        }

        var table_ref = ast.TableRef{ .name = self.current.literal, .alias = null };
        self.advance();

        if (self.current.type == token.TokenType.as) {
            self.advance();
            if (self.current.type != token.TokenType.ident) {
                self.addError("Expected alias name after AS", .{});
                return error.ExpectedIdentifier;
            }
            table_ref.alias = self.current.literal;
            self.advance();
        } else if (self.current.type == token.TokenType.ident and
            !is_keyword(self.current.type))
        {
            table_ref.alias = self.current.literal;
            self.advance();
        }

        try tables.append(self.allocator, table_ref);

        if (self.current.type == token.TokenType.comma) {
            self.advance();
        } else {
            break;
        }
    }

    return tables.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}

fn is_keyword(t: token.TokenType) bool {
    return t == token.TokenType.where or
        t == token.TokenType.join or
        t == token.TokenType.inner or
        t == token.TokenType.left or
        t == token.TokenType.right or
        t == token.TokenType.cross or
        t == token.TokenType.order or
        t == token.TokenType.group or
        t == token.TokenType.limit or
        t == token.TokenType.having or
        t == token.TokenType.on;
}

fn parse_select_columns(self: *Parser) ParseError![]ast.SelectColumn {
    var columns = std.ArrayList(ast.SelectColumn){};
    defer columns.deinit(self.allocator);

    while (true) {
        if (self.current.type == token.TokenType.from or
            self.current.type == token.TokenType.semicolon or
            self.current.type == token.TokenType.eof)
        {
            break;
        }

        const expr = try self.parse_or_expression();
        var alias: ?[]const u8 = null;

        if (self.current.type == token.TokenType.as) {
            self.advance();
            if (self.current.type != token.TokenType.ident) {
                self.addError("Expected alias name after AS", .{});
                return error.ExpectedIdentifier;
            }
            alias = self.current.literal;
            self.advance();
        }

        try columns.append(self.allocator, ast.SelectColumn{ .expr = expr, .alias = alias });

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

pub fn parse_union(self: *Parser, left: ast.SelectStatement) ParseError!ast.Statement {
    self.advance();

    var is_all = false;
    if (self.current.type == token.TokenType.all) {
        is_all = true;
        self.advance();
    }

    if (self.current.type != token.TokenType.select) {
        self.addError("Expected SELECT after UNION", .{});
        return error.UnexpectedToken;
    }

    const right_select = try parse_select(self);

    const right_ptr = self.allocator.create(ast.UnionOrSelect) catch return error.OutOfMemory;

    if (self.current.type == token.TokenType.@"union") {
        const nested = try parse_union(self, right_select);
        right_ptr.* = ast.UnionOrSelect{ .union_stmt = nested.union_stmt };
    } else {
        right_ptr.* = ast.UnionOrSelect{ .select = right_select };
    }

    return ast.Statement{
        .union_stmt = ast.UnionStatement{
            .left = left,
            .right = right_ptr,
            .all = is_all,
        },
    };
}

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

        try std.testing.expectEqual(1, stmt.from.len);
        try std.testing.expectEqualStrings("users", stmt.from[0].name);
        try std.testing.expectEqual(1, stmt.columns.len);
    }

    {
        const input = "SELECT id, name, email FROM users;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqual(1, stmt.from.len);
        try std.testing.expectEqualStrings("users", stmt.from[0].name);
        try std.testing.expectEqual(3, stmt.columns.len);
        try std.testing.expectEqualStrings("id", stmt.columns[0].expr.identifier.name);
        try std.testing.expectEqualStrings("name", stmt.columns[1].expr.identifier.name);
        try std.testing.expectEqualStrings("email", stmt.columns[2].expr.identifier.name);
    }

    {
        const input = "SELECT * FROM products LIMIT 10;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqual(1, stmt.from.len);
        try std.testing.expectEqualStrings("products", stmt.from[0].name);
        try std.testing.expectEqual(10, stmt.limit.?);
    }

    {
        const input = "SELECT * FROM products LIMIT 10 OFFSET 20;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqual(1, stmt.from.len);
        try std.testing.expectEqualStrings("products", stmt.from[0].name);
        try std.testing.expectEqual(10, stmt.limit.?);
        try std.testing.expectEqual(20, stmt.offset.?);
    }

    {
        const input = "SELECT * FROM users, orders;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqual(2, stmt.from.len);
        try std.testing.expectEqualStrings("users", stmt.from[0].name);
        try std.testing.expectEqualStrings("orders", stmt.from[1].name);
    }

    {
        const input = "SELECT * FROM users u, orders o WHERE u.id = o.user_id;";
        var l = lexer.Lexer.init(input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const stmt = try parse_select(&p);

        try std.testing.expectEqual(2, stmt.from.len);
        try std.testing.expectEqualStrings("users", stmt.from[0].name);
        try std.testing.expectEqualStrings("u", stmt.from[0].alias.?);
        try std.testing.expectEqualStrings("orders", stmt.from[1].name);
        try std.testing.expectEqualStrings("o", stmt.from[1].alias.?);
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

        try std.testing.expectEqual(1, stmt.from.len);
        try std.testing.expectEqualStrings("users", stmt.from[0].name);
        try std.testing.expectEqual(1, stmt.joins.len);
        try std.testing.expectEqual(ast.JoinType.inner, stmt.joins[0].join_type);
        try std.testing.expectEqualStrings("orders", stmt.joins[0].table.name);
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
