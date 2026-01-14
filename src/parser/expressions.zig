const std = @import("std");
const ast = @import("ast.zig");
const token = @import("../lexer/token.zig");
const Parser = @import("parser.zig").Parser;
const ParseError = @import("parser.zig").ParseError;

pub fn parse_or_expression(self: *Parser) ParseError!ast.Expression {
    var left = try parse_and_expression(self);

    while (self.current.type == .@"or") {
        self.advance();
        const right = try parse_and_expression(self);
        const binary = self.allocator.create(ast.BinaryExpression) catch return error.OutOfMemory;
        binary.* = ast.BinaryExpression{
            .left = left,
            .operator = "OR",
            .right = right,
        };
        left = ast.Expression{ .binary_expression = binary };
    }
    return left;
}

pub fn parse_and_expression(self: *Parser) ParseError!ast.Expression {
    var left = try parse_comparison_expression(self);

    while (self.current.type == .@"and") {
        self.advance();
        const right = try parse_comparison_expression(self);
        const binary = self.allocator.create(ast.BinaryExpression) catch return error.OutOfMemory;
        binary.* = ast.BinaryExpression{
            .left = left,
            .operator = "AND",
            .right = right,
        };
        left = ast.Expression{ .binary_expression = binary };
    }
    return left;
}

pub fn parse_comparison_expression(self: *Parser) ParseError!ast.Expression {
    var left = try parse_primary_expression(self);

    switch (self.current.type) {
        token.TokenType.eq => {
            self.advance();
            const right = try parse_primary_expression(self);
            const binary = self.allocator.create(ast.BinaryExpression) catch return error.OutOfMemory;
            binary.* = ast.BinaryExpression{
                .left = left,
                .operator = "=",
                .right = right,
            };
            left = ast.Expression{
                .binary_expression = binary,
            };

            return left;
        },
        token.TokenType.neq => {
            self.advance();
            const right = try parse_primary_expression(self);
            const binary = self.allocator.create(ast.BinaryExpression) catch return error.OutOfMemory;
            binary.* = ast.BinaryExpression{
                .left = left,
                .operator = "!=",
                .right = right,
            };
            left = ast.Expression{
                .binary_expression = binary,
            };

            return left;
        },
        token.TokenType.lt => {
            self.advance();
            const right = try parse_primary_expression(self);
            const binary = self.allocator.create(ast.BinaryExpression) catch return error.OutOfMemory;
            binary.* = ast.BinaryExpression{
                .left = left,
                .operator = "<",
                .right = right,
            };
            left = ast.Expression{
                .binary_expression = binary,
            };

            return left;
        },
        token.TokenType.lte => {
            self.advance();
            const right = try parse_primary_expression(self);
            const binary = self.allocator.create(ast.BinaryExpression) catch return error.OutOfMemory;
            binary.* = ast.BinaryExpression{
                .left = left,
                .operator = "<=",
                .right = right,
            };
            left = ast.Expression{
                .binary_expression = binary,
            };
            return left;
        },
        token.TokenType.gt => {
            self.advance();
            const right = try parse_primary_expression(self);
            const binary = self.allocator.create(ast.BinaryExpression) catch return error.OutOfMemory;
            binary.* = ast.BinaryExpression{
                .left = left,
                .operator = ">",
                .right = right,
            };
            left = ast.Expression{
                .binary_expression = binary,
            };
            return left;
        },
        token.TokenType.gte => {
            self.advance();
            const right = try parse_primary_expression(self);
            const binary = self.allocator.create(ast.BinaryExpression) catch return error.OutOfMemory;
            binary.* = ast.BinaryExpression{
                .left = left,
                .operator = ">=",
                .right = right,
            };
            left = ast.Expression{
                .binary_expression = binary,
            };
            return left;
        },
        else => {
            return left;
        },
    }

    return left;
}

pub fn parse_primary_expression(self: *Parser) ParseError!ast.Expression {
    switch (self.current.type) {
        token.TokenType.int => {
            const value = std.fmt.parseInt(i64, self.current.literal, 10) catch {
                self.addError("Invalid integer literal: '{s}'", .{self.current.literal});
                return error.InvalidInteger;
            };

            const expr = ast.Expression{
                .integer_literal = ast.IntegerLiteral{
                    .value = value,
                },
            };
            self.advance();
            return expr;
        },
        token.TokenType.float => {
            const value = std.fmt.parseFloat(f64, self.current.literal) catch {
                self.addError("Invalid float literal: '{s}'", .{self.current.literal});
                return error.InvalidFloat;
            };

            const expr = ast.Expression{
                .float_literal = ast.FloatLiteral{
                    .value = value,
                },
            };
            self.advance();
            return expr;
        },
        token.TokenType.string => {
            const expr = ast.Expression{
                .string_literal = ast.StringLiteral{
                    .value = self.current.literal,
                },
            };
            self.advance();
            return expr;
        },
        token.TokenType.null => {
            const expr = ast.Expression{
                .null_literal = ast.NullLiteral{},
            };
            self.advance();
            return expr;
        },
        token.TokenType.true => {
            const expr = ast.Expression{
                .boolean_literal = ast.BooleanLiteral{
                    .value = true,
                },
            };
            self.advance();
            return expr;
        },
        token.TokenType.false => {
            const expr = ast.Expression{
                .boolean_literal = ast.BooleanLiteral{
                    .value = false,
                },
            };
            self.advance();
            return expr;
        },
        token.TokenType.ident => {
            var name = self.current.literal;
            self.advance();

            if (self.current.type == token.TokenType.dot) {
                self.advance();
                if (self.current.type == token.TokenType.ident) {
                    const qualified_name = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ name, self.current.literal }) catch return error.OutOfMemory;
                    name = qualified_name;
                    self.advance();
                }
            }

            const expr = ast.Expression{
                .identifier = ast.Identifier{
                    .name = name,
                },
            };
            return expr;
        },
        token.TokenType.asterisk => {
            const expr = ast.Expression{
                .star_expression = ast.StarExpression{},
            };
            self.advance();
            return expr;
        },
        token.TokenType.not => {
            self.advance();
            const right = try parse_primary_expression(self);
            const unary = self.allocator.create(ast.UnaryExpression) catch return error.OutOfMemory;
            unary.* = ast.UnaryExpression{
                .operator = "NOT",
                .right = right,
            };
            const expr = ast.Expression{
                .unary_expression = unary,
            };
            return expr;
        },
        token.TokenType.minus => {
            self.advance();
            const right = try parse_primary_expression(self);
            const unary = self.allocator.create(ast.UnaryExpression) catch return error.OutOfMemory;
            unary.* = ast.UnaryExpression{
                .operator = "-",
                .right = right,
            };
            const expr = ast.Expression{
                .unary_expression = unary,
            };
            return expr;
        },
        token.TokenType.lparen => {
            self.advance();
            if (self.current.type == token.TokenType.select) {
                const select = @import("select.zig");
                const subquery_stmt = try select.parse_select(self);
                if (!self.expect(token.TokenType.rparen)) {
                    return error.ExpectedCloseParen;
                }
                const subquery = self.allocator.create(ast.SubqueryExpression) catch return error.OutOfMemory;
                subquery.* = ast.SubqueryExpression{
                    .select = subquery_stmt,
                };
                return ast.Expression{ .subquery = subquery };
            }
            const expr = try parse_or_expression(self);
            if (!self.expect(token.TokenType.rparen)) {
                return error.ExpectedCloseParen;
            }
            return expr;
        },
        else => {
            self.addError("Unexpected token in expression: '{s}'", .{@tagName(self.current.type)});
            return error.UnexpectedToken;
        },
    }
}

const lexer = @import("../lexer/lexer.zig");

test "parse primary expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const TestCase = struct {
        input: []const u8,
        tag: std.meta.Tag(ast.Expression),
        int_val: ?i64 = null,
        float_val: ?f64 = null,
        str_val: ?[]const u8 = null,
        unary_op: ?[]const u8 = null,
        unary_right_int: ?i64 = null,
    };

    const tests = [_]TestCase{
        .{ .input = "100", .tag = .integer_literal, .int_val = 100 },
        .{ .input = "100.5", .tag = .float_literal, .float_val = 100.5 },
        .{ .input = "'hello'", .tag = .string_literal, .str_val = "hello" },
        .{ .input = "NULL", .tag = .null_literal },
        .{ .input = "users", .tag = .identifier, .str_val = "users" },
        .{ .input = "*", .tag = .star_expression },
        .{ .input = "-100", .tag = .unary_expression, .unary_op = "-", .unary_right_int = 100 },
        .{ .input = "(100)", .tag = .integer_literal, .int_val = 100 },
    };

    for (tests) |t| {
        var l = lexer.Lexer.init(t.input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const expr = try parse_primary_expression(&p);

        try std.testing.expectEqual(t.tag, std.meta.activeTag(expr));

        switch (t.tag) {
            .integer_literal => {
                if (t.int_val) |val| {
                    try std.testing.expectEqual(val, expr.integer_literal.value);
                }
            },
            .float_literal => {
                if (t.float_val) |val| {
                    try std.testing.expectEqual(val, expr.float_literal.value);
                }
            },
            .string_literal => {
                if (t.str_val) |val| {
                    try std.testing.expectEqualStrings(val, expr.string_literal.value);
                }
            },
            .identifier => {
                if (t.str_val) |val| {
                    try std.testing.expectEqualStrings(val, expr.identifier.name);
                }
            },
            .unary_expression => {
                if (t.unary_op) |op| {
                    try std.testing.expectEqualStrings(op, expr.unary_expression.operator);
                }
                if (t.unary_right_int) |val| {
                    try std.testing.expect(std.meta.activeTag(expr.unary_expression.right) == .integer_literal);
                    try std.testing.expectEqual(val, expr.unary_expression.right.integer_literal.value);
                }
            },
            else => {},
        }
    }
}

test "parse comparison expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        left: i64,
        operator: []const u8,
        right: i64,
    }{
        .{ .input = "1 = 2", .left = 1, .operator = "=", .right = 2 },
        .{ .input = "1 != 2", .left = 1, .operator = "!=", .right = 2 },
        .{ .input = "1 < 2", .left = 1, .operator = "<", .right = 2 },
        .{ .input = "1 <= 2", .left = 1, .operator = "<=", .right = 2 },
        .{ .input = "1 > 2", .left = 1, .operator = ">", .right = 2 },
        .{ .input = "1 >= 2", .left = 1, .operator = ">=", .right = 2 },
    };

    for (tests) |t| {
        var l = lexer.Lexer.init(t.input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const expr = try parse_comparison_expression(&p);

        try std.testing.expect(std.meta.activeTag(expr) == .binary_expression);
        try std.testing.expectEqualStrings(t.operator, expr.binary_expression.operator);

        try std.testing.expect(std.meta.activeTag(expr.binary_expression.left) == .integer_literal);
        try std.testing.expectEqual(t.left, expr.binary_expression.left.integer_literal.value);

        try std.testing.expect(std.meta.activeTag(expr.binary_expression.right) == .integer_literal);
        try std.testing.expectEqual(t.right, expr.binary_expression.right.integer_literal.value);
    }
}

test "parse and expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        left: i64,
        operator: []const u8,
        right: i64,
    }{
        .{ .input = "1 AND 2", .left = 1, .operator = "AND", .right = 2 },
    };

    for (tests) |t| {
        var l = lexer.Lexer.init(t.input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const expr = try parse_and_expression(&p);

        try std.testing.expect(std.meta.activeTag(expr) == .binary_expression);
        try std.testing.expectEqualStrings(t.operator, expr.binary_expression.operator);

        try std.testing.expect(std.meta.activeTag(expr.binary_expression.left) == .integer_literal);
        try std.testing.expectEqual(t.left, expr.binary_expression.left.integer_literal.value);

        try std.testing.expect(std.meta.activeTag(expr.binary_expression.right) == .integer_literal);
        try std.testing.expectEqual(t.right, expr.binary_expression.right.integer_literal.value);
    }
}

test "parse or expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tests = [_]struct {
        input: []const u8,
        left: i64,
        operator: []const u8,
        right: i64,
    }{
        .{ .input = "1 OR 2", .left = 1, .operator = "OR", .right = 2 },
    };

    for (tests) |t| {
        var l = lexer.Lexer.init(t.input);
        const tokens = try l.tokenize(allocator);

        var p = Parser.init(tokens, allocator);
        const expr = try parse_or_expression(&p);

        try std.testing.expect(std.meta.activeTag(expr) == .binary_expression);
        try std.testing.expectEqualStrings(t.operator, expr.binary_expression.operator);

        try std.testing.expect(std.meta.activeTag(expr.binary_expression.left) == .integer_literal);
        try std.testing.expectEqual(t.left, expr.binary_expression.left.integer_literal.value);

        try std.testing.expect(std.meta.activeTag(expr.binary_expression.right) == .integer_literal);
        try std.testing.expectEqual(t.right, expr.binary_expression.right.integer_literal.value);
    }
}
