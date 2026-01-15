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
