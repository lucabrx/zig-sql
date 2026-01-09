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
    var columns = try c.allocator.alloc(Column, stmt.columns.len);
    for (stmt.columns, 0..) |col_def, i| {
        columns[i] = Column{
            .name = col_def.name,
            .type = map_column_type(col_def.type_name),
            .primary_key = col_def.primary_key,
            .not_null = col_def.not_null,
        };
    }

    const schema_ptr = try c.allocator.create(Schema);
    schema_ptr.* = Schema.init(stmt.table, columns);

    _ = try c.emit(.create_table, 0, 0, 0, "", @ptrCast(schema_ptr));
}

pub fn compile_drop_table(c: *Compiler, stmt: DropTableStatement) !void {
    const if_exists: i32 = if (stmt.if_exists) 1 else 0;
    _ = try c.emit(.drop_table, if_exists, 0, 0, stmt.table, null);
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
    } else {
        return .Text; // Default to TEXT
    }
}
