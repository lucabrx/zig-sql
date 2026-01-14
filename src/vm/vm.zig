const std = @import("std");
const opcode = @import("opcode.zig");
const Opcode = opcode.Opcode;
const Instruction = opcode.Instruction;
const VmErrors = @import("errors.zig").VmErrors;

const storage = struct {
    const Database = @import("../storage/table.zig").Database;
    const Table = @import("../storage/table.zig").Table;
    const Cursor = @import("../storage/cursor.zig").Cursor;
    const Btree = @import("../storage/btree.zig").Btree;
    const Pager = @import("../storage/pager.zig").Pager;
    const Schema = @import("../storage/schema.zig").Schema;
    const Column = @import("../storage/schema.zig").Column;
    const Type = @import("../storage/schema.zig").Type;
    const row = @import("../storage/row.zig");
    const DynamicRow = row.DynamicRow;
    const RowValue = row.RowValue;
    const node = @import("../storage/node.zig");
    const Transaction = @import("../storage/transaction.zig").Transaction;
    const IsolationLevel = @import("../storage/transaction.zig").IsolationLevel;
};

const print = std.debug.print;

pub const MAX_REGISTERS: usize = 32;

pub const RegisterValue = struct {
    type: ValueType = .null,
    integer: i64 = 0,
    real: f64 = 0.0,
    text: []const u8 = "",
    blob: []const u8 = "",
    boolean: bool = false,
    is_null: bool = true,

    pub const ValueType = enum { integer, real, text, blob, null, boolean };

    pub fn init_integer(value: i64) RegisterValue {
        return RegisterValue{ .type = .integer, .integer = value, .is_null = false };
    }
    pub fn init_real(value: f64) RegisterValue {
        return RegisterValue{ .type = .real, .real = value, .is_null = false };
    }
    pub fn init_text(value: []const u8) RegisterValue {
        return RegisterValue{ .type = .text, .text = value, .is_null = false };
    }
    pub fn init_null() RegisterValue {
        return RegisterValue{ .type = .null, .is_null = true };
    }
    pub fn init_boolean(value: bool) RegisterValue {
        return RegisterValue{ .type = .boolean, .boolean = value, .is_null = false };
    }
    pub fn init_blob(value: []const u8) RegisterValue {
        return RegisterValue{ .type = .blob, .blob = value, .is_null = false };
    }

    pub fn to_row_value(self: RegisterValue) storage.RowValue {
        if (self.is_null) return storage.RowValue{ .null_val = {} };
        return switch (self.type) {
            .integer => storage.RowValue{ .integer = self.integer },
            .real => storage.RowValue{ .real = self.real },
            .text => storage.RowValue{ .text = self.text },
            .blob => storage.RowValue{ .blob = self.blob },
            .boolean => storage.RowValue{ .boolean = self.boolean },
            .null => storage.RowValue{ .null_val = {} },
        };
    }

    pub fn from_row_value(val: storage.RowValue) RegisterValue {
        return switch (val) {
            .integer => |v| RegisterValue.init_integer(v),
            .real => |v| RegisterValue.init_real(v),
            .text => |v| RegisterValue.init_text(v),
            .blob => |v| RegisterValue.init_blob(v),
            .boolean => |v| RegisterValue.init_boolean(v),
            .null_val => RegisterValue.init_null(),
        };
    }
};

pub const VM = struct {
    db: *storage.Database,
    program: []const Instruction = &[_]Instruction{},
    pc: usize = 0,
    registers: [MAX_REGISTERS]RegisterValue = [_]RegisterValue{RegisterValue{}} ** MAX_REGISTERS,
    cursors: std.AutoHashMap(i32, storage.Cursor),
    tables: std.AutoHashMap(i32, *storage.Table),
    results: std.ArrayList([]RegisterValue),
    halted: bool = false,
    debug: bool = true,
    allocator: std.mem.Allocator,
    index_rowids: std.ArrayList(u32),
    index_pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, db: *storage.Database) VM {
        return VM{
            .db = db,
            .cursors = std.AutoHashMap(i32, storage.Cursor).init(allocator),
            .tables = std.AutoHashMap(i32, *storage.Table).init(allocator),
            .results = std.ArrayList([]RegisterValue){},
            .allocator = allocator,
            .index_rowids = std.ArrayList(u32){},
            .index_pos = 0,
        };
    }

    pub fn deinit(self: *VM) void {
        self.cursors.deinit();
        self.tables.deinit();
        for (self.results.items) |r| {
            self.allocator.free(r);
        }
        self.results.deinit(self.allocator);
        self.index_rowids.deinit(self.allocator);
    }

    pub fn set_debug(self: *VM, enabled: bool) void {
        self.debug = enabled;
    }

    pub fn load(self: *VM, program: []const Instruction) void {
        self.program = program;
        self.pc = 0;
        self.halted = false;
        for (self.results.items) |r| {
            self.allocator.free(r);
        }
        self.results.clearRetainingCapacity();
    }

    pub fn run(self: *VM) !void {
        while (!self.halted and self.pc < self.program.len) {
            const inst = self.program[self.pc];
            if (self.debug) {
                print("[VM] PC={d}: {s}\n", .{ self.pc, inst.op.to_string() });
            }
            try self.execute(inst);
        }
    }

    pub fn get_results(self: *VM) [][]RegisterValue {
        return self.results.items;
    }

    fn execute(self: *VM, inst: Instruction) !void {
        switch (inst.op) {
            .init => self.pc += 1,
            .halt => self.halted = true,
            .goto => self.pc = @intCast(inst.p2),
            .if_zero => {
                if (self.registers[@intCast(inst.p1)].integer == 0) {
                    self.pc = @intCast(inst.p2);
                } else {
                    self.pc += 1;
                }
            },
            .open_read, .open_write => try self.op_open_table(inst),
            .close => {
                _ = self.cursors.remove(inst.p1);
                _ = self.tables.remove(inst.p1);
                self.pc += 1;
            },
            .rewind => try self.op_rewind(inst),
            .next => try self.op_next(inst),
            .column => try self.op_column(inst),
            .row_id => try self.op_row_id(inst),
            .result_row => try self.op_result_row(inst),
            .integer => {
                self.registers[@intCast(inst.p1)] = RegisterValue.init_integer(@intCast(inst.p2));
                self.pc += 1;
            },
            .string => {
                self.registers[@intCast(inst.p1)] = RegisterValue.init_text(inst.p4);
                self.pc += 1;
            },
            .real => {
                if (inst.p5) |ptr| {
                    const float_ptr: *const f64 = @ptrCast(@alignCast(ptr));
                    self.registers[@intCast(inst.p1)] = RegisterValue.init_real(float_ptr.*);
                } else {
                    self.registers[@intCast(inst.p1)] = RegisterValue.init_real(0.0);
                }
                self.pc += 1;
            },
            .blob => {
                self.registers[@intCast(inst.p1)] = RegisterValue.init_blob(inst.p4);
                self.pc += 1;
            },
            .null => {
                self.registers[@intCast(inst.p1)] = RegisterValue.init_null();
                self.pc += 1;
            },
            .make_row => self.pc += 1,
            .insert => try self.op_insert(inst),
            .create_table => try self.op_create_table(inst),
            .create_index => try self.op_create_index(inst),
            .drop_table => try self.op_drop_table(inst),
            .drop_index => try self.op_drop_index(inst),
            .index_scan => try self.op_index_scan(inst),
            .index_next => try self.op_index_next(inst),
            .txn_begin => try self.op_txn_begin(),
            .txn_commit => try self.op_txn_commit(),
            .txn_rollback => try self.op_txn_rollback(),
            .txn_savepoint => try self.op_txn_savepoint(inst),
            .txn_release => try self.op_txn_release(inst),
            .txn_rollback_to => try self.op_txn_rollback_to(inst),
            .txn_set_isolation => try self.op_txn_set_isolation(inst),
            .eq, .ne, .lt, .le, .gt, .ge => try self.op_compare(inst),
            .delete => try self.op_delete(inst),
            else => return VmErrors.InvalidOp,
        }
    }

    fn op_open_table(self: *VM, inst: Instruction) !void {
        const table = try self.db.get_table(inst.p4);
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

        const page = try self.db.pager.get_page(cursor.page_num);
        const col_idx: usize = @intCast(inst.p2);
        const dest_reg: usize = @intCast(inst.p3);

        if (col_idx < table.schema.columns.len) {
            const val = storage.row.get_value_from_page(page, cursor.cell_num, table.schema, col_idx);
            self.registers[dest_reg] = RegisterValue.from_row_value(val);
        } else {
            self.registers[dest_reg] = RegisterValue.init_null();
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
        const result = try self.allocator.alloc(RegisterValue, num_cols);
        for (0..num_cols) |i| {
            result[i] = self.registers[start_reg + i];
        }
        try self.results.append(self.allocator, result);
        self.pc += 1;
    }

    fn validate_not_null_constraints(self: *VM, table: *storage.Table, start_reg: usize, num_cols: usize) !void {
        const schema = table.schema;
        const cols_to_check = @min(num_cols, schema.columns.len);
        for (0..cols_to_check) |i| {
            const col = schema.columns[i];
            if (col.not_null) {
                const reg = self.registers[start_reg + i];
                if (reg.type == .null or reg.is_null) {
                    return VmErrors.NullConstraintViolation;
                }
            }
        }
    }

    fn validate_type_constraints(self: *VM, table: *storage.Table, start_reg: usize, num_cols: usize) !void {
        const schema = table.schema;
        const cols_to_check = @min(num_cols, schema.columns.len);
        for (0..cols_to_check) |i| {
            const col = schema.columns[i];
            const reg = self.registers[start_reg + i];
            if (reg.type == .null or reg.is_null) continue;

            const valid = switch (col.type) {
                .Integer, .Date, .Time, .Datetime => reg.type == .integer,
                .Real => reg.type == .real or reg.type == .integer,
                .Text => reg.type == .text,
                .Blob => reg.type == .blob or reg.type == .text,
                .Boolean => reg.type == .boolean or reg.type == .integer,
            };
            if (!valid) return VmErrors.TypeMismatch;
        }
    }

    fn op_insert(self: *VM, inst: Instruction) !void {
        const table = self.tables.get(inst.p1) orelse return VmErrors.NoTable;
        const start_reg: usize = @intCast(inst.p2);
        const num_cols: usize = @intCast(inst.p3);

        try self.validate_not_null_constraints(table, start_reg, num_cols);
        try self.validate_type_constraints(table, start_reg, num_cols);

        const key: u32 = @intCast(self.registers[start_reg].integer);

        var values: [MAX_REGISTERS]storage.RowValue = undefined;
        const cols_to_use = @min(num_cols, table.schema.columns.len);
        for (0..cols_to_use) |i| {
            values[i] = self.registers[start_reg + i].to_row_value();
        }

        var row = storage.DynamicRow.init();
        try row.serialize_values(table.schema, values[0..cols_to_use]);

        if (self.debug) {
            print("[VM] op_insert: key={}, num_cols={}\n", .{ key, num_cols });
        }

        try self.db.insert_into_indexes(table.schema.table_name, key, &row);

        try self.db.transaction.save_page_for_rollback(table.btree.root_page);

        try table.insert(key, &row);

        try self.db.wal_log_page(table.btree.root_page);

        self.pc += 1;
    }

    fn op_create_table(self: *VM, inst: Instruction) !void {
        if (inst.p5) |schema_ptr| {
            const schema: *const storage.Schema = @ptrCast(@alignCast(schema_ptr));
            _ = try self.db.create_table(schema);
        }
        self.pc += 1;
    }

    fn op_create_index(self: *VM, inst: Instruction) !void {
        if (inst.p5) |index_ptr| {
            const IndexDef = @import("../storage/schema.zig").IndexDef;
            const index_def: *IndexDef = @ptrCast(@alignCast(index_ptr));
            try self.db.create_index(index_def);
        }
        self.pc += 1;
    }

    fn op_drop_table(self: *VM, inst: Instruction) !void {
        self.db.drop_table(inst.p4) catch |err| {
            if (inst.p1 == 0) return err;
        };
        self.pc += 1;
    }

    fn op_drop_index(self: *VM, inst: Instruction) !void {
        self.db.drop_index(inst.p4) catch |err| {
            if (inst.p1 == 0) return err;
        };
        self.pc += 1;
    }

    fn op_index_scan(self: *VM, inst: Instruction) !void {
        const index_btree = @import("../storage/index_btree.zig");
        const table = self.tables.get(inst.p1) orelse return VmErrors.NoTable;
        const index_name = inst.p4;
        const value_reg: usize = @intCast(inst.p3);

        const index_def = try self.db.get_index(index_name);

        const search_val = self.registers[value_reg];
        const key_hash: u32 = switch (search_val.type) {
            .integer => index_btree.hash_int(search_val.integer),
            .real => index_btree.hash_float(search_val.real),
            .text => index_btree.hash_bytes(search_val.text),
            .blob => index_btree.hash_bytes(search_val.blob),
            .boolean => if (search_val.boolean) @as(u32, 1) else @as(u32, 0),
            .null => 0,
        };

        self.index_rowids.clearRetainingCapacity();
        self.index_pos = 0;

        const idx_btree = try self.db.get_index_btree(index_name);
        try idx_btree.find(key_hash, self.allocator, &self.index_rowids);

        if (self.debug) {
            print("[VM] INDEX_SCAN on '{s}': hash={}, found {} matches\n", .{ index_name, key_hash, self.index_rowids.items.len });
        }

        if (self.index_rowids.items.len == 0) {
            self.pc = @intCast(inst.p2);
            return;
        }

        const first_rowid = self.index_rowids.items[0];
        const cursor = try table.search(first_rowid);
        try self.cursors.put(inst.p1, cursor);

        _ = index_def;
        self.pc += 1;
    }

    fn op_index_next(self: *VM, inst: Instruction) !void {
        const table = self.tables.get(inst.p1) orelse return VmErrors.NoTable;

        self.index_pos += 1;

        if (self.index_pos >= self.index_rowids.items.len) {
            self.pc += 1;
            return;
        }

        const rowid = self.index_rowids.items[self.index_pos];
        const cursor = try table.search(rowid);
        try self.cursors.put(inst.p1, cursor);

        self.pc = @intCast(inst.p2);
    }

    fn op_txn_begin(self: *VM) !void {
        try self.db.transaction.begin();
        self.pc += 1;
    }

    fn op_txn_commit(self: *VM) !void {
        try self.db.wal_commit();
        try self.db.transaction.commit();
        try self.db.pager.sync();
        self.pc += 1;
    }

    fn op_txn_rollback(self: *VM) !void {
        try self.db.transaction.rollback();
        self.pc += 1;
    }

    fn op_txn_savepoint(self: *VM, inst: Instruction) !void {
        try self.db.transaction.savepoint(inst.p4);
        self.pc += 1;
    }

    fn op_txn_release(self: *VM, inst: Instruction) !void {
        try self.db.transaction.release_savepoint(inst.p4);
        self.pc += 1;
    }

    fn op_txn_rollback_to(self: *VM, inst: Instruction) !void {
        try self.db.transaction.rollback_to_savepoint(inst.p4);
        self.pc += 1;
    }

    fn op_txn_set_isolation(self: *VM, inst: Instruction) !void {
        const level: storage.IsolationLevel = switch (inst.p1) {
            0 => .read_uncommitted,
            1 => .read_committed,
            2 => .repeatable_read,
            3 => .serializable,
            else => .read_committed,
        };
        try self.db.transaction.set_isolation_level(level);
        self.pc += 1;
    }

    fn op_delete(self: *VM, inst: Instruction) !void {
        const cursor = self.cursors.getPtr(inst.p1) orelse return VmErrors.NoCursor;
        const table = self.tables.get(inst.p1) orelse return VmErrors.NoTable;
        const page_num = cursor.page_number();
        const page = try self.db.pager.get_page(page_num);
        const num_cells = storage.node.get_num_cells(page);
        const cell_to_delete = cursor.cell_number();

        const rowid = storage.row.get_leaf_key(page, cell_to_delete);
        const row = storage.row.get_leaf_row(page, cell_to_delete, table.schema);

        self.db.delete_from_indexes(table.schema.table_name, rowid, &row) catch {};

        try self.db.transaction.save_page_for_rollback(page_num);

        if (cell_to_delete < num_cells - 1) {
            var i: u32 = cell_to_delete;
            while (i < num_cells - 1) : (i += 1) {
                const src_offset = storage.row.leaf_cell_offset(i + 1);
                const dest_offset = storage.row.leaf_cell_offset(i);
                @memcpy(
                    page.data[dest_offset .. dest_offset + storage.row.LEAF_CELL_SIZE],
                    page.data[src_offset .. src_offset + storage.row.LEAF_CELL_SIZE],
                );
            }
        }
        storage.node.set_num_cells(page, num_cells - 1);
        self.db.pager.mark_dirty(page_num);

        try self.db.wal_log_page(page_num);

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
        }
        self.registers[dest_reg] = RegisterValue.init_integer(if (result) 1 else 0);
        self.pc += 1;
    }
};

test "vm initialization" {
    const allocator = std.testing.allocator;
    var pager = try storage.Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try storage.Database.init(allocator, &pager);
    defer db.close();

    var vm = VM.init(allocator, &db);
    defer vm.deinit();

    try std.testing.expect(!vm.halted);
    try std.testing.expectEqual(@as(usize, 0), vm.pc);
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

    try std.testing.expectEqual(@as(i64, 42), vm.registers[0].integer);
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

    try std.testing.expectEqual(@as(i64, 1), vm.registers[2].integer);
}

test "vm insert and select with dynamic row" {
    const allocator = std.testing.allocator;
    var pager = try storage.Pager.init(allocator, ":memory:");
    defer pager.deinit();

    var db = try storage.Database.init(allocator, &pager);
    defer db.close();

    var columns = try allocator.alloc(storage.Column, 2);
    columns[0] = .{ .name = try allocator.dupe(u8, "id"), .type = .Integer, .primary_key = true, .not_null = true };
    columns[1] = .{ .name = try allocator.dupe(u8, "name"), .type = .Text, .primary_key = false, .not_null = true };

    const schema_ptr = try allocator.create(storage.Schema);
    schema_ptr.* = storage.Schema.init(try allocator.dupe(u8, "test_table"), columns);
    _ = try db.create_table(schema_ptr);

    var vm = VM.init(allocator, &db);
    vm.set_debug(false);
    defer vm.deinit();

    vm.registers[0] = RegisterValue.init_integer(1);
    vm.registers[1] = RegisterValue.init_text("alice");

    const table = try db.get_table("test_table");
    try vm.tables.put(0, table);

    var row = storage.DynamicRow.init();
    const values = [_]storage.RowValue{
        storage.RowValue{ .integer = 1 },
        storage.RowValue{ .text = "alice" },
    };
    try row.serialize_values(schema_ptr, &values);
    try table.insert(1, &row);

    var cursor = try table.select_all();
    try std.testing.expect(!cursor.is_end());

    const retrieved = try cursor.value(schema_ptr);
    const id_val = retrieved.get_value(schema_ptr, 0);
    try std.testing.expectEqual(@as(i64, 1), id_val.integer);

    const name_val = retrieved.get_value(schema_ptr, 1);
    try std.testing.expectEqualStrings("alice", name_val.text);
}
