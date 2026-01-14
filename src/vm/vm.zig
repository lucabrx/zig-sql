const std = @import("std");
const opcode = @import("opcode.zig");
const Opcode = opcode.Opcode;
const Instruction = opcode.Instruction;
const VmErrors = @import("errors.zig").VmErrors;

// INIT
// OPEN_READ  cursor=0, table="users"
// REWIND     cursor=0, jump_if_empty=7
// COLUMN     cursor=0, col=0 -> r0   (id)
// COLUMN     cursor=0, col=1 -> r1   (username)
// RESULT_ROW r0, 2 cols
// NEXT       cursor=0, jump=3        (loop back)
// CLOSE      cursor=0
// HALT

const storage = struct {
    const Database = @import("../storage/table.zig").Database;
    const Table = @import("../storage/table.zig").Table;
    const Cursor = @import("../storage/cursor.zig").Cursor;
    const Btree = @import("../storage/btree.zig").Btree;
    const Pager = @import("../storage/pager.zig").Pager;
    const Schema = @import("../storage/schema.zig").Schema;
    const Row = @import("../storage/row.zig").Row;
    const row = @import("../storage/row.zig");
    const node = @import("../storage/node.zig");
};

const print = std.debug.print;

pub const MAX_REGISTERS: usize = 32;

pub const RegisterValue = struct {
    type: ValueType = .null,
    integer: i64 = 0,
    real: f64 = 0.0,
    text: []const u8 = "",
    boolean: bool = false,
    is_null: bool = true,

    pub const ValueType = enum {
        integer,
        real,
        text,
        null,
        boolean,
    };

    pub fn init_integer(value: i64) RegisterValue {
        return RegisterValue{
            .type = .integer,
            .integer = value,
            .is_null = false,
            .boolean = false,
        };
    }

    pub fn init_real(value: f64) RegisterValue {
        return RegisterValue{
            .type = .real,
            .real = value,
            .is_null = false,
        };
    }

    pub fn init_text(value: []const u8) RegisterValue {
        return RegisterValue{
            .type = .text,
            .text = value,
            .is_null = false,
        };
    }

    pub fn init_null() RegisterValue {
        return RegisterValue{
            .type = .null,
            .is_null = true,
        };
    }

    pub fn init_boolean(value: bool) RegisterValue {
        return RegisterValue{
            .type = .boolean,
            .boolean = value,
            .is_null = false,
        };
    }
};

pub const VM = struct {
    db: *storage.Database,
    program: []const Instruction = &[_]Instruction{},
    pc: usize = 0, // Program Counter
    registers: [MAX_REGISTERS]RegisterValue = [_]RegisterValue{RegisterValue{}} ** MAX_REGISTERS,
    cursors: std.AutoHashMap(i32, storage.Cursor),
    tables: std.AutoHashMap(i32, *storage.Table),
    results: std.ArrayList([]RegisterValue),
    halted: bool = false,
    debug: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db: *storage.Database) VM {
        return VM{
            .db = db,
            .cursors = std.AutoHashMap(i32, storage.Cursor).init(allocator),
            .tables = std.AutoHashMap(i32, *storage.Table).init(allocator),
            .results = std.ArrayList([]RegisterValue){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VM) void {
        self.cursors.deinit();
        self.tables.deinit();
        for (self.results.items) |row| {
            self.allocator.free(row);
        }
        self.results.deinit(self.allocator);
    }

    pub fn set_debug(self: *VM, enabled: bool) void {
        self.debug = enabled;
    }

    pub fn load(self: *VM, program: []const Instruction) void {
        self.program = program;
        self.pc = 0;
        self.halted = false;

        // Clear previous results
        for (self.results.items) |row| {
            self.allocator.free(row);
        }
        self.results.clearRetainingCapacity();

        if (self.debug) {
            print("[VM] Loaded program:\n", .{});
            for (program, 0..) |inst, i| {
                print("  {d:3}: {s}\n", .{ i, self.format_instruction(inst) });
            }
        }
    }

    pub fn run(self: *VM) !void {
        if (self.debug) {
            print("[VM] Starting execution...\n", .{});
        }

        while (!self.halted and self.pc < self.program.len) {
            const inst = self.program[self.pc];
            if (self.debug) {
                print("[VM] PC={d}: {s}\n", .{ self.pc, self.format_instruction(inst) });
            }
            try self.execute(inst);
        }

        if (self.debug) {
            print("[VM] Execution complete. {d} result rows.\n", .{self.results.items.len});
        }
    }

    pub fn get_results(self: *VM) [][]RegisterValue {
        return self.results.items;
    }

    fn execute(self: *VM, inst: Instruction) !void {
        switch (inst.op) {
            .init => {
                self.pc += 1;
            },
            .halt => {
                self.halted = true;
            },
            .goto => {
                self.pc = @intCast(inst.p2);
            },
            .if_zero => {
                if (self.registers[@intCast(inst.p1)].integer == 0) {
                    self.pc = @intCast(inst.p2);
                } else {
                    self.pc += 1;
                }
            },
            .open_read, .open_write => {
                try self.op_open_table(inst);
            },
            .close => {
                _ = self.cursors.remove(inst.p1);
                _ = self.tables.remove(inst.p1);
                self.pc += 1;
            },
            .rewind => {
                try self.op_rewind(inst);
            },
            .next => {
                try self.op_next(inst);
            },
            .column => {
                try self.op_column(inst);
            },
            .row_id => {
                try self.op_row_id(inst);
            },
            .result_row => {
                try self.op_result_row(inst);
            },
            .integer => {
                self.registers[@intCast(inst.p1)] = RegisterValue.init_integer(@intCast(inst.p2));
                self.pc += 1;
            },
            .string => {
                self.registers[@intCast(inst.p1)] = RegisterValue.init_text(inst.p4);
                self.pc += 1;
            },
            .null => {
                self.registers[@intCast(inst.p1)] = RegisterValue.init_null();
                self.pc += 1;
            },
            .make_row => {
                self.pc += 1;
            },
            .insert => {
                try self.op_insert(inst);
            },
            .create_table => {
                try self.op_create_table(inst);
            },
            .drop_table => {
                try self.op_drop_table(inst);
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                try self.op_compare(inst);
            },
            .delete => {
                try self.op_delete(inst);
            },
            else => {
                return VmErrors.InvalidOp;
            },
        }
    }

    fn op_open_table(self: *VM, inst: Instruction) !void {
        const table_name = inst.p4;
        const table = try self.db.get_table(table_name);

        try self.tables.put(inst.p1, table);
        self.pc += 1;
    }

    fn op_rewind(self: *VM, inst: Instruction) !void {
        const table = self.tables.get(inst.p1) orelse return VmErrors.NoTable;

        var cursor = try storage.Cursor.new_cursor_start(&table.btree);
        try self.cursors.put(inst.p1, cursor);

        if (cursor.is_end()) {
            self.pc = @intCast(inst.p2);
        } else {
            self.pc += 1;
        }
    }

    fn op_next(self: *VM, inst: Instruction) !void {
        var cursor = self.cursors.getPtr(inst.p1) orelse return VmErrors.NoCursor;

        try cursor.advance();

        if (cursor.is_end()) {
            self.pc += 1;
        } else {
            self.pc = @intCast(inst.p2);
        }
    }

    fn op_column(self: *VM, inst: Instruction) !void {
        const cursor = self.cursors.getPtr(inst.p1) orelse return VmErrors.NoCursor;
        const table = self.tables.get(inst.p1) orelse return VmErrors.NoTable;
        _ = table;

        const page = try self.db.pager.get_page(cursor.page_number());

        const cell_offset = storage.row.leaf_cell_offset(cursor.cell_number());
        const key_size = storage.row.LEAF_KEY_SIZE;
        const row_data = page.data[cell_offset + key_size ..];

        const col_idx: usize = @intCast(inst.p2);
        const dest_reg: usize = @intCast(inst.p3);

        switch (col_idx) {
            0 => {
                const id = std.mem.readInt(u32, row_data[0..4], .little);
                self.registers[dest_reg] = RegisterValue.init_integer(@intCast(id));
            },
            1 => {
                const username_start = storage.row.COL_ID_SIZE;
                const username_data = row_data[username_start .. username_start + storage.row.COL_USERNAME_SIZE];
                const username = std.mem.sliceTo(username_data, 0);
                self.registers[dest_reg] = RegisterValue.init_text(username);
            },
            2 => {
                const email_start = storage.row.COL_ID_SIZE + storage.row.COL_USERNAME_SIZE;
                const email_data = row_data[email_start .. email_start + storage.row.COL_EMAIL_SIZE];
                const email = std.mem.sliceTo(email_data, 0);
                self.registers[dest_reg] = RegisterValue.init_text(email);
            },
            3 => {
                const active_offset = storage.row.COL_ID_SIZE + storage.row.COL_USERNAME_SIZE + storage.row.COL_EMAIL_SIZE;
                const active = row_data[active_offset] != 0;
                self.registers[dest_reg] = RegisterValue.init_boolean(active);
            },
            else => self.registers[dest_reg] = RegisterValue.init_null(),
        }

        self.pc += 1;
    }

    fn op_row_id(self: *VM, inst: Instruction) !void {
        var cursor = self.cursors.getPtr(inst.p1) orelse return VmErrors.NoCursor;

        const key = try cursor.key();
        self.registers[@intCast(inst.p2)] = RegisterValue.init_integer(@intCast(key));
        self.pc += 1;
    }

    fn op_result_row(self: *VM, inst: Instruction) !void {
        const start_reg: usize = @intCast(inst.p1);
        const num_cols: usize = @intCast(inst.p2);

        const row = try self.allocator.alloc(RegisterValue, num_cols);
        for (0..num_cols) |i| {
            row[i] = self.registers[start_reg + i];
        }

        try self.results.append(self.allocator, row);
        self.pc += 1;
    }

    fn op_insert(self: *VM, inst: Instruction) !void {
        const table = self.tables.get(inst.p1) orelse return VmErrors.NoTable;

        const start_reg: usize = @intCast(inst.p2);
        const key: u32 = @intCast(self.registers[start_reg].integer);

        // Build row from registers
        var username: []const u8 = "";
        var email: []const u8 = "";
        var active: bool = false;

        if (inst.p3 > 1) {
            const reg = self.registers[start_reg + 1];
            if (reg.type == .text) {
                username = reg.text;
            } else if (reg.type == .boolean) {
                active = reg.boolean;
            } else if (reg.type == .integer) {
                // Boolean stored as integer 0/1
                active = reg.integer != 0;
            }
        }
        if (inst.p3 > 2) {
            const reg = self.registers[start_reg + 2];
            if (reg.type == .text) {
                email = reg.text;
            } else if (reg.type == .boolean) {
                active = reg.boolean;
            } else if (reg.type == .integer) {
                active = reg.integer != 0;
            }
        }
        if (inst.p3 > 3) {
            const reg = self.registers[start_reg + 3];
            if (reg.type == .boolean) {
                active = reg.boolean;
            } else if (reg.type == .integer) {
                active = reg.integer != 0;
            }
        }

        if (self.debug) {
            print("[VM] op_insert: key={}, username='{s}', email='{s}', active={}, num_cols={}\n", .{ key, username, email, active, inst.p3 });
        }

        const row = storage.Row.initWithActive(key, username, email, active);
        try table.insert(key, row);

        self.pc += 1;
    }

    fn op_create_table(self: *VM, inst: Instruction) !void {
        if (inst.p5) |schema_ptr| {
            const schema: *const storage.Schema = @ptrCast(@alignCast(schema_ptr));
            _ = try self.db.create_table(schema);
        }
        self.pc += 1;
    }

    fn op_drop_table(self: *VM, inst: Instruction) !void {
        const table_name = inst.p4;
        self.db.drop_table(table_name) catch |err| {
            if (inst.p1 == 0) {
                return err;
            }
        };
        self.pc += 1;
    }

    fn op_delete(self: *VM, inst: Instruction) !void {
        const cursor = self.cursors.getPtr(inst.p1) orelse return VmErrors.NoCursor;

        const page = try self.db.pager.get_page(cursor.page_number());
        const num_cells = storage.node.get_num_cells(page);
        const cell_to_delete = cursor.cell_number();

        if (self.debug) {
            print("[VM] op_delete: deleting cell {} from page {} (total cells: {})\n", .{ cell_to_delete, cursor.page_number(), num_cells });
        }

        if (cell_to_delete < num_cells - 1) {
            var i: u32 = cell_to_delete;
            while (i < num_cells - 1) : (i += 1) {
                const next_key = storage.row.get_leaf_key(page, i + 1);
                const next_row = storage.row.get_leaf_row(page, i + 1);
                storage.row.set_leaf_key(page, i, next_key);
                storage.row.set_leaf_row(page, i, next_row);
            }
        }

        storage.node.set_num_cells(page, num_cells - 1);
        self.db.pager.mark_dirty(cursor.page_number());

        self.pc += 1;
    }

    fn op_compare(self: *VM, inst: Instruction) !void {
        const left = self.registers[@intCast(inst.p1)];
        const right = self.registers[@intCast(inst.p2)];
        const dest_reg: usize = @intCast(inst.p3);

        var result: bool = false;

        if (left.type == .integer and right.type == .integer) {
            result = switch (inst.op) {
                .eq => left.integer == right.integer,
                .ne => left.integer != right.integer,
                .lt => left.integer < right.integer,
                .le => left.integer <= right.integer,
                .gt => left.integer > right.integer,
                .ge => left.integer >= right.integer,
                else => false,
            };
        } else if (left.type == .text and right.type == .text) {
            result = switch (inst.op) {
                .eq => std.mem.eql(u8, left.text, right.text),
                .ne => !std.mem.eql(u8, left.text, right.text),
                else => false,
            };
        } else if (left.type == .boolean and right.type == .boolean) {
            result = switch (inst.op) {
                .eq => left.boolean == right.boolean,
                .ne => left.boolean != right.boolean,
                else => false,
            };
        }

        self.registers[dest_reg] = RegisterValue.init_integer(if (result) 1 else 0);
        self.pc += 1;
    }

    fn format_instruction(self: *VM, inst: Instruction) []const u8 {
        _ = self;
        return inst.op.to_string();
    }
};

// Tests
test "vm initialization" {
    const allocator = std.testing.allocator;
    var pager = try storage.Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try storage.Database.init(allocator, &pager);
    defer db.close();

    var vm = VM.init(allocator, &db);
    defer vm.deinit();

    try std.testing.expect(!vm.halted);
    try std.testing.expectEqual(0, vm.pc);
}

test "vm load and halt" {
    const allocator = std.testing.allocator;
    var pager = try storage.Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try storage.Database.init(allocator, &pager);
    defer db.close();

    var vm = VM.init(allocator, &db);
    vm.set_debug(false);
    defer vm.deinit();

    const program = [_]Instruction{
        Instruction.init(.init),
        Instruction.init(.halt),
    };

    vm.load(&program);
    try vm.run();

    try std.testing.expect(vm.halted);
}

test "vm integer register" {
    const allocator = std.testing.allocator;
    var pager = try storage.Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try storage.Database.init(allocator, &pager);
    defer db.close();

    var vm = VM.init(allocator, &db);
    vm.set_debug(false);
    defer vm.deinit();

    const program = [_]Instruction{
        Instruction.init(.init),
        Instruction.init(.integer).with_p1(0).with_p2(42),
        Instruction.init(.halt),
    };

    vm.load(&program);
    try vm.run();

    try std.testing.expectEqual(42, vm.registers[0].integer);
}

test "vm comparison" {
    const allocator = std.testing.allocator;
    var pager = try storage.Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try storage.Database.init(allocator, &pager);
    defer db.close();

    var vm = VM.init(allocator, &db);
    vm.set_debug(false);
    defer vm.deinit();

    const program = [_]Instruction{
        Instruction.init(.init),
        Instruction.init(.integer).with_p1(0).with_p2(10),
        Instruction.init(.integer).with_p1(1).with_p2(10),
        Instruction.init(.eq).with_p1(0).with_p2(1).with_p3(2),
        Instruction.init(.halt),
    };

    vm.load(&program);
    try vm.run();

    try std.testing.expectEqual(1, vm.registers[2].integer);
}

test "vm goto" {
    const allocator = std.testing.allocator;
    var pager = try storage.Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try storage.Database.init(allocator, &pager);
    defer db.close();

    var vm = VM.init(allocator, &db);
    vm.set_debug(false);
    defer vm.deinit();

    const program = [_]Instruction{
        Instruction.init(.init),
        Instruction.init(.integer).with_p1(0).with_p2(1),
        Instruction.init(.goto).with_p2(4), // Skip next instruction
        Instruction.init(.integer).with_p1(0).with_p2(999), // Should be skipped
        Instruction.init(.halt),
    };

    vm.load(&program);
    try vm.run();

    try std.testing.expectEqual(1, vm.registers[0].integer);
}
