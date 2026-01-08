const std = @import("std");
const token = @import("token.zig");
const helpers = @import("../helpers.zig");

pub const Lexer = struct {
    input: []const u8, // input SQL string
    pos: usize = 0, // pos to current character
    read_pos: usize = 0, // pos to next character
    ch: u8 = 0,
    line: usize = 1,
    column: usize = 0,

    pub fn init(input: []const u8) Lexer {
        var l = Lexer{
            .input = input,
        };
        l.read_char();
        return l;
    }

    pub fn read_char(self: *Lexer) void {
        if (self.read_pos >= self.input.len) {
            self.ch = 0; // ASCII Nul = end of input
        } else {
            self.ch = self.input[self.read_pos];
        }

        self.pos = self.read_pos;
        self.read_pos += 1;
        self.column += 1;

        // if new line set column to 0 and increment line
        if (self.ch == '\n') {
            self.line += 1;
            self.column = 0;
        }
    }

    pub fn peek_char(self: *Lexer) u8 {
        if (self.read_pos >= self.input.len) {
            return 0;
        }
        return self.input[self.read_pos];
    }

    pub fn next_token(self: *Lexer) token.Token {
        self.skip_whitespace();
        const start_line = self.line;
        const start_column = self.column;

        if (self.ch == 0) {
            return token.Token{ .type = .eof, .literal = "", .line = start_line, .column = start_column };
        }

        var tok = token.Token{ .type = .illegal, .literal = "", .line = start_line, .column = start_column };

        const ch_str = self.input[self.pos..self.read_pos];

        switch (self.ch) {
            '=' => tok = self.new_token(.eq, ch_str, start_line, start_column),
            '+' => tok = self.new_token(.plus, ch_str, start_line, start_column),
            '-' => tok = self.new_token(.minus, ch_str, start_line, start_column),
            '*' => tok = self.new_token(.asterisk, ch_str, start_line, start_column),
            '/' => tok = self.new_token(.slash, ch_str, start_line, start_column),
            ',' => tok = self.new_token(.comma, ch_str, start_line, start_column),
            ';' => tok = self.new_token(.semicolon, ch_str, start_line, start_column),
            '(' => tok = self.new_token(.lparen, ch_str, start_line, start_column),
            ')' => tok = self.new_token(.rparen, ch_str, start_line, start_column),
            '.' => tok = self.new_token(.dot, ch_str, start_line, start_column),
            '<' => {
                if (self.peek_char() == '=') {
                    const start = self.pos;
                    self.read_char();
                    tok = self.new_token(.lte, self.input[start..self.read_pos], start_line, start_column);
                } else if (self.peek_char() == '>') {
                    const start = self.pos;
                    self.read_char();
                    tok = self.new_token(.neq, self.input[start..self.read_pos], start_line, start_column);
                } else {
                    tok = self.new_token(.lt, ch_str, start_line, start_column);
                }
            },

            '>' => {
                if (self.peek_char() == '=') {
                    const start = self.pos;
                    self.read_char();
                    tok = self.new_token(.gte, self.input[start..self.read_pos], start_line, start_column);
                } else {
                    tok = self.new_token(.gt, ch_str, start_line, start_column);
                }
            },
            '!' => {
                if (self.peek_char() == '=') {
                    const start = self.pos;
                    self.read_char();
                    tok = self.new_token(.neq, self.input[start..self.read_pos], start_line, start_column);
                } else {
                    tok = self.new_token(.illegal, ch_str, start_line, start_column);
                }
            },
            '\'' => {
                tok.type = .string;
                tok.literal = self.read_string();
                tok.line = start_line;
                tok.column = start_column;
                return tok;
            },
            else => {
                if (helpers.is_letter(self.ch)) {
                    tok.literal = self.read_identifier();
                    tok.type = token.lookup_ident(tok.literal);
                    tok.line = start_line;
                    tok.column = start_column;
                    return tok;
                } else if (std.ascii.isDigit(self.ch)) {
                    const result = self.read_number();
                    tok.literal = result.literal;
                    tok.type = result.type;
                    tok.line = start_line;
                    tok.column = start_column;
                    return tok;
                } else {
                    tok = self.new_token(.illegal, ch_str, start_line, start_column);
                }
            },
        }

        self.read_char();
        return tok;
    }

    fn new_token(self: *Lexer, token_type: token.TokenType, literal: []const u8, line: usize, col: usize) token.Token {
        _ = self;
        return token.Token{
            .type = token_type,
            .literal = literal,
            .line = line,
            .column = col,
        };
    }

    fn skip_whitespace(self: *Lexer) void {
        while (self.ch == ' ' or self.ch == '\t' or self.ch == '\n' or self.ch == '\r') {
            self.read_char();
        }
    }

    fn read_string(self: *Lexer) []const u8 {
        self.read_char();
        const start = self.pos;

        while (true) {
            if (self.ch == '\'') {
                // Check for escaped quote ('')
                if (self.peek_char() == '\'') {
                    self.read_char();
                    self.read_char();
                    continue;
                }
                break;
            }
            if (self.ch == 0) {
                break;
            }
            self.read_char();
        }

        const str = self.input[start..self.pos];

        // Skip closing quote if we aren't at EOF
        if (self.ch == '\'') {
            self.read_char();
        }

        return str;
    }

    fn read_identifier(self: *Lexer) []const u8 {
        const start = self.pos;
        while (helpers.is_letter(self.ch) or std.ascii.isDigit(self.ch) or self.ch == '_') {
            self.read_char();
        }
        return self.input[start..self.pos];
    }

    const NumberResult = struct { literal: []const u8, type: token.TokenType };

    fn read_number(self: *Lexer) NumberResult {
        const start = self.pos;
        var token_type: token.TokenType = .int;
        while (std.ascii.isDigit(self.ch)) {
            self.read_char();
        }

        if (self.ch == '.' and std.ascii.isDigit(self.peek_char())) {
            token_type = .float;
            self.read_char(); // consume dot
            while (std.ascii.isDigit(self.ch)) {
                self.read_char();
            }
        }

        return NumberResult{ .literal = self.input[start..self.pos], .type = token_type };
    }

    pub fn tokenize(self: *Lexer, allocator: std.mem.Allocator) ![]token.Token {
        var tokens: std.ArrayList(token.Token) = .empty;
        defer tokens.deinit(allocator);

        while (true) {
            const tok = self.next_token();
            try tokens.append(allocator, tok);
            if (tok.type == .eof) break;
        }
        return tokens.toOwnedSlice(allocator);
    }
};

test "Lexer - next_token symbols and keywords" {
    const input =
        \\= + - * / , ; ( ) . < > <= >= != <> !
        \\SELECT FROM WHERE INSERT INTO VALUES CREATE TABLE DELETE UPDATE SET AND OR NOT NULL PRIMARY KEY INTEGER TEXT REAL BLOB ORDER BY ASC DESC LIMIT OFFSET DROP IF EXISTS
    ;

    const tests = [_]struct {
        expectedType: token.TokenType,
        expectedLiteral: []const u8,
    }{
        .{ .expectedType = .eq, .expectedLiteral = "=" },
        .{ .expectedType = .plus, .expectedLiteral = "+" },
        .{ .expectedType = .minus, .expectedLiteral = "-" },
        .{ .expectedType = .asterisk, .expectedLiteral = "*" },
        .{ .expectedType = .slash, .expectedLiteral = "/" },
        .{ .expectedType = .comma, .expectedLiteral = "," },
        .{ .expectedType = .semicolon, .expectedLiteral = ";" },
        .{ .expectedType = .lparen, .expectedLiteral = "(" },
        .{ .expectedType = .rparen, .expectedLiteral = ")" },
        .{ .expectedType = .dot, .expectedLiteral = "." },
        .{ .expectedType = .lt, .expectedLiteral = "<" },
        .{ .expectedType = .gt, .expectedLiteral = ">" },
        .{ .expectedType = .lte, .expectedLiteral = "<=" },
        .{ .expectedType = .gte, .expectedLiteral = ">=" },
        .{ .expectedType = .neq, .expectedLiteral = "!=" },
        .{ .expectedType = .neq, .expectedLiteral = "<>" },
        .{ .expectedType = .illegal, .expectedLiteral = "!" },
        .{ .expectedType = .select, .expectedLiteral = "SELECT" },
        .{ .expectedType = .from, .expectedLiteral = "FROM" },
        .{ .expectedType = .where, .expectedLiteral = "WHERE" },
        .{ .expectedType = .insert, .expectedLiteral = "INSERT" },
        .{ .expectedType = .into, .expectedLiteral = "INTO" },
        .{ .expectedType = .values, .expectedLiteral = "VALUES" },
        .{ .expectedType = .create, .expectedLiteral = "CREATE" },
        .{ .expectedType = .table, .expectedLiteral = "TABLE" },
        .{ .expectedType = .delete, .expectedLiteral = "DELETE" },
        .{ .expectedType = .update, .expectedLiteral = "UPDATE" },
        .{ .expectedType = .set, .expectedLiteral = "SET" },
        .{ .expectedType = .@"and", .expectedLiteral = "AND" },
        .{ .expectedType = .@"or", .expectedLiteral = "OR" },
        .{ .expectedType = .not, .expectedLiteral = "NOT" },
        .{ .expectedType = .null, .expectedLiteral = "NULL" },
        .{ .expectedType = .primary, .expectedLiteral = "PRIMARY" },
        .{ .expectedType = .key, .expectedLiteral = "KEY" },
        .{ .expectedType = .integer, .expectedLiteral = "INTEGER" },
        .{ .expectedType = .text, .expectedLiteral = "TEXT" },
        .{ .expectedType = .real, .expectedLiteral = "REAL" },
        .{ .expectedType = .blob, .expectedLiteral = "BLOB" },
        .{ .expectedType = .order, .expectedLiteral = "ORDER" },
        .{ .expectedType = .by, .expectedLiteral = "BY" },
        .{ .expectedType = .asc, .expectedLiteral = "ASC" },
        .{ .expectedType = .desc, .expectedLiteral = "DESC" },
        .{ .expectedType = .limit, .expectedLiteral = "LIMIT" },
        .{ .expectedType = .offset, .expectedLiteral = "OFFSET" },
        .{ .expectedType = .drop, .expectedLiteral = "DROP" },
        .{ .expectedType = .@"if", .expectedLiteral = "IF" },
        .{ .expectedType = .exists, .expectedLiteral = "EXISTS" },
        .{ .expectedType = .eof, .expectedLiteral = "" },
    };

    var l = Lexer.init(input);

    for (tests) |tt| {
        const tok = l.next_token();

        try std.testing.expectEqual(tt.expectedType, tok.type);
        try std.testing.expectEqualStrings(tt.expectedLiteral, tok.literal);
    }
}

test "Lexer - identifiers and literals" {
    const input =
        \\users id name 123 123.45 'hello world' 'it''s me'
    ;

    const tests = [_]struct {
        expectedType: token.TokenType,
        expectedLiteral: []const u8,
    }{
        .{ .expectedType = .ident, .expectedLiteral = "users" },
        .{ .expectedType = .ident, .expectedLiteral = "id" },
        .{ .expectedType = .ident, .expectedLiteral = "name" },
        .{ .expectedType = .int, .expectedLiteral = "123" },
        .{ .expectedType = .float, .expectedLiteral = "123.45" },
        .{ .expectedType = .string, .expectedLiteral = "hello world" },
        .{ .expectedType = .string, .expectedLiteral = "it''s me" },
        .{ .expectedType = .eof, .expectedLiteral = "" },
    };

    var l = Lexer.init(input);

    for (tests) |tt| {
        const tok = l.next_token();

        try std.testing.expectEqual(tt.expectedType, tok.type);
        try std.testing.expectEqualStrings(tt.expectedLiteral, tok.literal);
    }
}

test "Lexer - complex SQL" {
    const input = "SELECT * FROM users WHERE id = 1;";

    const tests = [_]struct {
        expectedType: token.TokenType,
        expectedLiteral: []const u8,
    }{
        .{ .expectedType = .select, .expectedLiteral = "SELECT" },
        .{ .expectedType = .asterisk, .expectedLiteral = "*" },
        .{ .expectedType = .from, .expectedLiteral = "FROM" },
        .{ .expectedType = .ident, .expectedLiteral = "users" },
        .{ .expectedType = .where, .expectedLiteral = "WHERE" },
        .{ .expectedType = .ident, .expectedLiteral = "id" },
        .{ .expectedType = .eq, .expectedLiteral = "=" },
        .{ .expectedType = .int, .expectedLiteral = "1" },
        .{ .expectedType = .semicolon, .expectedLiteral = ";" },
        .{ .expectedType = .eof, .expectedLiteral = "" },
    };

    var l = Lexer.init(input);

    for (tests) |tt| {
        const tok = l.next_token();
        try std.testing.expectEqual(tt.expectedType, tok.type);
        try std.testing.expectEqualStrings(tt.expectedLiteral, tok.literal);
    }
}
