const std = @import("std");
const DB = @import("../storage/table.zig").Database;
const Instruction = @import("../vm/opcode.zig").Instruction;
const Opcode = @import("../vm/opcode.zig").Opcode;
const ast = @import("../parser/ast.zig");
const Statement = ast.Statement;

const select = @import("select.zig");
const insert = @import("insert.zig");
const delete = @import("delete.zig");
const update = @import("update.zig");
const schema = @import("schema.zig");

pub const Compiler = struct {
    db: *DB,
    instructions: std.ArrayList(Instruction),
    next_reg: i32,
    allocator: std.mem.Allocator,
    persistent_allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, persistent_allocator: std.mem.Allocator, db: *DB) Compiler {
        return Compiler{
            .db = db,
            .instructions = std.ArrayList(Instruction){},
            .next_reg = 0,
            .allocator = allocator,
            .persistent_allocator = persistent_allocator,
        };
    }

    pub fn deinit(self: *Compiler) void {
        self.instructions.deinit(self.allocator);
    }

    pub fn compile(self: *Compiler, stmt: Statement) ![]Instruction {
        self.instructions.clearRetainingCapacity();
        self.next_reg = 0;

        _ = try self.emit(.init, 0, 0, 0, "", null);

        switch (stmt) {
            .select_stmt => |s| try select.compile_select(self, s),
            .insert_stmt => |s| try insert.compile_insert(self, s),
            .create_table_stmt => |s| try schema.compile_create_table(self, s),
            .create_index_stmt => |s| try schema.compile_create_index(self, s),
            .delete_stmt => |s| try delete.compile_delete(self, s),
            .update_stmt => |s| try update.compile_update(self, s),
            .drop_table_stmt => |s| try schema.compile_drop_table(self, s),
            .drop_index_stmt => |s| try schema.compile_drop_index(self, s),
            .begin_stmt => _ = try self.emit(.txn_begin, 0, 0, 0, "", null),
            .commit_stmt => _ = try self.emit(.txn_commit, 0, 0, 0, "", null),
            .rollback_stmt => |s| {
                if (s.savepoint_name) |name| {
                    _ = try self.emit(.txn_rollback_to, 0, 0, 0, name, null);
                } else {
                    _ = try self.emit(.txn_rollback, 0, 0, 0, "", null);
                }
            },
            .savepoint_stmt => |s| _ = try self.emit(.txn_savepoint, 0, 0, 0, s.name, null),
            .release_savepoint_stmt => |s| _ = try self.emit(.txn_release, 0, 0, 0, s.name, null),
            .set_transaction_stmt => |s| {
                const level: i32 = switch (s.isolation_level) {
                    .read_uncommitted => 0,
                    .read_committed => 1,
                    .repeatable_read => 2,
                    .serializable => 3,
                };
                _ = try self.emit(.txn_set_isolation, level, 0, 0, "", null);
            },
            .union_stmt => |s| try select.compile_union(self, s),
        }

        _ = try self.emit(.halt, 0, 0, 0, "", null);

        return self.instructions.items;
    }

    pub fn emit(self: *Compiler, op: Opcode, p1: i32, p2: i32, p3: i32, p4: []const u8, p5: ?*anyopaque) !usize {
        const inst = Instruction{
            .op = op,
            .p1 = p1,
            .p2 = p2,
            .p3 = p3,
            .p4 = p4,
            .p5 = p5,
        };
        try self.instructions.append(self.allocator, inst);
        return self.instructions.items.len - 1;
    }

    pub fn alloc_reg(self: *Compiler) i32 {
        const reg = self.next_reg;
        self.next_reg += 1;
        return reg;
    }

    pub fn current_addr(self: *Compiler) usize {
        return self.instructions.items.len;
    }

    pub fn patch(self: *Compiler, addr: usize, target: i32) void {
        self.instructions.items[addr].p2 = target;
    }
};

test "compiler initialization" {
    const allocator = std.testing.allocator;
    const Pager = @import("../storage/pager.zig").Pager;

    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try DB.init(allocator, &pager);
    defer db.close();

    var compiler = Compiler.init(allocator, allocator, &db);
    defer compiler.deinit();

    try std.testing.expectEqual(0, compiler.next_reg);
}
