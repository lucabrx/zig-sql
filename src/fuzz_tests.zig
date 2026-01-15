const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");

fn fuzz_parser(input: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var l = lexer.Lexer.init(input);
    const tokens = l.tokenize(allocator) catch return;

    var p = parser.Parser.init(tokens, allocator);
    defer p.deinit();

    _ = p.parse() catch return;
    _ = p.parseMultiple() catch return;
}

pub fn main() !void {
    const args = try std.process.argsAlloc(std.heap.page_allocator);
    defer std.process.argsFree(std.heap.page_allocator, args);

    if (args.len > 1) {
        const file = try std.fs.cwd().openFile(args[1], .{});
        defer file.close();
        const input = try file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024);
        defer std.heap.page_allocator.free(input);
        fuzz_parser(input);
    }
}

test "fuzz: empty input" {
    fuzz_parser("");
}

test "fuzz: single characters" {
    const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;':\",./<>?`~\\\n\t\r ";
    for (chars) |c| {
        fuzz_parser(&[_]u8{c});
    }
}

test "fuzz: sql keywords alone" {
    const keywords = [_][]const u8{
        "SELECT",   "FROM",       "WHERE",  "INSERT",  "INTO",     "VALUES",  "UPDATE", "SET",
        "DELETE",   "CREATE",     "TABLE",  "DROP",    "ALTER",    "INDEX",   "VIEW",   "BEGIN",
        "COMMIT",   "ROLLBACK",   "AND",    "OR",      "NOT",      "NULL",    "TRUE",   "FALSE",
        "INTEGER",  "TEXT",       "REAL",   "BLOB",    "BOOLEAN",  "PRIMARY", "KEY",    "UNIQUE",
        "FOREIGN",  "REFERENCES", "CHECK",  "DEFAULT", "AS",       "ON",      "JOIN",   "LEFT",
        "RIGHT",    "INNER",      "OUTER",  "CROSS",   "NATURAL",  "USING",   "GROUP",  "BY",
        "HAVING",   "ORDER",      "ASC",    "DESC",    "LIMIT",    "OFFSET",  "UNION",  "ALL",
        "DISTINCT", "CASE",       "WHEN",   "THEN",    "ELSE",     "END",     "IN",     "BETWEEN",
        "LIKE",     "IS",         "EXISTS", "CAST",    "COALESCE", "NULLIF",  "IFNULL",
    };
    for (keywords) |kw| {
        fuzz_parser(kw);
    }
}

test "fuzz: malformed statements" {
    const malformed = [_][]const u8{
        "SELECT",
        "SELECT *",
        "SELECT * FROM",
        "SELECT FROM table",
        "INSERT INTO",
        "INSERT INTO table",
        "INSERT INTO table VALUES",
        "INSERT INTO table VALUES (",
        "INSERT INTO table VALUES (1",
        "UPDATE",
        "UPDATE table",
        "UPDATE table SET",
        "DELETE",
        "DELETE FROM",
        "CREATE",
        "CREATE TABLE",
        "CREATE TABLE t",
        "CREATE TABLE t (",
        "DROP",
        "DROP TABLE",
        "BEGIN",
        "COMMIT",
        "ROLLBACK",
        "SELECT * FROM t WHERE",
        "SELECT * FROM t WHERE x =",
        "SELECT * FROM t ORDER",
        "SELECT * FROM t ORDER BY",
        "SELECT * FROM t GROUP",
        "SELECT * FROM t GROUP BY",
        "SELECT * FROM t LIMIT",
        "SELECT * FROM t OFFSET",
    };
    for (malformed) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: special characters in strings" {
    const special = [_][]const u8{
        "SELECT '\\'",
        "SELECT '\\n'",
        "SELECT '\\t'",
        "SELECT '\\r'",
        "SELECT '\\0'",
        "SELECT '''",
        "SELECT ''''",
        "SELECT '\"'",
        "SELECT \"'\"",
        "SELECT \"\"\"",
        "SELECT '",
        "SELECT \"",
        "INSERT INTO t VALUES ('test\\'s')",
        "INSERT INTO t VALUES (\"test\\\"s\")",
    };
    for (special) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: numeric edge cases" {
    const numbers = [_][]const u8{
        "SELECT 0",
        "SELECT -0",
        "SELECT 1",
        "SELECT -1",
        "SELECT 9223372036854775807",
        "SELECT -9223372036854775808",
        "SELECT 9999999999999999999999999999",
        "SELECT 0.0",
        "SELECT -0.0",
        "SELECT 1.0",
        "SELECT -1.0",
        "SELECT 1e10",
        "SELECT 1e-10",
        "SELECT 1.5e10",
        "SELECT .5",
        "SELECT 5.",
        "SELECT 1e",
        "SELECT 1e+",
        "SELECT 1e-",
        "SELECT 0x10",
        "SELECT 0b10",
        "SELECT 0o10",
    };
    for (numbers) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: deeply nested expressions" {
    fuzz_parser("SELECT ((((((((((1))))))))))");
    fuzz_parser("SELECT 1 + (2 + (3 + (4 + (5 + (6 + (7 + (8 + (9 + 10))))))))");
    fuzz_parser("SELECT NOT NOT NOT NOT NOT NOT NOT NOT NOT NOT TRUE");
    fuzz_parser("SELECT 1 AND 2 AND 3 AND 4 AND 5 AND 6 AND 7 AND 8 AND 9 AND 10");
    fuzz_parser("SELECT 1 OR 2 OR 3 OR 4 OR 5 OR 6 OR 7 OR 8 OR 9 OR 10");
}

test "fuzz: long identifiers" {
    var buf: [1024]u8 = undefined;
    const long_ident = "a" ** 256;
    const sql = std.fmt.bufPrint(&buf, "SELECT {s} FROM {s}", .{ long_ident, long_ident }) catch return;
    fuzz_parser(sql);
}

test "fuzz: many columns" {
    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const writer = stream.writer();
    writer.writeAll("SELECT ") catch return;
    for (0..100) |i| {
        if (i > 0) writer.writeAll(", ") catch return;
        writer.print("col{d}", .{i}) catch return;
    }
    writer.writeAll(" FROM t") catch return;
    fuzz_parser(stream.getWritten());
}

test "fuzz: unicode and binary" {
    const unicode = [_][]const u8{
        "SELECT '日本語'",
        "SELECT '中文'",
        "SELECT 'émoji 🎉'",
        "SELECT '\x00'",
        "SELECT '\xff'",
        "SELECT '\x80'",
    };
    for (unicode) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: comment handling" {
    const comments = [_][]const u8{
        "-- comment\nSELECT 1",
        "SELECT 1 -- comment",
        "/* comment */ SELECT 1",
        "SELECT /* comment */ 1",
        "SELECT 1 /* comment */",
        "/* unclosed comment",
        "-- unclosed comment",
        "/**/",
        "/* /* nested */ */",
    };
    for (comments) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: whitespace variations" {
    const whitespace = [_][]const u8{
        "SELECT\t1",
        "SELECT\n1",
        "SELECT\r\n1",
        "SELECT   1",
        "\n\n\nSELECT 1\n\n\n",
        "\t\t\tSELECT 1\t\t\t",
        "SELECT 1;SELECT 2;SELECT 3",
        "SELECT 1;\n\nSELECT 2;\n\nSELECT 3",
    };
    for (whitespace) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: subqueries" {
    const subqueries = [_][]const u8{
        "SELECT (SELECT 1)",
        "SELECT * FROM (SELECT 1)",
        "SELECT * FROM t WHERE x IN (SELECT 1)",
        "SELECT * FROM t WHERE x = (SELECT 1)",
        "SELECT * FROM t WHERE EXISTS (SELECT 1)",
        "SELECT (SELECT (SELECT (SELECT 1)))",
        "SELECT * FROM (SELECT * FROM (SELECT * FROM t))",
    };
    for (subqueries) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: joins" {
    const joins = [_][]const u8{
        "SELECT * FROM t1 JOIN t2",
        "SELECT * FROM t1 JOIN t2 ON t1.id = t2.id",
        "SELECT * FROM t1 LEFT JOIN t2 ON t1.id = t2.id",
        "SELECT * FROM t1 RIGHT JOIN t2 ON t1.id = t2.id",
        "SELECT * FROM t1 INNER JOIN t2 ON t1.id = t2.id",
        "SELECT * FROM t1 CROSS JOIN t2",
        "SELECT * FROM t1, t2, t3, t4, t5",
        "SELECT * FROM t1 JOIN t2 JOIN t3 JOIN t4 JOIN t5",
    };
    for (joins) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: case expressions" {
    const cases = [_][]const u8{
        "SELECT CASE WHEN 1 THEN 2 END",
        "SELECT CASE WHEN 1 THEN 2 ELSE 3 END",
        "SELECT CASE WHEN 1 THEN 2 WHEN 3 THEN 4 END",
        "SELECT CASE WHEN 1 THEN 2 WHEN 3 THEN 4 ELSE 5 END",
        "SELECT CASE x WHEN 1 THEN 2 END",
        "SELECT CASE",
        "SELECT CASE WHEN",
        "SELECT CASE WHEN 1",
        "SELECT CASE WHEN 1 THEN",
    };
    for (cases) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: aggregate functions" {
    const aggregates = [_][]const u8{
        "SELECT COUNT(*) FROM t",
        "SELECT COUNT(x) FROM t",
        "SELECT COUNT(DISTINCT x) FROM t",
        "SELECT SUM(x) FROM t",
        "SELECT AVG(x) FROM t",
        "SELECT MIN(x) FROM t",
        "SELECT MAX(x) FROM t",
        "SELECT COUNT(*), SUM(x), AVG(x), MIN(x), MAX(x) FROM t",
        "SELECT COUNT(",
        "SELECT COUNT()",
        "SELECT SUM()",
    };
    for (aggregates) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: create table variations" {
    const creates = [_][]const u8{
        "CREATE TABLE t (id INTEGER)",
        "CREATE TABLE t (id INTEGER PRIMARY KEY)",
        "CREATE TABLE t (id INTEGER NOT NULL)",
        "CREATE TABLE t (id INTEGER UNIQUE)",
        "CREATE TABLE t (id INTEGER DEFAULT 0)",
        "CREATE TABLE t (id INTEGER CHECK (id > 0))",
        "CREATE TABLE t (id INTEGER, FOREIGN KEY (id) REFERENCES other(id))",
        "CREATE TABLE t (id INTEGER, name TEXT, age INTEGER)",
        "CREATE TABLE IF NOT EXISTS t (id INTEGER)",
        "CREATE TABLE t (",
        "CREATE TABLE t ()",
        "CREATE TABLE t (id)",
        "CREATE TABLE t (id INTEGER,)",
    };
    for (creates) |sql| {
        fuzz_parser(sql);
    }
}

test "fuzz: random byte sequences" {
    const random_seqs = [_][]const u8{
        "\x00\x01\x02\x03",
        "\xff\xfe\xfd\xfc",
        "\x7f\x80\x81\x82",
        "SELECT \x00 FROM t",
        "SELECT * FROM \xff",
    };
    for (random_seqs) |sql| {
        fuzz_parser(sql);
    }
}
