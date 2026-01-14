const std = @import("std");

pub const TokenType = enum {
    // Special tokens
    illegal,
    eof,
    ws, // whitespace (skipped)

    // Literals
    ident, // column_name, table_name
    int, // 123
    float, // 123.45
    string, // 'hello'

    // Operators
    eq, // =
    neq, // != or <>
    lt, // <
    gt, // >
    lte, // <=
    gte, // >=
    plus, // +
    minus, // -
    asterisk, // *
    slash, // /

    // Delimiters
    comma, // ,
    semicolon, // ;
    lparen, // (
    rparen, // )
    dot, // .

    // Keywords
    select,
    from,
    where,
    insert,
    into,
    values,
    create,
    table,
    delete,
    update,
    set,
    @"and",
    @"or",
    not,
    null,
    primary,
    key,
    integer,
    text,
    real,
    blob,
    boolean,
    true,
    false,
    date,
    time,
    datetime,
    order,
    by,
    asc,
    desc,
    limit,
    offset,
    drop,
    @"if",
    exists,
    index,
    unique,
    on,
    begin,
    commit,
    rollback,
    transaction,

    pub fn toString(self: TokenType) []const u8 {
        return switch (self) {
            .illegal => "ILLEGAL",
            .eof => "EOF",
            .ws => "WS",
            .ident => "IDENT",
            .int => "INT",
            .float => "FLOAT",
            .string => "STRING",
            .eq => "=",
            .neq => "!=",
            .lt => "<",
            .gt => ">",
            .lte => "<=",
            .gte => ">=",
            .plus => "+",
            .minus => "-",
            .asterisk => "*",
            .slash => "/",
            .comma => ",",
            .semicolon => ";",
            .lparen => "(",
            .rparen => ")",
            .dot => ".",
            .select => "SELECT",
            .from => "FROM",
            .where => "WHERE",
            .insert => "INSERT",
            .into => "INTO",
            .values => "VALUES",
            .create => "CREATE",
            .table => "TABLE",
            .delete => "DELETE",
            .update => "UPDATE",
            .set => "SET",
            .@"and" => "AND",
            .@"or" => "OR",
            .not => "NOT",
            .null => "NULL",
            .primary => "PRIMARY",
            .key => "KEY",
            .integer => "INTEGER",
            .text => "TEXT",
            .real => "REAL",
            .blob => "BLOB",
            .boolean => "BOOLEAN",
            .true => "TRUE",
            .false => "FALSE",
            .date => "DATE",
            .time => "TIME",
            .datetime => "DATETIME",
            .order => "ORDER",
            .by => "BY",
            .asc => "ASC",
            .desc => "DESC",
            .limit => "LIMIT",
            .offset => "OFFSET",
            .drop => "DROP",
            .@"if" => "IF",
            .exists => "EXISTS",
            .index => "INDEX",
            .unique => "UNIQUE",
            .on => "ON",
            .begin => "BEGIN",
            .commit => "COMMIT",
            .rollback => "ROLLBACK",
            .transaction => "TRANSACTION",
        };
    }
};

pub const Token = struct {
    type: TokenType,
    literal: []const u8,
    line: usize,
    column: usize,
};

const keywords = std.StaticStringMap(TokenType).initComptime(.{
    .{ "SELECT", .select },
    .{ "FROM", .from },
    .{ "WHERE", .where },
    .{ "INSERT", .insert },
    .{ "INTO", .into },
    .{ "VALUES", .values },
    .{ "CREATE", .create },
    .{ "TABLE", .table },
    .{ "DELETE", .delete },
    .{ "UPDATE", .update },
    .{ "SET", .set },
    .{ "AND", .@"and" },
    .{ "OR", .@"or" },
    .{ "NOT", .not },
    .{ "NULL", .null },
    .{ "PRIMARY", .primary },
    .{ "KEY", .key },
    .{ "INTEGER", .integer },
    .{ "TEXT", .text },
    .{ "REAL", .real },
    .{ "BLOB", .blob },
    .{ "BOOLEAN", .boolean },
    .{ "TRUE", .true },
    .{ "FALSE", .false },
    .{ "DATE", .date },
    .{ "TIME", .time },
    .{ "DATETIME", .datetime },
    .{ "ORDER", .order },
    .{ "BY", .by },
    .{ "ASC", .asc },
    .{ "DESC", .desc },
    .{ "LIMIT", .limit },
    .{ "OFFSET", .offset },
    .{ "DROP", .drop },
    .{ "IF", .@"if" },
    .{ "EXISTS", .exists },
    .{ "INDEX", .index },
    .{ "UNIQUE", .unique },
    .{ "ON", .on },
    .{ "BEGIN", .begin },
    .{ "COMMIT", .commit },
    .{ "ROLLBACK", .rollback },
    .{ "TRANSACTION", .transaction },
});

pub fn lookup_ident(ident: []const u8) TokenType {
    var upper_buf: [64]u8 = undefined;
    const len = @min(ident.len, upper_buf.len);
    const upper = std.ascii.upperString(upper_buf[0..len], ident[0..len]);

    return keywords.get(upper) orelse .ident;
}

test "lookup_ident" {
    try std.testing.expect(lookup_ident("select") == .select);
    try std.testing.expect(lookup_ident("FROM") == .from);
    try std.testing.expect(lookup_ident("Where") == .where);
    try std.testing.expect(lookup_ident("my_column") == .ident);
    try std.testing.expect(lookup_ident("TableName") == .ident);
}
