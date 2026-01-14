const std = @import("std");
const Compiler = @import("compiler.zig").Compiler;
const ast = @import("../parser/ast.zig");
const CreateTableStatement = ast.CreateTableStatement;
const DropTableStatement = ast.DropTableStatement;
const CompilerError = @import("errors.zig").CompilerError;
const Schema = @import("../storage/schema.zig").Schema;
const Column = @import("../storage/schema.zig").Column;
const Type = @import("../storage/schema.zig").Type;

pub fn compile_create_table(c: *Compiler, stmt: CreateTableStatement) !void {
    var columns = try c.persistent_allocator.alloc(Column, stmt.columns.len);
    for (stmt.columns, 0..) |col_def, i| {
        const owned_name = try c.persistent_allocator.dupe(u8, col_def.name);
        columns[i] = Column{
            .name = owned_name,
            .type = map_column_type(col_def.type_name),
            .primary_key = col_def.primary_key,
            .not_null = col_def.not_null,
        };
    }

    const owned_table_name = try c.persistent_allocator.dupe(u8, stmt.table);

    const schema_ptr = try c.persistent_allocator.create(Schema);
    schema_ptr.* = Schema.init(owned_table_name, columns);

    _ = try c.emit(.create_table, 0, 0, 0, "", @ptrCast(schema_ptr));
}

pub fn compile_drop_table(c: *Compiler, stmt: DropTableStatement) !void {
    const if_exists: i32 = if (stmt.if_exists) 1 else 0;
    _ = try c.emit(.drop_table, if_exists, 0, 0, stmt.table, null);
}

pub fn compile_drop_index(c: *Compiler, stmt: ast.DropIndexStatement) !void {
    const if_exists: i32 = if (stmt.if_exists) 1 else 0;
    _ = try c.emit(.drop_index, if_exists, 0, 0, stmt.index_name, null);
}

pub fn compile_create_index(c: *Compiler, stmt: ast.CreateIndexStatement) !void {
    const IndexDef = @import("../storage/schema.zig").IndexDef;

    _ = c.db.get_table(stmt.table) catch return CompilerError.TableNotFound;

    var columns = try c.persistent_allocator.alloc([]const u8, stmt.columns.len);
    for (stmt.columns, 0..) |col, i| {
        columns[i] = try c.persistent_allocator.dupe(u8, col);
    }

    const index_def = try c.persistent_allocator.create(IndexDef);
    index_def.* = IndexDef{
        .name = try c.persistent_allocator.dupe(u8, stmt.index_name),
        .table = try c.persistent_allocator.dupe(u8, stmt.table),
        .columns = columns,
        .unique = stmt.unique,
        .root_page = 0, // Will be set by VM
    };

    _ = try c.emit(.create_index, 0, 0, 0, "", @ptrCast(index_def));
}

fn map_column_type(parser_type: []const u8) Type {
    if (std.mem.eql(u8, parser_type, "INTEGER") or std.mem.eql(u8, parser_type, "INT")) {
        return .Integer;
    } else if (std.mem.eql(u8, parser_type, "TEXT") or std.mem.eql(u8, parser_type, "VARCHAR")) {
        return .Text;
    } else if (std.mem.eql(u8, parser_type, "REAL") or std.mem.eql(u8, parser_type, "FLOAT")) {
        return .Real;
    } else if (std.mem.eql(u8, parser_type, "BLOB")) {
        return .Blob;
    } else if (std.mem.eql(u8, parser_type, "BOOLEAN") or std.mem.eql(u8, parser_type, "BOOL")) {
        return .Boolean;
    } else {
        return .Text;
    }
}

test "compile create table" {
    const allocator = std.testing.allocator;
    const Pager = @import("../storage/pager.zig").Pager;
    const DB = @import("../storage/table.zig").Database;
    const Opcode = @import("../vm/opcode.zig").Opcode;

    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try DB.init(allocator, &pager);
    defer db.close();

    var compiler = Compiler.init(allocator, allocator, &db);
    defer compiler.deinit();

    const stmt = CreateTableStatement{
        .table = "users",
        .columns = &[_]ast.ColumnDef{
            .{ .name = "id", .type_name = "INTEGER", .primary_key = true, .not_null = true },
            .{ .name = "name", .type_name = "TEXT", .primary_key = false, .not_null = false },
        },
    };

    try compile_create_table(&compiler, stmt);

    if (compiler.instructions.items[0].p5) |ptr| {
        const schema_ptr: *Schema = @ptrCast(@alignCast(ptr));
        for (schema_ptr.columns) |col| {
            allocator.free(col.name);
        }
        allocator.free(schema_ptr.columns);
        allocator.free(schema_ptr.table_name);
        allocator.destroy(schema_ptr);
    }

    try std.testing.expect(compiler.instructions.items.len >= 1);
    try std.testing.expectEqual(Opcode.create_table, compiler.instructions.items[0].op);
}

test "compile drop table" {
    const allocator = std.testing.allocator;
    const Pager = @import("../storage/pager.zig").Pager;
    const DB = @import("../storage/table.zig").Database;
    const Opcode = @import("../vm/opcode.zig").Opcode;

    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try DB.init(allocator, &pager);
    defer db.close();

    var compiler = Compiler.init(allocator, allocator, &db);
    defer compiler.deinit();

    const stmt = DropTableStatement{
        .table = "users",
        .if_exists = true,
    };

    try compile_drop_table(&compiler, stmt);

    try std.testing.expect(compiler.instructions.items.len >= 1);
    try std.testing.expectEqual(Opcode.drop_table, compiler.instructions.items[0].op);
    try std.testing.expectEqual(1, compiler.instructions.items[0].p1); // if_exists = 1
}
