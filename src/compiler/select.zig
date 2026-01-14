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
    if (stmt.joins.len > 0) {
        try compile_join_select(c, stmt);
    } else {
        try compile_simple_select(c, stmt);
    }
}

fn compile_simple_select(c: *Compiler, stmt: SelectStatement) !void {
    const table = c.db.get_table(stmt.from) catch return CompilerError.TableNotFound;
    const schema = table.schema;

    const output_cols = try resolve_select_columns(c, stmt.columns, schema);
    defer c.allocator.free(output_cols);

    const index_candidate = if (stmt.where) |where_expr|
        try find_usable_index(c, where_expr, stmt.from, schema)
    else
        null;

    if (index_candidate) |candidate| {
        try compile_index_scan(c, stmt, schema, output_cols, candidate);
    } else {
        try compile_full_scan(c, stmt, schema, output_cols);
    }
}

fn compile_join_select(c: *Compiler, stmt: SelectStatement) !void {
    var tables = std.ArrayList(TableInfo){};
    defer tables.deinit(c.allocator);

    const main_table = c.db.get_table(stmt.from) catch return CompilerError.TableNotFound;
    try tables.append(c.allocator, .{
        .name = stmt.from,
        .schema = main_table.schema,
        .cursor_id = 0,
    });

    for (stmt.joins, 1..) |join, i| {
        const join_table = c.db.get_table(join.table) catch return CompilerError.TableNotFound;
        try tables.append(c.allocator, .{
            .name = join.table,
            .schema = join_table.schema,
            .cursor_id = @intCast(i),
        });
    }

    const output_cols = try resolve_join_columns(c, stmt.columns, tables.items);
    defer c.allocator.free(output_cols);

    for (tables.items) |tbl| {
        _ = try c.emit(.open_read, tbl.cursor_id, 0, 0, tbl.name, null);
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

    _ = try c.emit(.result_row, start_reg, @intCast(output_cols.len), 0, "", null);

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

const JoinColInfo = struct {
    cursor_id: i32,
    col_idx: i32,
};

fn resolve_join_columns(c: *Compiler, cols: []const Expression, tables: []const TableInfo) ![]JoinColInfo {
    var result = std.ArrayList(JoinColInfo){};

    for (cols) |col| {
        switch (col) {
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
        else => {},
    }
}

fn compile_full_scan(c: *Compiler, stmt: SelectStatement, schema: *const Schema, output_cols: []i32) !void {
    _ = try c.emit(.open_read, 0, 0, 0, stmt.from, null);

    const rewind_addr = try c.emit(.rewind, 0, 0, 0, "", null);

    const loop_start = c.current_addr();

    var skip_addr: ?usize = null;
    if (stmt.where) |where_expr| {
        const cond_reg = c.alloc_reg();
        try expression.compile_expression(c, where_expr, cond_reg, schema);
        skip_addr = try c.emit(.if_zero, cond_reg, 0, 0, "", null);
    }

    const start_reg = c.next_reg;
    for (output_cols) |col_idx| {
        const reg = c.alloc_reg();
        _ = try c.emit(.column, 0, col_idx, reg, "", null);
    }

    _ = try c.emit(.result_row, start_reg, @intCast(output_cols.len), 0, "", null);

    _ = try c.emit(.next, 0, @intCast(loop_start), 0, "", null);

    if (skip_addr) |addr| {
        c.patch(addr, @intCast(c.current_addr()));
        _ = try c.emit(.next, 0, @intCast(loop_start), 0, "", null);
    }

    const close_addr = c.current_addr();
    _ = try c.emit(.close, 0, 0, 0, "", null);
    c.patch(rewind_addr, @intCast(close_addr));
}

fn compile_index_scan(c: *Compiler, stmt: SelectStatement, schema: *const Schema, output_cols: []i32, candidate: IndexCandidate) !void {
    const value_reg = c.alloc_reg();
    try expression.compile_expression(c, candidate.value, value_reg, schema);

    _ = try c.emit(.open_read, 0, 0, 0, stmt.from, null);
    const scan_addr = try c.emit(.index_scan, 0, 0, value_reg, candidate.index_name, null);

    const loop_start = c.current_addr();

    const start_reg = c.next_reg;
    for (output_cols) |col_idx| {
        const reg = c.alloc_reg();
        _ = try c.emit(.column, 0, col_idx, reg, "", null);
    }

    _ = try c.emit(.result_row, start_reg, @intCast(output_cols.len), 0, "", null);

    _ = try c.emit(.index_next, 0, @intCast(loop_start), 0, "", null);

    const close_addr = c.current_addr();
    _ = try c.emit(.close, 0, 0, 0, "", null);
    c.patch(scan_addr, @intCast(close_addr));
}

fn find_usable_index(c: *Compiler, where_expr: Expression, table_name: []const u8, schema: *const Schema) !?IndexCandidate {
    switch (where_expr) {
        .binary_expression => |bin_expr| {
            const op = bin_expr.operator;
            if (!std.mem.eql(u8, op, "=") and !std.mem.eql(u8, op, "==")) {
                return null;
            }

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

            if (col_name == null or value_expr == null) return null;

            _ = schema.get_column_index(col_name.?) catch return null;

            const index_name = try find_index_for_column(c, table_name, col_name.?);
            if (index_name) |idx_name| {
                return IndexCandidate{
                    .index_name = idx_name,
                    .column_name = col_name.?,
                    .value = value_expr.?,
                };
            }
        },
        else => {},
    }

    return null;
}

fn find_index_for_column(c: *Compiler, table_name: []const u8, column_name: []const u8) !?[]const u8 {
    var idx_iter = c.db.indexes.iterator();
    while (idx_iter.next()) |entry| {
        const index_def = entry.value_ptr.*;
        if (!std.mem.eql(u8, index_def.table, table_name)) continue;

        if (index_def.columns.len == 1 and std.mem.eql(u8, index_def.columns[0], column_name)) {
            return entry.key_ptr.*;
        }
    }
    return null;
}

fn resolve_select_columns(c: *Compiler, cols: []const Expression, schema: *const Schema) ![]i32 {
    var indices = std.ArrayList(i32){};

    for (cols) |col| {
        switch (col) {
            .star_expression => {
                for (0..schema.columns.len) |i| {
                    try indices.append(c.allocator, @intCast(i));
                }
            },
            .identifier => |ident| {
                const idx = get_column_index(schema, ident.name);
                if (idx >= 0) {
                    try indices.append(c.allocator, idx);
                }
            },
            else => {},
        }
    }

    return try indices.toOwnedSlice(c.allocator);
}

fn get_column_index(schema: *const Schema, name: []const u8) i32 {
    for (schema.columns, 0..) |col, i| {
        if (std.mem.eql(u8, col.name, name)) {
            return @intCast(i);
        }
    }
    return -1;
}
