const std = @import("std");
const Compiler = @import("compiler.zig").Compiler;
const ast = @import("../parser/ast.zig");
const SelectStatement = ast.SelectStatement;
const Expression = ast.Expression;
const JoinClause = ast.JoinClause;
const JoinType = ast.JoinType;
const CompilerError = @import("errors.zig").CompilerError;
const expression = @import("expression.zig");
const Schema = @import("../storage/schema.zig").Schema;
const IndexDef = @import("../storage/schema.zig").IndexDef;
const ViewDef = @import("../storage/schema.zig").ViewDef;
const Parser = @import("../parser/parser.zig").Parser;
const lexer = @import("../lexer/lexer.zig");

const IndexCandidate = struct {
    index_name: []const u8,
    column_name: []const u8,
    value: Expression,
};

const TableInfo = struct {
    name: []const u8,
    schema: *const Schema,
    cursor_id: i32,
};

pub fn compile_select(c: *Compiler, stmt: SelectStatement) !void {
    if (stmt.group_by.len > 0 or has_aggregates(stmt.columns)) {
        try compile_grouped_select(c, stmt);
    } else if (stmt.joins.len > 0 or stmt.from.len > 1) {
        try compile_join_select(c, stmt);
    } else {
        try compile_simple_select(c, stmt);
    }
}

pub fn compile_union(c: *Compiler, stmt: ast.UnionStatement) !void {
    _ = try c.emit(.union_start, 0, 0, 0, "", null);

    try compile_select(c, stmt.left);

    try compile_union_right(c, stmt.right, stmt.all);
}

fn compile_union_right(c: *Compiler, right: *ast.UnionOrSelect, all: bool) !void {
    switch (right.*) {
        .select => |sel| {
            try compile_select(c, sel);
            _ = try c.emit(.union_merge, if (all) 1 else 0, 0, 0, "", null);
        },
        .union_stmt => |u| {
            try compile_select(c, u.left);
            _ = try c.emit(.union_merge, if (all) 1 else 0, 0, 0, "", null);
            try compile_union_right(c, u.right, u.all);
        },
    }
}

fn compile_view_select(c: *Compiler, outer_stmt: SelectStatement, view_def: *ViewDef) !void {
    _ = outer_stmt;

    var lex = lexer.Lexer.init(view_def.sql);
    const tokens = lex.tokenize(c.allocator) catch return CompilerError.InvalidSyntax;
    defer c.allocator.free(tokens);

    var parser = Parser.init(tokens, c.allocator);
    defer parser.deinit();

    const parsed = parser.parse() catch return CompilerError.InvalidSyntax;
    const view_select = switch (parsed) {
        .select_stmt => |s| s,
        else => return CompilerError.InvalidSyntax,
    };

    if (view_select.group_by.len > 0 or has_aggregates(view_select.columns)) {
        try compile_grouped_select(c, view_select);
    } else if (view_select.joins.len > 0 or view_select.from.len > 1) {
        try compile_join_select(c, view_select);
    } else {
        const table = c.db.get_table(view_select.from[0].name) catch return CompilerError.TableNotFound;
        const schema = table.schema;

        const output_cols = try resolve_select_columns(c, view_select.columns, schema);
        defer c.allocator.free(output_cols);

        try compile_full_scan(c, view_select, schema, output_cols);
        try compile_order_limit(c, view_select, schema);
    }
}

fn has_aggregates(cols: []const ast.SelectColumn) bool {
    for (cols) |col| {
        if (col.expr == .aggregate) return true;
    }
    return false;
}

fn compile_grouped_select(c: *Compiler, stmt: SelectStatement) !void {
    const table = c.db.get_table(stmt.from[0].name) catch return CompilerError.TableNotFound;
    const schema = table.schema;

    const agg_info = try analyze_aggregates(c, stmt.columns, schema);
    defer c.allocator.free(agg_info.agg_cols);

    _ = try c.emit(.agg_init, @intCast(agg_info.agg_cols.len), @intCast(stmt.group_by.len), 0, "", null);

    _ = try c.emit(.open_read, 0, 0, 0, stmt.from[0].name, null);
    const rewind_addr = try c.emit(.rewind, 0, 0, 0, "", null);
    const loop_start = c.current_addr();

    var skip_addr: ?usize = null;
    if (stmt.where) |where_expr| {
        const cond_reg = c.alloc_reg();
        try expression.compile_expression(c, where_expr, cond_reg, schema);
        skip_addr = try c.emit(.if_zero, cond_reg, 0, 0, "", null);
    }

    const group_key_start = c.next_reg;
    for (stmt.group_by) |col_name| {
        const reg = c.alloc_reg();
        const col_idx = schema.get_column_index(col_name) catch 0;
        _ = try c.emit(.column, 0, @intCast(col_idx), reg, "", null);
    }

    for (agg_info.agg_cols, 0..) |agg_col, i| {
        const val_reg = c.alloc_reg();
        if (agg_col.arg_col_idx) |col_idx| {
            _ = try c.emit(.column, 0, col_idx, val_reg, "", null);
        } else {
            _ = try c.emit(.integer, val_reg, 1, 0, "", null);
        }
        _ = try c.emit(.agg_step, @intCast(i), val_reg, group_key_start, @tagName(agg_col.func), null);
    }

    _ = try c.emit(.next, 0, @intCast(loop_start), 0, "", null);

    if (skip_addr) |addr| {
        c.patch(addr, @intCast(c.current_addr() - 1));
    }

    const close_addr = c.current_addr();
    _ = try c.emit(.close, 0, 0, 0, "", null);
    c.patch(rewind_addr, @intCast(close_addr));

    var having_ptr: ?*anyopaque = null;
    if (stmt.having) |having_expr| {
        const having_copy = c.allocator.create(Expression) catch return CompilerError.OutOfMemory;
        having_copy.* = having_expr;
        having_ptr = @ptrCast(having_copy);
    }

    _ = try c.emit(.agg_final, 0, @intCast(stmt.group_by.len), if (stmt.distinct) 1 else 0, "", having_ptr);
}

const AggColInfo = struct {
    func: ast.AggregateFunction,
    arg_col_idx: ?i32,
};

const AggAnalysis = struct {
    agg_cols: []AggColInfo,
};

fn analyze_aggregates(c: *Compiler, cols: []const ast.SelectColumn, schema: *const Schema) !AggAnalysis {
    var agg_cols = std.ArrayList(AggColInfo){};

    for (cols) |col| {
        switch (col.expr) {
            .aggregate => |agg| {
                var arg_idx: ?i32 = null;
                if (agg.arg) |arg| {
                    switch (arg) {
                        .identifier => |ident| {
                            arg_idx = @intCast(schema.get_column_index(ident.name) catch 0);
                        },
                        else => {},
                    }
                }
                try agg_cols.append(c.allocator, .{
                    .func = agg.function,
                    .arg_col_idx = arg_idx,
                });
            },
            else => {},
        }
    }

    return AggAnalysis{
        .agg_cols = try agg_cols.toOwnedSlice(c.allocator),
    };
}

fn compile_simple_select(c: *Compiler, stmt: SelectStatement) !void {
    const table = c.db.get_table(stmt.from[0].name) catch {
        if (c.db.get_view(stmt.from[0].name)) |view_def| {
            return compile_view_select(c, stmt, view_def);
        } else |_| {}
        return CompilerError.TableNotFound;
    };
    const schema = table.schema;

    const output_cols = try resolve_select_columns(c, stmt.columns, schema);
    defer c.allocator.free(output_cols);

    const index_candidate = if (stmt.where) |where_expr|
        try find_usable_index(c, where_expr, stmt.from[0].name, schema)
    else
        null;

    if (index_candidate) |candidate| {
        try compile_index_scan(c, stmt, schema, output_cols, candidate);
    } else {
        try compile_full_scan(c, stmt, schema, output_cols);
    }

    try compile_order_limit(c, stmt, schema);
}

fn compile_join_select(c: *Compiler, stmt: SelectStatement) !void {
    var tables = std.ArrayList(TableInfo){};
    defer tables.deinit(c.allocator);

    for (stmt.from, 0..) |from_table, i| {
        const table = c.db.get_table(from_table.name) catch return CompilerError.TableNotFound;
        try tables.append(c.allocator, .{
            .name = if (from_table.alias) |a| a else from_table.name,
            .schema = table.schema,
            .cursor_id = @intCast(i),
        });
    }

    const join_cursor_start: usize = stmt.from.len;
    for (stmt.joins, 0..) |join, i| {
        const join_table = c.db.get_table(join.table.name) catch return CompilerError.TableNotFound;
        try tables.append(c.allocator, .{
            .name = if (join.table.alias) |a| a else join.table.name,
            .schema = join_table.schema,
            .cursor_id = @intCast(join_cursor_start + i),
        });
    }

    try optimize_join_order(c, &tables, stmt);

    const output_cols = try resolve_join_columns(c, stmt.columns, tables.items);
    defer c.allocator.free(output_cols);

    for (tables.items, 0..) |tbl, idx| {
        const actual_name = if (idx < stmt.from.len) stmt.from[idx].name else stmt.joins[idx - stmt.from.len].table.name;
        _ = try c.emit(.open_read, tbl.cursor_id, 0, 0, actual_name, null);
    }

    var rewind_addrs = std.ArrayList(usize){};
    defer rewind_addrs.deinit(c.allocator);
    var loop_starts = std.ArrayList(usize){};
    defer loop_starts.deinit(c.allocator);

    for (tables.items) |tbl| {
        const rewind_addr = try c.emit(.rewind, tbl.cursor_id, 0, 0, "", null);
        try rewind_addrs.append(c.allocator, rewind_addr);
        try loop_starts.append(c.allocator, c.current_addr());
    }

    var skip_addr: ?usize = null;
    if (stmt.joins.len > 0) {
        for (stmt.joins) |join| {
            if (join.condition) |cond| {
                const cond_reg = c.alloc_reg();
                try compile_join_condition(c, cond, tables.items, cond_reg);
                skip_addr = try c.emit(.if_zero, cond_reg, 0, 0, "", null);
            }
        }
    }

    if (stmt.where) |where_expr| {
        const where_reg = c.alloc_reg();
        try compile_join_expression(c, where_expr, tables.items, where_reg);
        const where_skip = try c.emit(.if_zero, where_reg, 0, 0, "", null);
        if (skip_addr == null) {
            skip_addr = where_skip;
        } else {
            c.patch(skip_addr.?, @intCast(c.current_addr()));
            skip_addr = where_skip;
        }
    }

    const start_reg = c.next_reg;
    for (output_cols) |col_info| {
        const reg = c.alloc_reg();
        _ = try c.emit(.column, col_info.cursor_id, col_info.col_idx, reg, "", null);
    }

    _ = try c.emit(.result_row, start_reg, @intCast(output_cols.len), if (stmt.distinct) 1 else 0, "", null);

    var i: usize = tables.items.len;
    while (i > 0) {
        i -= 1;
        _ = try c.emit(.next, tables.items[i].cursor_id, @intCast(loop_starts.items[i]), 0, "", null);

        if (skip_addr != null and i == tables.items.len - 1) {
            c.patch(skip_addr.?, @intCast(c.current_addr() - 1));
        }
    }

    const close_addr = c.current_addr();
    for (tables.items) |tbl| {
        _ = try c.emit(.close, tbl.cursor_id, 0, 0, "", null);
    }

    for (rewind_addrs.items) |addr| {
        c.patch(addr, @intCast(close_addr));
    }
}

fn optimize_join_order(c: *Compiler, tables: *std.ArrayList(TableInfo), stmt: SelectStatement) !void {
    if (tables.items.len <= 1) return;

    var costs = try c.allocator.alloc(usize, tables.items.len);
    defer c.allocator.free(costs);

    for (tables.items, 0..) |tbl, i| {
        var cost: usize = tbl.schema.columns.len * 100;

        const actual_name = if (i < stmt.from.len) stmt.from[i].name else stmt.joins[i - stmt.from.len].table.name;
        var idx_iter = c.db.indexes.iterator();
        while (idx_iter.next()) |entry| {
            const index_def = entry.value_ptr.*;
            if (std.mem.eql(u8, index_def.table, actual_name)) {
                cost = cost / 2;
                break;
            }
        }

        costs[i] = cost;
    }

    var j: usize = 0;
    while (j < tables.items.len - 1) : (j += 1) {
        var min_idx = j;
        var k = j + 1;
        while (k < tables.items.len) : (k += 1) {
            if (costs[k] < costs[min_idx]) {
                min_idx = k;
            }
        }
        if (min_idx != j) {
            const tmp_tbl = tables.items[j];
            tables.items[j] = tables.items[min_idx];
            tables.items[min_idx] = tmp_tbl;

            const tmp_cost = costs[j];
            costs[j] = costs[min_idx];
            costs[min_idx] = tmp_cost;
        }
    }
}

const JoinColInfo = struct {
    cursor_id: i32,
    col_idx: i32,
};

fn resolve_join_columns(c: *Compiler, cols: []const ast.SelectColumn, tables: []const TableInfo) ![]JoinColInfo {
    var result = std.ArrayList(JoinColInfo){};

    for (cols) |col| {
        switch (col.expr) {
            .star_expression => {
                for (tables) |tbl| {
                    for (0..tbl.schema.columns.len) |col_idx| {
                        try result.append(c.allocator, .{
                            .cursor_id = tbl.cursor_id,
                            .col_idx = @intCast(col_idx),
                        });
                    }
                }
            },
            .identifier => |ident| {
                const info = try resolve_column_in_tables(ident.name, tables);
                try result.append(c.allocator, info);
            },
            else => {},
        }
    }

    return try result.toOwnedSlice(c.allocator);
}

fn resolve_column_in_tables(name: []const u8, tables: []const TableInfo) !JoinColInfo {
    var dot_pos: ?usize = null;
    for (name, 0..) |ch, i| {
        if (ch == '.') {
            dot_pos = i;
            break;
        }
    }

    if (dot_pos) |pos| {
        const table_name = name[0..pos];
        const col_name = name[pos + 1 ..];

        for (tables) |tbl| {
            if (std.mem.eql(u8, tbl.name, table_name)) {
                for (tbl.schema.columns, 0..) |schema_col, i| {
                    if (std.mem.eql(u8, schema_col.name, col_name)) {
                        return JoinColInfo{
                            .cursor_id = tbl.cursor_id,
                            .col_idx = @intCast(i),
                        };
                    }
                }
            }
        }
    } else {
        for (tables) |tbl| {
            for (tbl.schema.columns, 0..) |schema_col, i| {
                if (std.mem.eql(u8, schema_col.name, name)) {
                    return JoinColInfo{
                        .cursor_id = tbl.cursor_id,
                        .col_idx = @intCast(i),
                    };
                }
            }
        }
    }

    return CompilerError.ColumnNotFound;
}

fn compile_join_condition(c: *Compiler, expr: Expression, tables: []const TableInfo, dest_reg: i32) !void {
    try compile_join_expression(c, expr, tables, dest_reg);
}

fn compile_join_expression(c: *Compiler, expr: Expression, tables: []const TableInfo, dest_reg: i32) CompilerError!void {
    switch (expr) {
        .identifier => |ident| {
            const info = try resolve_column_in_tables(ident.name, tables);
            _ = try c.emit(.column, info.cursor_id, info.col_idx, dest_reg, "", null);
        },
        .integer_literal => |lit| {
            _ = try c.emit(.integer, dest_reg, @intCast(lit.value), 0, "", null);
        },
        .string_literal => |lit| {
            _ = try c.emit(.string, dest_reg, 0, 0, lit.value, null);
        },
        .null_literal => {
            _ = try c.emit(.null, dest_reg, 0, 0, "", null);
        },
        .boolean_literal => |lit| {
            _ = try c.emit(.integer, dest_reg, if (lit.value) 1 else 0, 0, "", null);
        },
        .binary_expression => |bin| {
            const left_reg = c.alloc_reg();
            const right_reg = c.alloc_reg();

            try compile_join_expression(c, bin.left, tables, left_reg);
            try compile_join_expression(c, bin.right, tables, right_reg);

            const op = bin.operator;
            if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
                _ = try c.emit(.eq, left_reg, right_reg, dest_reg, "", null);
            } else if (std.mem.eql(u8, op, "!=") or std.mem.eql(u8, op, "<>")) {
                _ = try c.emit(.ne, left_reg, right_reg, dest_reg, "", null);
            } else if (std.mem.eql(u8, op, "<")) {
                _ = try c.emit(.lt, left_reg, right_reg, dest_reg, "", null);
            } else if (std.mem.eql(u8, op, "<=")) {
                _ = try c.emit(.le, left_reg, right_reg, dest_reg, "", null);
            } else if (std.mem.eql(u8, op, ">")) {
                _ = try c.emit(.gt, left_reg, right_reg, dest_reg, "", null);
            } else if (std.mem.eql(u8, op, ">=")) {
                _ = try c.emit(.ge, left_reg, right_reg, dest_reg, "", null);
            } else if (std.mem.eql(u8, op, "AND")) {
                _ = try c.emit(.@"and", left_reg, right_reg, dest_reg, "", null);
            } else if (std.mem.eql(u8, op, "OR")) {
                _ = try c.emit(.@"or", left_reg, right_reg, dest_reg, "", null);
            }
        },
        .subquery => |subq| {
            const subq_ptr = c.allocator.create(ast.SubqueryExpression) catch return CompilerError.OutOfMemory;
            subq_ptr.* = subq.*;
            _ = try c.emit(.subquery, dest_reg, 0, 0, "", @ptrCast(subq_ptr));
        },
        else => {},
    }
}

fn compile_order_limit(c: *Compiler, stmt: SelectStatement, schema: *const Schema) !void {
    if (stmt.order_by.len > 0) {
        const order = stmt.order_by[0];
        const col_idx = schema.get_column_index(order.column) catch 0;
        _ = try c.emit(.sort_results, @intCast(col_idx), if (order.desc) 1 else 0, 0, "", null);
    }

    if (stmt.limit != null or stmt.offset != null) {
        const limit: i32 = if (stmt.limit) |l| @intCast(l) else 0;
        const offset: i32 = if (stmt.offset) |o| @intCast(o) else 0;
        _ = try c.emit(.limit_results, limit, offset, 0, "", null);
    }
}

const ColInfo = union(enum) {
    column_idx: i32,
    expression: Expression,
};

fn compile_full_scan(c: *Compiler, stmt: SelectStatement, schema: *const Schema, output_cols: []ColInfo) !void {
    _ = try c.emit(.open_read, 0, 0, 0, stmt.from[0].name, null);

    const rewind_addr = try c.emit(.rewind, 0, 0, 0, "", null);

    const loop_start = c.current_addr();

    var skip_addr: ?usize = null;
    if (stmt.where) |where_expr| {
        const cond_reg = c.alloc_reg();
        try expression.compile_expression(c, where_expr, cond_reg, schema);
        skip_addr = try c.emit(.if_zero, cond_reg, 0, 0, "", null);
    }

    const start_reg = c.next_reg;
    const num_cols = output_cols.len;
    for (0..num_cols) |_| {
        _ = c.alloc_reg();
    }

    for (output_cols, 0..) |col_info, i| {
        const reg: i32 = @intCast(start_reg + @as(i32, @intCast(i)));
        switch (col_info) {
            .column_idx => |col_idx| {
                _ = try c.emit(.column, 0, col_idx, reg, "", null);
            },
            .expression => |expr| {
                try expression.compile_expression(c, expr, reg, schema);
            },
        }
    }

    _ = try c.emit(.result_row, start_reg, @intCast(output_cols.len), if (stmt.distinct) 1 else 0, "", null);

    _ = try c.emit(.next, 0, @intCast(loop_start), 0, "", null);

    if (skip_addr) |addr| {
        c.patch(addr, @intCast(c.current_addr()));
        _ = try c.emit(.next, 0, @intCast(loop_start), 0, "", null);
    }

    const close_addr = c.current_addr();
    _ = try c.emit(.close, 0, 0, 0, "", null);
    c.patch(rewind_addr, @intCast(close_addr));
}

fn compile_index_scan(c: *Compiler, stmt: SelectStatement, schema: *const Schema, output_cols: []ColInfo, candidate: IndexCandidate) !void {
    const value_reg = c.alloc_reg();
    try expression.compile_expression(c, candidate.value, value_reg, schema);

    _ = try c.emit(.open_read, 0, 0, 0, stmt.from[0].name, null);
    const scan_addr = try c.emit(.index_scan, 0, 0, value_reg, candidate.index_name, null);

    const loop_start = c.current_addr();

    const start_reg = c.next_reg;
    const num_cols = output_cols.len;
    for (0..num_cols) |_| {
        _ = c.alloc_reg();
    }

    for (output_cols, 0..) |col_info, i| {
        const reg: i32 = @intCast(start_reg + @as(i32, @intCast(i)));
        switch (col_info) {
            .column_idx => |col_idx| {
                _ = try c.emit(.column, 0, col_idx, reg, "", null);
            },
            .expression => |expr| {
                try expression.compile_expression(c, expr, reg, schema);
            },
        }
    }

    _ = try c.emit(.result_row, start_reg, @intCast(output_cols.len), if (stmt.distinct) 1 else 0, "", null);

    _ = try c.emit(.index_next, 0, @intCast(loop_start), 0, "", null);

    const close_addr = c.current_addr();
    _ = try c.emit(.close, 0, 0, 0, "", null);
    c.patch(scan_addr, @intCast(close_addr));
}

const EqualityCandidate = struct { col: []const u8, val: Expression };

fn find_usable_index(c: *Compiler, where_expr: Expression, table_name: []const u8, schema: *const Schema) !?IndexCandidate {
    var candidates = std.ArrayList(EqualityCandidate){};
    defer candidates.deinit(c.allocator);

    try extract_equality_conditions(where_expr, &candidates, c.allocator);

    if (candidates.items.len == 0) return null;

    var idx_iter = c.db.indexes.iterator();
    while (idx_iter.next()) |entry| {
        const index_def = entry.value_ptr.*;
        if (!std.mem.eql(u8, index_def.table, table_name)) continue;

        if (index_def.columns.len == 1) {
            for (candidates.items) |cand| {
                _ = schema.get_column_index(cand.col) catch continue;
                if (std.mem.eql(u8, index_def.columns[0], cand.col)) {
                    return IndexCandidate{
                        .index_name = entry.key_ptr.*,
                        .column_name = cand.col,
                        .value = cand.val,
                    };
                }
            }
        }
    }

    return null;
}

fn extract_equality_conditions(expr: Expression, candidates: *std.ArrayList(EqualityCandidate), allocator: std.mem.Allocator) !void {
    switch (expr) {
        .binary_expression => |bin_expr| {
            const op = bin_expr.operator;
            if (std.mem.eql(u8, op, "AND")) {
                try extract_equality_conditions(bin_expr.left, candidates, allocator);
                try extract_equality_conditions(bin_expr.right, candidates, allocator);
            } else if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
                var col_name: ?[]const u8 = null;
                var value_expr: ?Expression = null;

                switch (bin_expr.left) {
                    .identifier => |ident| {
                        col_name = ident.name;
                        value_expr = bin_expr.right;
                    },
                    else => {},
                }
                if (col_name == null) {
                    switch (bin_expr.right) {
                        .identifier => |ident| {
                            col_name = ident.name;
                            value_expr = bin_expr.left;
                        },
                        else => {},
                    }
                }
                if (col_name != null and value_expr != null) {
                    try candidates.append(allocator, .{ .col = col_name.?, .val = value_expr.? });
                }
            }
        },
        else => {},
    }
}

fn resolve_select_columns(c: *Compiler, cols: []const ast.SelectColumn, schema: *const Schema) ![]ColInfo {
    var result = std.ArrayList(ColInfo){};

    for (cols) |col| {
        switch (col.expr) {
            .star_expression => {
                for (0..schema.columns.len) |i| {
                    try result.append(c.allocator, .{ .column_idx = @intCast(i) });
                }
            },
            .identifier => |ident| {
                const idx = get_column_index(schema, ident.name);
                if (idx >= 0) {
                    try result.append(c.allocator, .{ .column_idx = idx });
                }
            },
            else => {
                try result.append(c.allocator, .{ .expression = col.expr });
            },
        }
    }

    return try result.toOwnedSlice(c.allocator);
}

fn get_column_index(schema: *const Schema, name: []const u8) i32 {
    for (schema.columns, 0..) |col, i| {
        if (std.mem.eql(u8, col.name, name)) {
            return @intCast(i);
        }
    }
    return -1;
}
