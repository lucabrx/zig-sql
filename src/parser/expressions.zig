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
    var left = try parse_additive_expression(self);

    switch (self.current.type) {
        token.TokenType.eq => {
            self.advance();
            const right = try parse_additive_expression(self);
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
            const right = try parse_additive_expression(self);
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
            const right = try parse_additive_expression(self);
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
            const right = try parse_additive_expression(self);
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
            const right = try parse_additive_expression(self);
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
            const right = try parse_additive_expression(self);
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
        token.TokenType.between => {
            return try parse_between(self, left, false);
        },
        token.TokenType.in => {
            return try parse_in(self, left, false);
        },
        token.TokenType.like => {
            return try parse_like(self, left, false);
        },
        token.TokenType.is => {
            return try parse_is_null(self, left);
        },
        token.TokenType.not => {
            self.advance();
            if (self.current.type == token.TokenType.between) {
                return try parse_between(self, left, true);
            } else if (self.current.type == token.TokenType.in) {
                return try parse_in(self, left, true);
            } else if (self.current.type == token.TokenType.like) {
                return try parse_like(self, left, true);
            }
            return left;
        },
        else => {
            return left;
        },
    }

    return left;
}

fn parse_additive_expression(self: *Parser) ParseError!ast.Expression {
    var left = try parse_multiplicative_expression(self);

    while (self.current.type == .plus or self.current.type == .minus) {
        const op = if (self.current.type == .plus) "+" else "-";
        self.advance();
        const right = try parse_multiplicative_expression(self);
        const binary = self.allocator.create(ast.BinaryExpression) catch return error.OutOfMemory;
        binary.* = ast.BinaryExpression{
            .left = left,
            .operator = op,
            .right = right,
        };
        left = ast.Expression{ .binary_expression = binary };
    }
    return left;
}

fn parse_multiplicative_expression(self: *Parser) ParseError!ast.Expression {
    var left = try parse_primary_expression(self);

    while (self.current.type == .asterisk or self.current.type == .slash) {
        const op = if (self.current.type == .asterisk) "*" else "/";
        self.advance();
        const right = try parse_primary_expression(self);
        const binary = self.allocator.create(ast.BinaryExpression) catch return error.OutOfMemory;
        binary.* = ast.BinaryExpression{
            .left = left,
            .operator = op,
            .right = right,
        };
        left = ast.Expression{ .binary_expression = binary };
    }
    return left;
}

fn parse_between(self: *Parser, expr: ast.Expression, negated: bool) ParseError!ast.Expression {
    self.advance();
    const low = try parse_primary_expression(self);
    if (!self.expect(token.TokenType.@"and")) {
        return error.ExpectedAnd;
    }
    const high = try parse_primary_expression(self);

    const between = self.allocator.create(ast.BetweenExpression) catch return error.OutOfMemory;
    between.* = ast.BetweenExpression{
        .expr = expr,
        .low = low,
        .high = high,
        .negated = negated,
    };
    return ast.Expression{ .between = between };
}

fn parse_in(self: *Parser, expr: ast.Expression, negated: bool) ParseError!ast.Expression {
    self.advance();
    if (!self.expect(token.TokenType.lparen)) {
        return error.ExpectedOpenParen;
    }

    if (self.current.type == token.TokenType.select) {
        const select = @import("select.zig");
        const subquery_stmt = try select.parse_select(self);
        if (!self.expect(token.TokenType.rparen)) {
            return error.ExpectedCloseParen;
        }
        const in_sub = self.allocator.create(ast.InSubqueryExpression) catch return error.OutOfMemory;
        in_sub.* = ast.InSubqueryExpression{
            .expr = expr,
            .subquery = subquery_stmt,
            .negated = negated,
        };
        return ast.Expression{ .in_subquery = in_sub };
    }

    var list = std.ArrayList(ast.Expression){};
    defer list.deinit(self.allocator);

    while (self.current.type != token.TokenType.rparen and self.current.type != token.TokenType.eof) {
        const val = try parse_primary_expression(self);
        try list.append(self.allocator, val);
        if (self.current.type == token.TokenType.comma) {
            self.advance();
        } else {
            break;
        }
    }

    if (!self.expect(token.TokenType.rparen)) {
        return error.ExpectedCloseParen;
    }

    const in_list = self.allocator.create(ast.InListExpression) catch return error.OutOfMemory;
    in_list.* = ast.InListExpression{
        .expr = expr,
        .list = list.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
        .negated = negated,
    };
    return ast.Expression{ .in_list = in_list };
}

fn parse_like(self: *Parser, expr: ast.Expression, negated: bool) ParseError!ast.Expression {
    self.advance();
    const pattern = try parse_primary_expression(self);

    const like = self.allocator.create(ast.LikeExpression) catch return error.OutOfMemory;
    like.* = ast.LikeExpression{
        .expr = expr,
        .pattern = pattern,
        .negated = negated,
    };
    return ast.Expression{ .like = like };
}

fn parse_is_null(self: *Parser, expr: ast.Expression) ParseError!ast.Expression {
    self.advance();
    var negated = false;
    if (self.current.type == token.TokenType.not) {
        negated = true;
        self.advance();
    }
    if (self.current.type != token.TokenType.null) {
        return error.ExpectedNull;
    }
    self.advance();

    const is_null = self.allocator.create(ast.IsNullExpression) catch return error.OutOfMemory;
    is_null.* = ast.IsNullExpression{
        .expr = expr,
        .negated = negated,
    };
    return ast.Expression{ .is_null = is_null };
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
        token.TokenType.count, token.TokenType.sum, token.TokenType.avg, token.TokenType.min, token.TokenType.max => {
            return try parse_aggregate(self);
        },
        token.TokenType.case => {
            return try parse_case(self);
        },
        token.TokenType.upper, token.TokenType.lower, token.TokenType.length, token.TokenType.substr, token.TokenType.concat, token.TokenType.trim, token.TokenType.abs, token.TokenType.round, token.TokenType.floor, token.TokenType.ceil, token.TokenType.coalesce, token.TokenType.nullif, token.TokenType.ifnull, token.TokenType.typeof, token.TokenType.strftime => {
            return try parse_function_call(self);
        },
        token.TokenType.cast => {
            return try parse_cast(self);
        },
        else => {
            self.addError("Unexpected token in expression: '{s}'", .{@tagName(self.current.type)});
            return error.UnexpectedToken;
        },
    }
}

fn parse_aggregate(self: *Parser) ParseError!ast.Expression {
    const func = switch (self.current.type) {
        token.TokenType.count => ast.AggregateFunction.count,
        token.TokenType.sum => ast.AggregateFunction.sum,
        token.TokenType.avg => ast.AggregateFunction.avg,
        token.TokenType.min => ast.AggregateFunction.min,
        token.TokenType.max => ast.AggregateFunction.max,
        else => return error.UnexpectedToken,
    };
    self.advance();

    if (!self.expect(token.TokenType.lparen)) {
        return error.ExpectedOpenParen;
    }

    var is_distinct = false;
    if (self.current.type == token.TokenType.distinct) {
        is_distinct = true;
        self.advance();
    }

    var arg: ?ast.Expression = null;
    if (self.current.type == token.TokenType.asterisk) {
        self.advance();
    } else if (self.current.type != token.TokenType.rparen) {
        arg = try parse_or_expression(self);
    }

    if (!self.expect(token.TokenType.rparen)) {
        return error.ExpectedCloseParen;
    }

    const agg = self.allocator.create(ast.AggregateExpression) catch return error.OutOfMemory;
    agg.* = ast.AggregateExpression{
        .function = func,
        .arg = arg,
        .distinct = is_distinct,
    };
    return ast.Expression{ .aggregate = agg };
}

fn parse_case(self: *Parser) ParseError!ast.Expression {
    self.advance();

    var operand: ?ast.Expression = null;
    if (self.current.type != token.TokenType.when) {
        operand = try parse_or_expression(self);
    }

    var when_clauses = std.ArrayList(ast.WhenClause){};
    defer when_clauses.deinit(self.allocator);

    while (self.current.type == token.TokenType.when) {
        self.advance();
        const condition = try parse_or_expression(self);
        if (self.current.type != token.TokenType.then) {
            return error.ExpectedThen;
        }
        self.advance();
        const result = try parse_or_expression(self);
        try when_clauses.append(self.allocator, ast.WhenClause{
            .condition = condition,
            .result = result,
        });
    }

    var else_result: ?ast.Expression = null;
    if (self.current.type == token.TokenType.@"else") {
        self.advance();
        else_result = try parse_or_expression(self);
    }

    if (self.current.type != token.TokenType.end) {
        return error.ExpectedEnd;
    }
    self.advance();

    const case_expr = self.allocator.create(ast.CaseExpression) catch return error.OutOfMemory;
    case_expr.* = ast.CaseExpression{
        .operand = operand,
        .when_clauses = when_clauses.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
        .else_result = else_result,
    };
    return ast.Expression{ .case_expr = case_expr };
}

fn parse_function_call(self: *Parser) ParseError!ast.Expression {
    const name = self.current.literal;
    self.advance();

    if (!self.expect(token.TokenType.lparen)) {
        return error.ExpectedOpenParen;
    }

    var args = std.ArrayList(ast.Expression){};
    defer args.deinit(self.allocator);

    while (self.current.type != token.TokenType.rparen and self.current.type != token.TokenType.eof) {
        const arg = try parse_or_expression(self);
        try args.append(self.allocator, arg);
        if (self.current.type == token.TokenType.comma) {
            self.advance();
        } else {
            break;
        }
    }

    if (!self.expect(token.TokenType.rparen)) {
        return error.ExpectedCloseParen;
    }

    const func = self.allocator.create(ast.FunctionCall) catch return error.OutOfMemory;
    func.* = ast.FunctionCall{
        .name = name,
        .args = args.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
    };
    return ast.Expression{ .function_call = func };
}

fn parse_cast(self: *Parser) ParseError!ast.Expression {
    self.advance();

    if (!self.expect(token.TokenType.lparen)) {
        return error.ExpectedOpenParen;
    }

    const expr = try parse_or_expression(self);

    if (self.current.type != token.TokenType.as) {
        return error.ExpectedAs;
    }
    self.advance();

    const type_name = self.current.literal;
    self.advance();

    if (!self.expect(token.TokenType.rparen)) {
        return error.ExpectedCloseParen;
    }

    const type_expr = ast.Expression{ .string_literal = ast.StringLiteral{ .value = type_name } };

    var args = self.allocator.alloc(ast.Expression, 2) catch return error.OutOfMemory;
    args[0] = expr;
    args[1] = type_expr;

    const func = self.allocator.create(ast.FunctionCall) catch return error.OutOfMemory;
    func.* = ast.FunctionCall{
        .name = "CAST",
        .args = args,
    };
    return ast.Expression{ .function_call = func };
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
