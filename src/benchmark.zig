const std = @import("std");
const lexer = @import("lexer/lexer.zig");
const parser = @import("parser/parser.zig");
const Compiler = @import("compiler/compiler.zig").Compiler;
const VM = @import("vm/vm.zig").VM;
const Pager = @import("storage/pager.zig").Pager;
const Database = @import("storage/table.zig").Database;

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var global_db: ?*Database = null;
var global_pager: ?*Pager = null;

fn execute(sql: []const u8) !void {
    const allocator = gpa.allocator();
    const db = global_db orelse return error.NoDatabase;

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
}

fn runBenchmark(comptime name: []const u8, iterations: usize, comptime func: fn () void) void {
    const start = std.time.nanoTimestamp();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        func();
    }
    const end = std.time.nanoTimestamp();
    const elapsed_ns = end - start;
    const per_op_ns = @divTrunc(elapsed_ns, @as(i128, iterations));
    const per_op_us = @as(f64, @floatFromInt(per_op_ns)) / 1000.0;
    const ops_per_sec = if (per_op_ns > 0) @divTrunc(1_000_000_000, per_op_ns) else 0;
    std.debug.print("{s}: {d:.2} µs/op ({d} ops/sec)\n", .{ name, per_op_us, ops_per_sec });
}

fn benchSelectAll() void {
    execute("SELECT * FROM bench;") catch {};
}

fn benchSelectWhere() void {
    execute("SELECT * FROM bench WHERE id = 25;") catch {};
}

fn benchSelectCount() void {
    execute("SELECT COUNT(*) FROM bench;") catch {};
}

fn benchSelectLimit() void {
    execute("SELECT * FROM bench LIMIT 10;") catch {};
}

fn benchUpdate() void {
    execute("UPDATE bench SET value = 200 WHERE id = 10;") catch {};
}

fn benchSum() void {
    execute("SELECT SUM(value) FROM bench;") catch {};
}

fn benchMinMax() void {
    execute("SELECT MIN(value), MAX(value) FROM bench;") catch {};
}

fn benchParseSimple() void {
    const allocator = gpa.allocator();
    var l = lexer.Lexer.init("SELECT * FROM users WHERE id = 1;");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tokens = l.tokenize(arena.allocator()) catch return;
    var p = parser.Parser.init(tokens, arena.allocator());
    _ = p.parse() catch {};
}

fn benchParseComplex() void {
    const allocator = gpa.allocator();
    var l = lexer.Lexer.init("SELECT a.id, b.name, COUNT(*) FROM table_a a INNER JOIN table_b b ON a.id = b.a_id WHERE a.status = 'active' GROUP BY a.id HAVING COUNT(*) > 5 ORDER BY a.id DESC LIMIT 100;");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tokens = l.tokenize(arena.allocator()) catch return;
    var p = parser.Parser.init(tokens, arena.allocator());
    _ = p.parse() catch {};
}

pub fn main() !void {
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== ZQL Benchmark Suite ===\n\n", .{});

    const pager = try allocator.create(Pager);
    pager.* = try Pager.init(allocator, ":memory:");
    global_pager = pager;

    const db = try allocator.create(Database);
    db.* = try Database.init(allocator, pager);
    global_db = db;

    defer {
        if (global_db) |d| {
            d.close();
            allocator.destroy(d);
        }
        if (global_pager) |p| {
            p.deinit();
            allocator.destroy(p);
        }
    }

    try execute("CREATE TABLE bench (id INTEGER PRIMARY KEY, value INTEGER);");

    std.debug.print("Inserting 50 rows...\n", .{});
    var buf: [128]u8 = undefined;
    for (1..51) |i| {
        const sql = try std.fmt.bufPrint(&buf, "INSERT INTO bench VALUES ({d}, {d});", .{ i, i * 10 });
        try execute(sql);
    }
    std.debug.print("Done.\n\n", .{});

    std.debug.print("--- SELECT Performance ---\n", .{});
    runBenchmark("SELECT * (50 rows)", 100, benchSelectAll);
    runBenchmark("SELECT with WHERE", 500, benchSelectWhere);
    runBenchmark("SELECT COUNT(*)", 500, benchSelectCount);
    runBenchmark("SELECT with LIMIT", 500, benchSelectLimit);

    std.debug.print("\n--- Parser Performance ---\n", .{});
    runBenchmark("Parse simple SELECT", 10000, benchParseSimple);
    runBenchmark("Parse complex SELECT", 5000, benchParseComplex);

    std.debug.print("\n--- UPDATE Performance ---\n", .{});
    runBenchmark("UPDATE single row", 200, benchUpdate);

    std.debug.print("\n--- Aggregate Performance ---\n", .{});
    runBenchmark("SUM", 200, benchSum);
    runBenchmark("MIN/MAX", 200, benchMinMax);

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}
