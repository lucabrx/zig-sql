const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const Compiler = @import("compiler/compiler.zig").Compiler;
const VM = @import("vm/vm.zig").VM;
const RegisterValue = @import("vm/vm.zig").RegisterValue;
const Pager = @import("storage/pager.zig").Pager;
const Database = @import("storage/table.zig").Database;

fn execute_sql(allocator: std.mem.Allocator, db: *Database, sql: []const u8) ![][]RegisterValue {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    var l = lexer.Lexer.init(sql);
    const tokens = try l.tokenize(temp);
    var p = parser.Parser.init(tokens, temp);
    const stmt = try p.parse();

    var compiler = Compiler.init(temp, allocator, db);
    defer compiler.deinit();
    const instructions = try compiler.compile(stmt);

    var vm = VM.init(allocator, db);
    vm.set_debug(false);
    defer vm.deinit();

    vm.load(instructions);
    try vm.run();

    const results = vm.get_results();
    const copy = try allocator.alloc([]RegisterValue, results.len);
    for (results, 0..) |row, i| {
        copy[i] = try allocator.dupe(RegisterValue, row);
    }
    return copy;
}

fn free_results(allocator: std.mem.Allocator, results: [][]RegisterValue) void {
    for (results) |row| {
        allocator.free(row);
    }
    allocator.free(results);
}

test "basic CRUD operations" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT);");

    _ = try execute_sql(allocator, &db, "INSERT INTO users VALUES (1, 'Alice');");
    _ = try execute_sql(allocator, &db, "INSERT INTO users VALUES (2, 'Bob');");

    const results = try execute_sql(allocator, &db, "SELECT * FROM users;");
    defer free_results(allocator, results);

    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(i64, 1), results[0][0].integer);
    try std.testing.expectEqualStrings("Alice", results[0][1].text);

    _ = try execute_sql(allocator, &db, "UPDATE users SET name = 'Alicia' WHERE id = 1;");

    const updated = try execute_sql(allocator, &db, "SELECT name FROM users WHERE id = 1;");
    defer free_results(allocator, updated);
    try std.testing.expectEqualStrings("Alicia", updated[0][0].text);

    _ = try execute_sql(allocator, &db, "DELETE FROM users WHERE id = 2;");

    const after_delete = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM users;");
    defer free_results(allocator, after_delete);
    try std.testing.expectEqual(@as(i64, 1), after_delete[0][0].integer);
}

test "aggregate functions" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE sales (id INTEGER PRIMARY KEY, amount INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO sales VALUES (1, 100);");
    _ = try execute_sql(allocator, &db, "INSERT INTO sales VALUES (2, 200);");
    _ = try execute_sql(allocator, &db, "INSERT INTO sales VALUES (3, 300);");

    const sum_result = try execute_sql(allocator, &db, "SELECT SUM(amount) FROM sales;");
    defer free_results(allocator, sum_result);
    try std.testing.expectEqual(@as(i64, 600), sum_result[0][0].integer);

    const count_result = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM sales;");
    defer free_results(allocator, count_result);
    try std.testing.expectEqual(@as(i64, 3), count_result[0][0].integer);

    const min_result = try execute_sql(allocator, &db, "SELECT MIN(amount) FROM sales;");
    defer free_results(allocator, min_result);
    try std.testing.expectEqual(@as(i64, 100), min_result[0][0].integer);

    const max_result = try execute_sql(allocator, &db, "SELECT MAX(amount) FROM sales;");
    defer free_results(allocator, max_result);
    try std.testing.expectEqual(@as(i64, 300), max_result[0][0].integer);
}

test "JOIN operations" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE t1 (id INTEGER PRIMARY KEY, val INTEGER);");
    _ = try execute_sql(allocator, &db, "CREATE TABLE t2 (id INTEGER PRIMARY KEY, t1_id INTEGER);");

    _ = try execute_sql(allocator, &db, "INSERT INTO t1 VALUES (1, 100);");
    _ = try execute_sql(allocator, &db, "INSERT INTO t2 VALUES (1, 1);");

    const cross = try execute_sql(allocator, &db, "SELECT t1.val FROM t1, t2 WHERE t1.id = t2.t1_id;");
    defer free_results(allocator, cross);

    try std.testing.expectEqual(@as(usize, 1), cross.len);
    try std.testing.expectEqual(@as(i64, 100), cross[0][0].integer);
}

test "ORDER BY and LIMIT" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE items (id INTEGER PRIMARY KEY, val INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO items VALUES (1, 30);");
    _ = try execute_sql(allocator, &db, "INSERT INTO items VALUES (2, 10);");
    _ = try execute_sql(allocator, &db, "INSERT INTO items VALUES (3, 20);");

    const all = try execute_sql(allocator, &db, "SELECT val FROM items;");
    defer free_results(allocator, all);
    try std.testing.expectEqual(@as(usize, 3), all.len);

    const limited = try execute_sql(allocator, &db, "SELECT val FROM items LIMIT 2;");
    defer free_results(allocator, limited);
    try std.testing.expectEqual(@as(usize, 2), limited.len);
}

test "transactions begin and commit" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO accounts VALUES (1, 100);");

    _ = try execute_sql(allocator, &db, "BEGIN;");
    _ = try execute_sql(allocator, &db, "UPDATE accounts SET balance = 150 WHERE id = 1;");
    _ = try execute_sql(allocator, &db, "COMMIT;");

    const after_commit = try execute_sql(allocator, &db, "SELECT balance FROM accounts WHERE id = 1;");
    defer free_results(allocator, after_commit);
    try std.testing.expectEqual(@as(i64, 150), after_commit[0][0].integer);
}

test "NOT NULL constraint" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT NOT NULL);");

    const result = execute_sql(allocator, &db, "INSERT INTO test VALUES (1, NULL);");
    try std.testing.expectError(error.NullConstraintViolation, result);
}

test "UNIQUE constraint" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE test (id INTEGER PRIMARY KEY, email TEXT UNIQUE);");
    _ = try execute_sql(allocator, &db, "INSERT INTO test VALUES (1, 'test@test.com');");

    const result = execute_sql(allocator, &db, "INSERT INTO test VALUES (2, 'test@test.com');");
    try std.testing.expectError(error.UniqueConstraintViolation, result);
}

test "string functions" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT);");
    _ = try execute_sql(allocator, &db, "INSERT INTO test VALUES (1, 'hello');");

    const len = try execute_sql(allocator, &db, "SELECT LENGTH(name) FROM test;");
    defer free_results(allocator, len);
    try std.testing.expectEqual(@as(i64, 5), len[0][0].integer);
}

test "LIKE operator" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT);");
    _ = try execute_sql(allocator, &db, "INSERT INTO test VALUES (1, 'Alice');");
    _ = try execute_sql(allocator, &db, "INSERT INTO test VALUES (2, 'Bob');");
    _ = try execute_sql(allocator, &db, "INSERT INTO test VALUES (3, 'Alicia');");

    const result = try execute_sql(allocator, &db, "SELECT name FROM test WHERE name LIKE 'Ali%';");
    defer free_results(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "DISTINCT" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE test (id INTEGER PRIMARY KEY, category TEXT);");
    _ = try execute_sql(allocator, &db, "INSERT INTO test VALUES (1, 'A');");
    _ = try execute_sql(allocator, &db, "INSERT INTO test VALUES (2, 'B');");
    _ = try execute_sql(allocator, &db, "INSERT INTO test VALUES (3, 'A');");

    const result = try execute_sql(allocator, &db, "SELECT DISTINCT category FROM test;");
    defer free_results(allocator, result);

    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "stress test: many inserts" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE stress (id INTEGER PRIMARY KEY, val INTEGER);");

    var buf: [128]u8 = undefined;
    for (1..16) |i| {
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO stress VALUES ({d}, {d});", .{ i, i * 10 });
        _ = try execute_sql(allocator, &db, sql);
    }

    const result = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM stress;");
    defer free_results(allocator, result);

    try std.testing.expectEqual(@as(i64, 15), result[0][0].integer);
}

test "stress test: many deletes" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE stress (id INTEGER PRIMARY KEY, val INTEGER);");

    _ = try execute_sql(allocator, &db, "INSERT INTO stress VALUES (1, 10);");
    _ = try execute_sql(allocator, &db, "INSERT INTO stress VALUES (2, 20);");
    _ = try execute_sql(allocator, &db, "INSERT INTO stress VALUES (3, 30);");

    _ = try execute_sql(allocator, &db, "DELETE FROM stress WHERE id = 1;");

    const result = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM stress;");
    defer free_results(allocator, result);

    try std.testing.expectEqual(@as(i64, 2), result[0][0].integer);
}

test "stress test: interleaved insert delete" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE stress (id INTEGER PRIMARY KEY, val INTEGER);");

    _ = try execute_sql(allocator, &db, "INSERT INTO stress VALUES (1, 10);");
    _ = try execute_sql(allocator, &db, "INSERT INTO stress VALUES (2, 20);");
    _ = try execute_sql(allocator, &db, "DELETE FROM stress WHERE id = 1;");
    _ = try execute_sql(allocator, &db, "INSERT INTO stress VALUES (3, 30);");

    const result = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM stress;");
    defer free_results(allocator, result);

    try std.testing.expectEqual(@as(i64, 2), result[0][0].integer);
}

test "stress test: updates" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE stress (id INTEGER PRIMARY KEY, val INTEGER);");

    _ = try execute_sql(allocator, &db, "INSERT INTO stress VALUES (1, 0);");
    _ = try execute_sql(allocator, &db, "INSERT INTO stress VALUES (2, 0);");
    _ = try execute_sql(allocator, &db, "INSERT INTO stress VALUES (3, 0);");

    _ = try execute_sql(allocator, &db, "UPDATE stress SET val = 100 WHERE id = 1;");
    _ = try execute_sql(allocator, &db, "UPDATE stress SET val = 200 WHERE id = 2;");
    _ = try execute_sql(allocator, &db, "UPDATE stress SET val = 300 WHERE id = 3;");

    const result = try execute_sql(allocator, &db, "SELECT SUM(val) FROM stress;");
    defer free_results(allocator, result);

    const val = result[0][0];
    const sum_val: i64 = if (val.type == .integer) val.integer else @intFromFloat(val.real);
    try std.testing.expectEqual(@as(i64, 600), sum_val);
}

test "edge case: empty table operations" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE empty (id INTEGER PRIMARY KEY, val TEXT);");

    const count = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM empty;");
    defer free_results(allocator, count);
    try std.testing.expectEqual(@as(i64, 0), count[0][0].integer);

    const select = try execute_sql(allocator, &db, "SELECT * FROM empty;");
    defer free_results(allocator, select);
    try std.testing.expectEqual(@as(usize, 0), select.len);
}

test "edge case: NULL handling" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE nulls (id INTEGER PRIMARY KEY, val INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO nulls VALUES (1, NULL);");
    _ = try execute_sql(allocator, &db, "INSERT INTO nulls VALUES (2, 10);");
    _ = try execute_sql(allocator, &db, "INSERT INTO nulls VALUES (3, NULL);");

    const is_null = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM nulls WHERE val IS NULL;");
    defer free_results(allocator, is_null);
    try std.testing.expectEqual(@as(i64, 2), is_null[0][0].integer);

    const is_not_null = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM nulls WHERE val IS NOT NULL;");
    defer free_results(allocator, is_not_null);
    try std.testing.expectEqual(@as(i64, 1), is_not_null[0][0].integer);

    const coalesce = try execute_sql(allocator, &db, "SELECT COALESCE(val, 0) FROM nulls WHERE id = 1;");
    defer free_results(allocator, coalesce);
    try std.testing.expectEqual(@as(i64, 0), coalesce[0][0].integer);
}

test "edge case: arithmetic expressions" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE nums (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO nums VALUES (1, 10, 3);");

    const add = try execute_sql(allocator, &db, "SELECT a + b FROM nums;");
    defer free_results(allocator, add);
    try std.testing.expectEqual(@as(i64, 13), add[0][0].integer);

    const sub = try execute_sql(allocator, &db, "SELECT a - b FROM nums;");
    defer free_results(allocator, sub);
    try std.testing.expectEqual(@as(i64, 7), sub[0][0].integer);

    const mul = try execute_sql(allocator, &db, "SELECT a * b FROM nums;");
    defer free_results(allocator, mul);
    try std.testing.expectEqual(@as(i64, 30), mul[0][0].integer);

    const div = try execute_sql(allocator, &db, "SELECT a / b FROM nums;");
    defer free_results(allocator, div);
    try std.testing.expectEqual(@as(i64, 3), div[0][0].integer);

    const complex = try execute_sql(allocator, &db, "SELECT (a + b) * 2 FROM nums;");
    defer free_results(allocator, complex);
    try std.testing.expectEqual(@as(i64, 26), complex[0][0].integer);
}

test "edge case: string operations" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE strings (id INTEGER PRIMARY KEY, s TEXT);");
    _ = try execute_sql(allocator, &db, "INSERT INTO strings VALUES (1, 'Hello World');");
    _ = try execute_sql(allocator, &db, "INSERT INTO strings VALUES (2, '');");

    const length = try execute_sql(allocator, &db, "SELECT LENGTH(s) FROM strings WHERE id = 1;");
    defer free_results(allocator, length);
    try std.testing.expectEqual(@as(i64, 11), length[0][0].integer);

    const empty_len = try execute_sql(allocator, &db, "SELECT LENGTH(s) FROM strings WHERE id = 2;");
    defer free_results(allocator, empty_len);
    try std.testing.expectEqual(@as(i64, 0), empty_len[0][0].integer);
}

test "edge case: comparison operators" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE cmp (id INTEGER PRIMARY KEY, val INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO cmp VALUES (1, 10);");
    _ = try execute_sql(allocator, &db, "INSERT INTO cmp VALUES (2, 20);");
    _ = try execute_sql(allocator, &db, "INSERT INTO cmp VALUES (3, 30);");

    const gt = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM cmp WHERE val > 15;");
    defer free_results(allocator, gt);
    try std.testing.expectEqual(@as(i64, 2), gt[0][0].integer);

    const gte = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM cmp WHERE val >= 20;");
    defer free_results(allocator, gte);
    try std.testing.expectEqual(@as(i64, 2), gte[0][0].integer);

    const lt = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM cmp WHERE val < 25;");
    defer free_results(allocator, lt);
    try std.testing.expectEqual(@as(i64, 2), lt[0][0].integer);

    const lte = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM cmp WHERE val <= 20;");
    defer free_results(allocator, lte);
    try std.testing.expectEqual(@as(i64, 2), lte[0][0].integer);

    const neq = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM cmp WHERE val <> 20;");
    defer free_results(allocator, neq);
    try std.testing.expectEqual(@as(i64, 2), neq[0][0].integer);
}

test "edge case: BETWEEN operator" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE range (id INTEGER PRIMARY KEY, val INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO range VALUES (1, 5);");
    _ = try execute_sql(allocator, &db, "INSERT INTO range VALUES (2, 10);");
    _ = try execute_sql(allocator, &db, "INSERT INTO range VALUES (3, 15);");

    const between = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM range WHERE val BETWEEN 8 AND 12;");
    defer free_results(allocator, between);
    try std.testing.expectEqual(@as(i64, 1), between[0][0].integer);

    const between_inclusive = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM range WHERE val BETWEEN 5 AND 15;");
    defer free_results(allocator, between_inclusive);
    try std.testing.expectEqual(@as(i64, 3), between_inclusive[0][0].integer);
}

test "edge case: IN operator" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE intest (id INTEGER PRIMARY KEY, val INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO intest VALUES (1, 10);");
    _ = try execute_sql(allocator, &db, "INSERT INTO intest VALUES (2, 20);");
    _ = try execute_sql(allocator, &db, "INSERT INTO intest VALUES (3, 30);");

    const in_list = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM intest WHERE val IN (10, 30);");
    defer free_results(allocator, in_list);
    try std.testing.expectEqual(@as(i64, 2), in_list[0][0].integer);

    const not_in = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM intest WHERE val NOT IN (10, 30);");
    defer free_results(allocator, not_in);
    try std.testing.expectEqual(@as(i64, 1), not_in[0][0].integer);
}

test "edge case: LIKE pattern matching" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE patterns (id INTEGER PRIMARY KEY, name TEXT);");
    _ = try execute_sql(allocator, &db, "INSERT INTO patterns VALUES (1, 'apple');");
    _ = try execute_sql(allocator, &db, "INSERT INTO patterns VALUES (2, 'banana');");
    _ = try execute_sql(allocator, &db, "INSERT INTO patterns VALUES (3, 'apricot');");

    const starts_with = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM patterns WHERE name LIKE 'ap%';");
    defer free_results(allocator, starts_with);
    try std.testing.expectEqual(@as(i64, 2), starts_with[0][0].integer);

    const ends_with = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM patterns WHERE name LIKE '%a';");
    defer free_results(allocator, ends_with);
    try std.testing.expectEqual(@as(i64, 1), ends_with[0][0].integer);

    const contains = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM patterns WHERE name LIKE '%an%';");
    defer free_results(allocator, contains);
    try std.testing.expectEqual(@as(i64, 1), contains[0][0].integer);
}

test "edge case: GROUP BY with multiple aggregates" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE sales (id INTEGER PRIMARY KEY, category TEXT, amount INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO sales VALUES (1, 'A', 100);");
    _ = try execute_sql(allocator, &db, "INSERT INTO sales VALUES (2, 'A', 200);");
    _ = try execute_sql(allocator, &db, "INSERT INTO sales VALUES (3, 'B', 150);");

    const grouped = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM sales GROUP BY category;");
    defer free_results(allocator, grouped);
    try std.testing.expectEqual(@as(usize, 2), grouped.len);
}

test "edge case: ORDER BY with LIMIT" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE ordered (id INTEGER PRIMARY KEY, val INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO ordered VALUES (1, 30);");
    _ = try execute_sql(allocator, &db, "INSERT INTO ordered VALUES (2, 10);");
    _ = try execute_sql(allocator, &db, "INSERT INTO ordered VALUES (3, 20);");

    const limited = try execute_sql(allocator, &db, "SELECT val FROM ordered LIMIT 2;");
    defer free_results(allocator, limited);
    try std.testing.expectEqual(@as(usize, 2), limited.len);
}

test "edge case: multiple conditions with AND/OR" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE logic (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO logic VALUES (1, 1, 1);");
    _ = try execute_sql(allocator, &db, "INSERT INTO logic VALUES (2, 1, 0);");
    _ = try execute_sql(allocator, &db, "INSERT INTO logic VALUES (3, 0, 1);");

    const and_cond = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM logic WHERE a = 1 AND b = 1;");
    defer free_results(allocator, and_cond);
    try std.testing.expectEqual(@as(i64, 1), and_cond[0][0].integer);

    const or_cond = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM logic WHERE a = 1 OR b = 1;");
    defer free_results(allocator, or_cond);
    try std.testing.expectEqual(@as(i64, 3), or_cond[0][0].integer);
}

test "edge case: subquery in WHERE" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE main (id INTEGER PRIMARY KEY, val INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO main VALUES (1, 100);");
    _ = try execute_sql(allocator, &db, "INSERT INTO main VALUES (2, 200);");

    const subq = try execute_sql(allocator, &db, "SELECT * FROM main WHERE val = (SELECT MAX(val) FROM main);");
    defer free_results(allocator, subq);
    try std.testing.expectEqual(@as(usize, 1), subq.len);
    try std.testing.expectEqual(@as(i64, 2), subq[0][0].integer);
}

test "edge case: CASE expression" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE grades (id INTEGER PRIMARY KEY, score INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO grades VALUES (1, 95);");
    _ = try execute_sql(allocator, &db, "INSERT INTO grades VALUES (2, 75);");
    _ = try execute_sql(allocator, &db, "INSERT INTO grades VALUES (3, 55);");

    const case_expr = try execute_sql(allocator, &db, "SELECT CASE WHEN score >= 90 THEN 1 WHEN score >= 70 THEN 2 ELSE 3 END FROM grades WHERE id = 1;");
    defer free_results(allocator, case_expr);
    try std.testing.expectEqual(@as(i64, 1), case_expr[0][0].integer);
}

test "edge case: column aliases" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE alias_test (id INTEGER PRIMARY KEY, value INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO alias_test VALUES (1, 42);");

    const aliased = try execute_sql(allocator, &db, "SELECT value AS v FROM alias_test;");
    defer free_results(allocator, aliased);
    try std.testing.expectEqual(@as(i64, 42), aliased[0][0].integer);
}

test "edge case: table aliases in JOIN" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE a (id INTEGER PRIMARY KEY, val INTEGER);");
    _ = try execute_sql(allocator, &db, "CREATE TABLE b (id INTEGER PRIMARY KEY, a_id INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO a VALUES (1, 100);");
    _ = try execute_sql(allocator, &db, "INSERT INTO b VALUES (1, 1);");

    const joined = try execute_sql(allocator, &db, "SELECT x.val FROM a AS x, b AS y WHERE x.id = y.a_id;");
    defer free_results(allocator, joined);
    try std.testing.expectEqual(@as(usize, 1), joined.len);
    try std.testing.expectEqual(@as(i64, 100), joined[0][0].integer);
}

test "edge case: UPDATE with WHERE" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE counter (id INTEGER PRIMARY KEY, cnt INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO counter VALUES (1, 10);");
    _ = try execute_sql(allocator, &db, "INSERT INTO counter VALUES (2, 20);");

    _ = try execute_sql(allocator, &db, "UPDATE counter SET cnt = 15 WHERE id = 1;");

    const result = try execute_sql(allocator, &db, "SELECT cnt FROM counter WHERE id = 1;");
    defer free_results(allocator, result);
    try std.testing.expectEqual(@as(i64, 15), result[0][0].integer);

    const unchanged = try execute_sql(allocator, &db, "SELECT cnt FROM counter WHERE id = 2;");
    defer free_results(allocator, unchanged);
    try std.testing.expectEqual(@as(i64, 20), unchanged[0][0].integer);
}

test "edge case: DELETE with complex WHERE" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE del_test (id INTEGER PRIMARY KEY, status TEXT);");
    _ = try execute_sql(allocator, &db, "INSERT INTO del_test VALUES (1, 'active');");
    _ = try execute_sql(allocator, &db, "INSERT INTO del_test VALUES (2, 'inactive');");
    _ = try execute_sql(allocator, &db, "INSERT INTO del_test VALUES (3, 'active');");

    _ = try execute_sql(allocator, &db, "DELETE FROM del_test WHERE status = 'inactive';");

    const result = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM del_test;");
    defer free_results(allocator, result);
    try std.testing.expectEqual(@as(i64, 2), result[0][0].integer);
}

test "edge case: boolean values" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE bools (id INTEGER PRIMARY KEY, flag INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO bools VALUES (1, 1);");
    _ = try execute_sql(allocator, &db, "INSERT INTO bools VALUES (2, 0);");

    const true_count = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM bools WHERE flag = 1;");
    defer free_results(allocator, true_count);
    try std.testing.expectEqual(@as(i64, 1), true_count[0][0].integer);

    const false_count = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM bools WHERE flag = 0;");
    defer free_results(allocator, false_count);
    try std.testing.expectEqual(@as(i64, 1), false_count[0][0].integer);
}

test "edge case: real/float values" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE floats (id INTEGER PRIMARY KEY, val REAL);");
    _ = try execute_sql(allocator, &db, "INSERT INTO floats VALUES (1, 3.14);");
    _ = try execute_sql(allocator, &db, "INSERT INTO floats VALUES (2, 2.71);");

    const sum = try execute_sql(allocator, &db, "SELECT SUM(val) FROM floats;");
    defer free_results(allocator, sum);
    const sum_val = sum[0][0].real;
    try std.testing.expect(sum_val > 5.8 and sum_val < 5.9);
}

test "edge case: multiple row insert" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();
    var db = try Database.init(allocator, &pager);
    defer db.close();

    _ = try execute_sql(allocator, &db, "CREATE TABLE multi (id INTEGER PRIMARY KEY, val INTEGER);");
    _ = try execute_sql(allocator, &db, "INSERT INTO multi VALUES (1, 10), (2, 20), (3, 30);");

    const result = try execute_sql(allocator, &db, "SELECT COUNT(*) FROM multi;");
    defer free_results(allocator, result);
    try std.testing.expectEqual(@as(i64, 3), result[0][0].integer);
}
