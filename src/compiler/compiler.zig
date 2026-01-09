const std = @import("std");
const DB = @import("../storage/table.zig").Database;
const Instruction = @import("../vm/opcode.zig").Instruction;
const Opcode = @import("../vm/opcode.zig").Opcode;
const ast = @import("../parser/ast.zig");
const Statement = ast.Statement;

pub const CompilerError = error{
    NotImplemented,
    TableNotFound,
    ColumnNotFound,
    OutOfMemory,
};

pub const Compiler = struct {
    db: *DB,
    instructions: std.ArrayList(Instruction),
    next_reg: i32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db: *DB) Compiler {
        return Compiler{
            .db = db,
            .instructions = std.ArrayList(Instruction).init(allocator),
            .next_reg = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.instructions.deinit();
    }

    pub fn compile(self: *Compiler, stmt: Statement) ![]Instruction {
        self.instructions.clearRetainingCapacity();
        self.next_reg = 0;

        try self.emit(.init, 0, 0, 0, "", null);

        switch (stmt) {
            .select_stmt => |s| try self.compile_select(s),
            .insert_stmt => |s| try self.compile_insert(s),
            .create_table_stmt => |s| try self.compile_create_table(s),
            .delete_stmt => |s| try self.compile_delete(s),
            .update_stmt => |s| try self.compile_update(s),
            .drop_table_stmt => |s| try self.compile_drop_table(s),
        }

        try self.emit(.halt, 0, 0, 0, "", null); // halt means end of program

        return self.instructions.items;
    }

    fn emit(self: *Compiler, op: Opcode, p1: i32, p2: i32, p3: i32, p4: []const u8, p5: ?*anyopaque) !usize {
        const inst = Instruction{
            .op = op,
            .p1 = p1,
            .p2 = p2,
            .p3 = p3,
            .p4 = p4,
            .p5 = p5,
        };
        try self.instructions.append(inst);
        return self.instructions.items.len - 1;
    }

    fn alloc_reg(self: *Compiler) i32 {
        const reg = self.next_reg;
        self.next_reg += 1;
        return reg;
    }

    fn current_addr(self: *Compiler) usize {
        return self.instructions.items.len;
    }

    fn patch(self: *Compiler, addr: usize, target: i32) void {
        self.instructions.items[addr].p2 = target;
    }

    fn compile_select(self: *Compiler, stmt: ast.SelectStatement) !void {
        _ = self;
        _ = stmt;
        return CompilerError.NotImplemented;
    }

    fn compile_insert(self: *Compiler, stmt: ast.InsertStatement) !void {
        _ = self;
        _ = stmt;
        return CompilerError.NotImplemented;
    }

    fn compile_create_table(self: *Compiler, stmt: ast.CreateTableStatement) !void {
        _ = self;
        _ = stmt;
        return CompilerError.NotImplemented;
    }

    fn compile_delete(self: *Compiler, stmt: ast.DeleteStatement) !void {
        _ = self;
        _ = stmt;
        return CompilerError.NotImplemented;
    }

    fn compile_update(self: *Compiler, stmt: ast.UpdateStatement) !void {
        _ = self;
        _ = stmt;
        return CompilerError.NotImplemented;
    }

    fn compile_drop_table(self: *Compiler, stmt: ast.DropTableStatement) !void {
        _ = self;
        _ = stmt;
        return CompilerError.NotImplemented;
    }
};

test "compiler initialization" {
    const allocator = std.testing.allocator;
    const Pager = @import("../storage/pager.zig").Pager;

    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try DB.init(allocator, &pager);
    defer db.close();

    var compiler = Compiler.init(allocator, &db);
    defer compiler.deinit();

    try std.testing.expectEqual(0, compiler.next_reg);
}
