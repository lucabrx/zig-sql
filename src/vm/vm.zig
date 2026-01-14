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

fn match_like(text: []const u8, pattern: []const u8) bool {
    var ti: usize = 0;
    var pi: usize = 0;
    var star_idx: ?usize = null;
    var match_idx: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == '_' or pattern[pi] == text[ti])) {
            ti += 1;
            pi += 1;
        } else if (pi < pattern.len and pattern[pi] == '%') {
            star_idx = pi;
            match_idx = ti;
            pi += 1;
        } else if (star_idx != null) {
            pi = star_idx.? + 1;
            match_idx += 1;
            ti = match_idx;
        } else {
            return false;
        }
    }

    while (pi < pattern.len and pattern[pi] == '%') {
        pi += 1;
    }

    return pi == pattern.len;
}

const AggState = struct {
    func: []const u8 = "",
    count: i64 = 0,
    sum: f64 = 0,
    min: ?RegisterValue = null,
    max: ?RegisterValue = null,
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
    seen_rows: std.AutoHashMap(u64, void),
    agg_groups: std.AutoHashMap(u64, []AggState),
    num_aggs: usize = 0,
    num_group_cols: usize = 0,
    group_keys: std.AutoHashMap(u64, []RegisterValue),

    pub fn init(allocator: std.mem.Allocator, db: *storage.Database) VM {
        return VM{
            .db = db,
            .cursors = std.AutoHashMap(i32, storage.Cursor).init(allocator),
            .tables = std.AutoHashMap(i32, *storage.Table).init(allocator),
            .results = std.ArrayList([]RegisterValue){},
            .allocator = allocator,
            .index_rowids = std.ArrayList(u32){},
            .index_pos = 0,
            .seen_rows = std.AutoHashMap(u64, void).init(allocator),
            .agg_groups = std.AutoHashMap(u64, []AggState).init(allocator),
            .num_aggs = 0,
            .num_group_cols = 0,
            .group_keys = std.AutoHashMap(u64, []RegisterValue).init(allocator),
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
        self.seen_rows.deinit();
        var agg_iter = self.agg_groups.valueIterator();
        while (agg_iter.next()) |states| {
            self.allocator.free(states.*);
        }
        self.agg_groups.deinit();
        var key_iter = self.group_keys.valueIterator();
        while (key_iter.next()) |keys| {
            self.allocator.free(keys.*);
        }
        self.group_keys.deinit();
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
        self.seen_rows.clearRetainingCapacity();
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

    pub fn run_subquery(self: *VM) anyerror!void {
        while (!self.halted and self.pc < self.program.len) {
            const inst = self.program[self.pc];
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
            .@"and", .@"or" => try self.op_logical(inst),
            .not => self.op_not(inst),
            .add, .sub, .mul, .div => self.op_arithmetic(inst),
            .subquery => try self.op_subquery(inst),
            .delete => try self.op_delete(inst),
            .agg_init => self.op_agg_init(inst),
            .agg_step => try self.op_agg_step(inst),
            .agg_final => try self.op_agg_final(inst),
            .between => self.op_between(inst),
            .in_list => try self.op_in_list(inst),
            .in_subquery => try self.op_in_subquery(inst),
            .like => self.op_like(inst),
            .is_null => self.op_is_null(inst),
            .case_expr => try self.op_case(inst),
            .sort_results => self.op_sort_results(inst),
            .limit_results => self.op_limit_results(inst),
            .union_start => self.op_union_start(inst),
            .union_merge => self.op_union_merge(inst),
            .insert_select => try self.op_insert_select(inst),
            .alter_add_column => try self.op_alter_add_column(inst),
            .alter_drop_column => try self.op_alter_drop_column(inst),
            .alter_rename_table => try self.op_alter_rename_table(inst),
            .alter_rename_column => try self.op_alter_rename_column(inst),
            .func_call => try self.op_func_call(inst),
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
        const is_distinct = inst.p3 != 0;

        if (is_distinct) {
            const row_hash = self.hash_row(start_reg, num_cols);
            const gop = self.seen_rows.getOrPut(row_hash) catch return;
            if (gop.found_existing) {
                self.pc += 1;
                return;
            }
        }

        const result = try self.allocator.alloc(RegisterValue, num_cols);
        for (0..num_cols) |i| {
            result[i] = self.registers[start_reg + i];
        }
        try self.results.append(self.allocator, result);
        self.pc += 1;
    }

    fn hash_row(self: *VM, start_reg: usize, num_cols: usize) u64 {
        var hasher = std.hash.Wyhash.init(0);
        for (0..num_cols) |i| {
            const reg = self.registers[start_reg + i];
            hasher.update(std.mem.asBytes(&reg.type));
            switch (reg.type) {
                .integer => hasher.update(std.mem.asBytes(&reg.integer)),
                .real => hasher.update(std.mem.asBytes(&reg.real)),
                .text => hasher.update(reg.text),
                .blob => hasher.update(reg.blob),
                .boolean => hasher.update(std.mem.asBytes(&reg.boolean)),
                .null => hasher.update(&[_]u8{0}),
            }
        }
        return hasher.final();
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

    fn op_logical(self: *VM, inst: Instruction) !void {
        const left = self.registers[@intCast(inst.p1)];
        const right = self.registers[@intCast(inst.p2)];
        const dest_reg: usize = @intCast(inst.p3);

        const left_bool = left.integer != 0;
        const right_bool = right.integer != 0;

        const result: bool = switch (inst.op) {
            .@"and" => left_bool and right_bool,
            .@"or" => left_bool or right_bool,
            else => false,
        };

        self.registers[dest_reg] = RegisterValue.init_integer(if (result) 1 else 0);
        self.pc += 1;
    }

    fn op_not(self: *VM, inst: Instruction) void {
        const src_reg: usize = @intCast(inst.p1);
        const dest_reg: usize = @intCast(inst.p2);
        const val = self.registers[src_reg];
        const result = if (val.type == .integer) val.integer == 0 else true;
        self.registers[dest_reg] = RegisterValue.init_integer(if (result) 1 else 0);
        self.pc += 1;
    }

    fn op_arithmetic(self: *VM, inst: Instruction) void {
        const left = self.registers[@intCast(inst.p1)];
        const right = self.registers[@intCast(inst.p2)];
        const dest_reg: usize = @intCast(inst.p3);

        if (left.type == .integer and right.type == .integer) {
            const result: i64 = switch (inst.op) {
                .add => left.integer + right.integer,
                .sub => left.integer - right.integer,
                .mul => left.integer * right.integer,
                .div => if (right.integer != 0) @divTrunc(left.integer, right.integer) else 0,
                else => 0,
            };
            self.registers[dest_reg] = RegisterValue.init_integer(result);
        } else if ((left.type == .real or left.type == .integer) and (right.type == .real or right.type == .integer)) {
            const l: f64 = if (left.type == .real) left.real else @floatFromInt(left.integer);
            const r: f64 = if (right.type == .real) right.real else @floatFromInt(right.integer);
            const result: f64 = switch (inst.op) {
                .add => l + r,
                .sub => l - r,
                .mul => l * r,
                .div => if (r != 0) l / r else 0,
                else => 0,
            };
            self.registers[dest_reg] = RegisterValue.init_real(result);
        } else {
            self.registers[dest_reg] = RegisterValue.init_null();
        }
        self.pc += 1;
    }

    fn op_subquery(self: *VM, inst: Instruction) !void {
        const dest_reg: usize = @intCast(inst.p1);

        if (inst.p5) |ptr| {
            const ast = @import("../parser/ast.zig");
            const Compiler = @import("../compiler/compiler.zig").Compiler;

            const subq: *ast.SubqueryExpression = @ptrCast(@alignCast(ptr));

            var sub_compiler = Compiler.init(self.allocator, self.allocator, self.db);
            defer sub_compiler.deinit();

            const sub_instructions = sub_compiler.compile(ast.Statement{ .select_stmt = subq.select }) catch {
                self.registers[dest_reg] = RegisterValue.init_null();
                self.pc += 1;
                return;
            };

            var sub_vm = VM.init(self.allocator, self.db);
            sub_vm.set_debug(false);
            defer sub_vm.deinit();

            sub_vm.load(sub_instructions);
            if (sub_vm.run_subquery()) {
                const sub_results = sub_vm.get_results();
                if (sub_results.len > 0 and sub_results[0].len > 0) {
                    self.registers[dest_reg] = sub_results[0][0];
                } else {
                    self.registers[dest_reg] = RegisterValue.init_null();
                }
            } else |_| {
                self.registers[dest_reg] = RegisterValue.init_null();
            }
        } else {
            self.registers[dest_reg] = RegisterValue.init_null();
        }

        self.pc += 1;
    }

    fn op_between(self: *VM, inst: Instruction) void {
        const expr_reg: usize = @intCast(inst.p1);
        const low_reg: usize = @intCast(inst.p2);
        const high_reg: usize = @intCast(inst.p3);

        const val = self.registers[expr_reg];
        const low = self.registers[low_reg];
        const high = self.registers[high_reg];

        var result: bool = false;
        if (val.type == .integer and low.type == .integer and high.type == .integer) {
            result = val.integer >= low.integer and val.integer <= high.integer;
        } else if (val.type == .text and low.type == .text and high.type == .text) {
            const cmp_low = std.mem.order(u8, val.text, low.text);
            const cmp_high = std.mem.order(u8, val.text, high.text);
            result = (cmp_low == .gt or cmp_low == .eq) and (cmp_high == .lt or cmp_high == .eq);
        }

        self.registers[expr_reg] = RegisterValue.init_integer(if (result) 1 else 0);
        self.pc += 1;
    }

    fn op_in_list(self: *VM, inst: Instruction) !void {
        const expr_reg: usize = @intCast(inst.p1);
        const dest_reg: usize = @intCast(inst.p2);
        const negated = inst.p3 != 0;

        const val = self.registers[expr_reg];
        var found = false;

        if (inst.p5) |ptr| {
            const ast = @import("../parser/ast.zig");
            const in_list: *ast.InListExpression = @ptrCast(@alignCast(ptr));

            for (in_list.list) |item| {
                const item_val = self.eval_const_expr(item);
                if (self.values_equal(val, item_val)) {
                    found = true;
                    break;
                }
            }
        }

        const result = if (negated) !found else found;
        self.registers[dest_reg] = RegisterValue.init_integer(if (result) 1 else 0);
        self.pc += 1;
    }

    fn op_in_subquery(self: *VM, inst: Instruction) !void {
        const expr_reg: usize = @intCast(inst.p1);
        const dest_reg: usize = @intCast(inst.p2);
        const negated = inst.p3 != 0;

        const val = self.registers[expr_reg];
        var found = false;

        if (inst.p5) |ptr| {
            const ast = @import("../parser/ast.zig");
            const Compiler = @import("../compiler/compiler.zig").Compiler;
            const in_sub: *ast.InSubqueryExpression = @ptrCast(@alignCast(ptr));

            var sub_compiler = Compiler.init(self.allocator, self.allocator, self.db);
            defer sub_compiler.deinit();

            const sub_instructions = sub_compiler.compile(ast.Statement{ .select_stmt = in_sub.subquery }) catch {
                self.registers[dest_reg] = RegisterValue.init_integer(0);
                self.pc += 1;
                return;
            };

            var sub_vm = VM.init(self.allocator, self.db);
            sub_vm.set_debug(false);
            defer sub_vm.deinit();

            sub_vm.load(sub_instructions);
            if (sub_vm.run_subquery()) {
                const sub_results = sub_vm.get_results();
                for (sub_results) |row| {
                    if (row.len > 0 and self.values_equal(val, row[0])) {
                        found = true;
                        break;
                    }
                }
            } else |_| {}
        }

        const result = if (negated) !found else found;
        self.registers[dest_reg] = RegisterValue.init_integer(if (result) 1 else 0);
        self.pc += 1;
    }

    fn op_like(self: *VM, inst: Instruction) void {
        const expr_reg: usize = @intCast(inst.p1);
        const pattern_reg: usize = @intCast(inst.p2);
        const dest_reg: usize = @intCast(inst.p3);
        const negated = inst.p4.len > 0;

        const val = self.registers[expr_reg];
        const pattern = self.registers[pattern_reg];

        var result = false;
        if (val.type == .text and pattern.type == .text) {
            result = match_like(val.text, pattern.text);
        }

        if (negated) result = !result;
        self.registers[dest_reg] = RegisterValue.init_integer(if (result) 1 else 0);
        self.pc += 1;
    }

    fn op_is_null(self: *VM, inst: Instruction) void {
        const expr_reg: usize = @intCast(inst.p1);
        const dest_reg: usize = @intCast(inst.p2);
        const negated = inst.p3 != 0;

        const val = self.registers[expr_reg];
        var result = val.is_null or val.type == .null;

        if (negated) result = !result;
        self.registers[dest_reg] = RegisterValue.init_integer(if (result) 1 else 0);
        self.pc += 1;
    }

    fn op_case(self: *VM, inst: Instruction) !void {
        const dest_reg: usize = @intCast(inst.p1);

        if (inst.p5) |ptr| {
            const ast = @import("../parser/ast.zig");
            const case_expr: *ast.CaseExpression = @ptrCast(@alignCast(ptr));

            var operand_val: ?RegisterValue = null;
            if (case_expr.operand) |op| {
                operand_val = self.eval_const_expr(op);
            }

            for (case_expr.when_clauses) |when| {
                const cond_val = self.eval_const_expr(when.condition);
                var matches = false;

                if (operand_val) |op_val| {
                    matches = self.values_equal(op_val, cond_val);
                } else {
                    matches = cond_val.type == .integer and cond_val.integer != 0;
                    if (cond_val.type == .boolean) matches = cond_val.boolean;
                }

                if (matches) {
                    self.registers[dest_reg] = self.eval_const_expr(when.result);
                    self.pc += 1;
                    return;
                }
            }

            if (case_expr.else_result) |else_expr| {
                self.registers[dest_reg] = self.eval_const_expr(else_expr);
            } else {
                self.registers[dest_reg] = RegisterValue.init_null();
            }
        } else {
            self.registers[dest_reg] = RegisterValue.init_null();
        }

        self.pc += 1;
    }

    fn op_sort_results(self: *VM, inst: Instruction) void {
        const col_idx: usize = @intCast(inst.p1);
        const desc = inst.p2 != 0;

        const items = self.results.items;
        if (items.len <= 1) {
            self.pc += 1;
            return;
        }

        const Context = struct {
            col: usize,
            descending: bool,

            pub fn lessThan(ctx: @This(), a: []RegisterValue, b: []RegisterValue) bool {
                if (ctx.col >= a.len or ctx.col >= b.len) return false;
                const va = a[ctx.col];
                const vb = b[ctx.col];

                const result = switch (va.type) {
                    .integer => if (vb.type == .integer) va.integer < vb.integer else false,
                    .real => if (vb.type == .real) va.real < vb.real else false,
                    .text => if (vb.type == .text) std.mem.order(u8, va.text, vb.text) == .lt else false,
                    else => false,
                };
                return if (ctx.descending) !result else result;
            }
        };

        std.mem.sort([]RegisterValue, items, Context{ .col = col_idx, .descending = desc }, Context.lessThan);
        self.pc += 1;
    }

    fn op_limit_results(self: *VM, inst: Instruction) void {
        const limit: usize = @intCast(inst.p1);
        const offset: usize = @intCast(inst.p2);

        if (offset > 0 and offset < self.results.items.len) {
            for (0..offset) |i| {
                self.allocator.free(self.results.items[i]);
            }
            std.mem.copyForwards([]RegisterValue, self.results.items[0..], self.results.items[offset..]);
            self.results.shrinkRetainingCapacity(self.results.items.len - offset);
        } else if (offset >= self.results.items.len) {
            for (self.results.items) |r| {
                self.allocator.free(r);
            }
            self.results.clearRetainingCapacity();
        }

        if (limit > 0 and limit < self.results.items.len) {
            for (self.results.items[limit..]) |r| {
                self.allocator.free(r);
            }
            self.results.shrinkRetainingCapacity(limit);
        }

        self.pc += 1;
    }

    fn op_union_start(self: *VM, inst: Instruction) void {
        _ = inst;
        self.seen_rows.clearRetainingCapacity();
        self.pc += 1;
    }

    fn op_union_merge(self: *VM, inst: Instruction) void {
        const is_all = inst.p1 != 0;

        if (!is_all) {
            var i: usize = 0;
            while (i < self.results.items.len) {
                const row = self.results.items[i];
                const row_hash = self.hash_result_row(row);
                const gop = self.seen_rows.getOrPut(row_hash) catch {
                    i += 1;
                    continue;
                };
                if (gop.found_existing) {
                    self.allocator.free(row);
                    _ = self.results.orderedRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        self.pc += 1;
    }

    fn hash_result_row(self: *VM, row: []RegisterValue) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        for (row) |val| {
            hasher.update(std.mem.asBytes(&val.type));
            switch (val.type) {
                .integer => hasher.update(std.mem.asBytes(&val.integer)),
                .real => hasher.update(std.mem.asBytes(&val.real)),
                .text => hasher.update(val.text),
                .blob => hasher.update(val.blob),
                .boolean => hasher.update(std.mem.asBytes(&val.boolean)),
                .null => hasher.update(&[_]u8{0}),
            }
        }
        return hasher.final();
    }

    fn op_insert_select(self: *VM, inst: Instruction) !void {
        const table = self.tables.get(inst.p1) orelse return VmErrors.NoTable;
        const num_cols: usize = @intCast(inst.p2);

        if (inst.p5) |ptr| {
            const ast = @import("../parser/ast.zig");
            const Compiler = @import("../compiler/compiler.zig").Compiler;

            const select_stmt: *ast.SelectStatement = @ptrCast(@alignCast(ptr));

            var sub_compiler = Compiler.init(self.allocator, self.allocator, self.db);
            defer sub_compiler.deinit();

            const sub_instructions = sub_compiler.compile(ast.Statement{ .select_stmt = select_stmt.* }) catch {
                self.pc += 1;
                return;
            };

            var sub_vm = VM.init(self.allocator, self.db);
            sub_vm.set_debug(false);
            defer sub_vm.deinit();

            sub_vm.load(sub_instructions);
            if (sub_vm.run_subquery()) {
                const sub_results = sub_vm.get_results();

                for (sub_results) |row| {
                    var values: [MAX_REGISTERS]storage.RowValue = undefined;
                    const cols_to_use = @min(row.len, num_cols);

                    for (0..cols_to_use) |i| {
                        values[i] = row[i].to_row_value();
                    }
                    for (cols_to_use..num_cols) |i| {
                        values[i] = storage.RowValue{ .null_val = {} };
                    }

                    const key: u32 = switch (values[0]) {
                        .integer => |v| @intCast(v),
                        else => 0,
                    };

                    var dyn_row = storage.DynamicRow.init();
                    dyn_row.serialize_values(table.schema, values[0..num_cols]) catch continue;

                    self.db.insert_into_indexes(table.schema.table_name, key, &dyn_row) catch {};
                    self.db.transaction.save_page_for_rollback(table.btree.root_page) catch {};
                    table.insert(key, &dyn_row) catch continue;
                    self.db.wal_log_page(table.btree.root_page) catch {};
                }
            } else |_| {}
        }

        self.pc += 1;
    }

    fn op_alter_add_column(self: *VM, inst: Instruction) !void {
        const table_name = inst.p4;
        if (inst.p5) |ptr| {
            const col: *storage.Column = @ptrCast(@alignCast(ptr));
            self.db.alter_add_column(table_name, col.*) catch {};
        }
        self.pc += 1;
    }

    fn op_alter_drop_column(self: *VM, inst: Instruction) !void {
        const table_name = inst.p4;
        if (inst.p5) |ptr| {
            const col_name_ptr: [*]const u8 = @ptrCast(ptr);
            var len: usize = 0;
            while (col_name_ptr[len] != 0 and len < 256) : (len += 1) {}
            const col_name = col_name_ptr[0..len];
            self.db.alter_drop_column(table_name, col_name) catch {};
        }
        self.pc += 1;
    }

    fn op_alter_rename_table(self: *VM, inst: Instruction) !void {
        const old_name = inst.p4;
        if (inst.p5) |ptr| {
            const new_name_ptr: [*]const u8 = @ptrCast(ptr);
            var len: usize = 0;
            while (new_name_ptr[len] != 0 and len < 256) : (len += 1) {}
            const new_name = new_name_ptr[0..len];
            self.db.alter_rename_table(old_name, new_name) catch {};
        }
        self.pc += 1;
    }

    fn op_alter_rename_column(self: *VM, inst: Instruction) !void {
        const table_name = inst.p4;
        if (inst.p5) |ptr| {
            const names: *[2][]const u8 = @ptrCast(@alignCast(ptr));
            self.db.alter_rename_column(table_name, names[0], names[1]) catch {};
        }
        self.pc += 1;
    }

    fn eval_const_expr(self: *VM, expr: @import("../parser/ast.zig").Expression) RegisterValue {
        _ = self;
        switch (expr) {
            .integer_literal => |lit| return RegisterValue.init_integer(lit.value),
            .string_literal => |lit| return RegisterValue.init_text(lit.value),
            .null_literal => return RegisterValue.init_null(),
            .boolean_literal => |lit| return RegisterValue.init_boolean(lit.value),
            else => return RegisterValue.init_null(),
        }
    }

    fn values_equal(self: *VM, a: RegisterValue, b: RegisterValue) bool {
        _ = self;
        if (a.type != b.type) return false;
        return switch (a.type) {
            .integer => a.integer == b.integer,
            .text => std.mem.eql(u8, a.text, b.text),
            .real => a.real == b.real,
            .boolean => a.boolean == b.boolean,
            .null => true,
            else => false,
        };
    }

    fn op_agg_init(self: *VM, inst: Instruction) void {
        self.num_aggs = @intCast(inst.p1);
        self.num_group_cols = @intCast(inst.p2);
        self.agg_groups.clearRetainingCapacity();
        var key_iter = self.group_keys.valueIterator();
        while (key_iter.next()) |keys| {
            self.allocator.free(keys.*);
        }
        self.group_keys.clearRetainingCapacity();
        self.pc += 1;
    }

    fn op_agg_step(self: *VM, inst: Instruction) !void {
        const agg_idx: usize = @intCast(inst.p1);
        const val_reg: usize = @intCast(inst.p2);
        const group_key_start: usize = @intCast(inst.p3);

        var hasher = std.hash.Wyhash.init(0);
        for (0..self.num_group_cols) |i| {
            const reg = self.registers[group_key_start + i];
            hasher.update(std.mem.asBytes(&reg.type));
            switch (reg.type) {
                .integer => hasher.update(std.mem.asBytes(&reg.integer)),
                .text => hasher.update(reg.text),
                else => {},
            }
        }
        const group_hash = hasher.final();

        const gop = try self.agg_groups.getOrPut(group_hash);
        if (!gop.found_existing) {
            const states = try self.allocator.alloc(AggState, self.num_aggs);
            for (states) |*s| {
                s.* = AggState{};
            }
            gop.value_ptr.* = states;

            const keys = try self.allocator.alloc(RegisterValue, self.num_group_cols);
            for (0..self.num_group_cols) |i| {
                keys[i] = self.registers[group_key_start + i];
            }
            try self.group_keys.put(group_hash, keys);
        }

        const states = gop.value_ptr.*;
        const val = self.registers[val_reg];
        const func_name = inst.p4;

        states[agg_idx].func = func_name;

        if (std.mem.eql(u8, func_name, "count")) {
            states[agg_idx].count += 1;
        } else if (std.mem.eql(u8, func_name, "sum")) {
            if (val.type == .integer) {
                states[agg_idx].sum += @floatFromInt(val.integer);
            } else if (val.type == .real) {
                states[agg_idx].sum += val.real;
            }
            states[agg_idx].count += 1;
        } else if (std.mem.eql(u8, func_name, "avg")) {
            if (val.type == .integer) {
                states[agg_idx].sum += @floatFromInt(val.integer);
            } else if (val.type == .real) {
                states[agg_idx].sum += val.real;
            }
            states[agg_idx].count += 1;
        } else if (std.mem.eql(u8, func_name, "min")) {
            if (states[agg_idx].min == null) {
                states[agg_idx].min = val;
            } else if (val.type == .integer and states[agg_idx].min.?.type == .integer) {
                if (val.integer < states[agg_idx].min.?.integer) {
                    states[agg_idx].min = val;
                }
            }
        } else if (std.mem.eql(u8, func_name, "max")) {
            if (states[agg_idx].max == null) {
                states[agg_idx].max = val;
            } else if (val.type == .integer and states[agg_idx].max.?.type == .integer) {
                if (val.integer > states[agg_idx].max.?.integer) {
                    states[agg_idx].max = val;
                }
            }
        }

        self.pc += 1;
    }

    fn op_agg_final(self: *VM, inst: Instruction) !void {
        const num_group_cols: usize = @intCast(inst.p2);
        const having_expr: ?*const @import("../parser/ast.zig").Expression = if (inst.p5) |ptr|
            @ptrCast(@alignCast(ptr))
        else
            null;

        var iter = self.agg_groups.iterator();
        while (iter.next()) |entry| {
            const group_hash = entry.key_ptr.*;
            const states = entry.value_ptr.*;
            const group_keys = self.group_keys.get(group_hash) orelse continue;

            const num_cols = num_group_cols + self.num_aggs;
            const result = try self.allocator.alloc(RegisterValue, num_cols);

            for (0..num_group_cols) |i| {
                result[i] = group_keys[i];
            }

            for (states, 0..) |state, i| {
                const col_idx = num_group_cols + i;
                if (std.mem.eql(u8, state.func, "min")) {
                    result[col_idx] = state.min orelse RegisterValue.init_null();
                } else if (std.mem.eql(u8, state.func, "max")) {
                    result[col_idx] = state.max orelse RegisterValue.init_null();
                } else if (std.mem.eql(u8, state.func, "avg")) {
                    if (state.count > 0) {
                        const avg = state.sum / @as(f64, @floatFromInt(state.count));
                        result[col_idx] = RegisterValue.init_real(avg);
                    } else {
                        result[col_idx] = RegisterValue.init_null();
                    }
                } else if (std.mem.eql(u8, state.func, "sum")) {
                    if (state.sum == @trunc(state.sum)) {
                        result[col_idx] = RegisterValue.init_integer(@intFromFloat(state.sum));
                    } else {
                        result[col_idx] = RegisterValue.init_real(state.sum);
                    }
                } else {
                    result[col_idx] = RegisterValue.init_integer(state.count);
                }
            }

            if (having_expr) |expr| {
                const passes = self.eval_having(expr.*, result, states);
                if (!passes) {
                    self.allocator.free(result);
                    continue;
                }
            }

            try self.results.append(self.allocator, result);
        }

        if (self.agg_groups.count() == 0 and self.num_group_cols == 0) {
            const result = try self.allocator.alloc(RegisterValue, self.num_aggs);
            for (0..self.num_aggs) |i| {
                result[i] = RegisterValue.init_integer(0);
            }
            try self.results.append(self.allocator, result);
        }

        self.pc += 1;
    }

    fn eval_having(self: *VM, expr: @import("../parser/ast.zig").Expression, result: []RegisterValue, states: []AggState) bool {
        switch (expr) {
            .binary_expression => |bin| {
                const left_val = self.eval_having_value(bin.left, result, states);
                const right_val = self.eval_having_value(bin.right, result, states);

                if (std.mem.eql(u8, bin.operator, ">")) {
                    return left_val > right_val;
                } else if (std.mem.eql(u8, bin.operator, ">=")) {
                    return left_val >= right_val;
                } else if (std.mem.eql(u8, bin.operator, "<")) {
                    return left_val < right_val;
                } else if (std.mem.eql(u8, bin.operator, "<=")) {
                    return left_val <= right_val;
                } else if (std.mem.eql(u8, bin.operator, "=") or std.mem.eql(u8, bin.operator, "==")) {
                    return left_val == right_val;
                } else if (std.mem.eql(u8, bin.operator, "!=") or std.mem.eql(u8, bin.operator, "<>")) {
                    return left_val != right_val;
                } else if (std.mem.eql(u8, bin.operator, "AND")) {
                    return left_val != 0 and right_val != 0;
                } else if (std.mem.eql(u8, bin.operator, "OR")) {
                    return left_val != 0 or right_val != 0;
                }
                return true;
            },
            .aggregate => |agg| {
                for (states) |state| {
                    if (state.func.len > 0) {
                        const func_match = switch (agg.function) {
                            .count => std.mem.eql(u8, state.func, "count"),
                            .sum => std.mem.eql(u8, state.func, "sum"),
                            .avg => std.mem.eql(u8, state.func, "avg"),
                            .min => std.mem.eql(u8, state.func, "min"),
                            .max => std.mem.eql(u8, state.func, "max"),
                        };
                        if (func_match) {
                            return state.count > 0;
                        }
                    }
                }
                return true;
            },
            else => return true,
        }
    }

    fn eval_having_value(self: *VM, expr: @import("../parser/ast.zig").Expression, result: []RegisterValue, states: []AggState) i64 {
        _ = self;
        _ = result;
        const ast = @import("../parser/ast.zig");
        _ = ast; // autofix
        switch (expr) {
            .integer_literal => |lit| return lit.value,
            .aggregate => |agg| {
                for (states) |state| {
                    const func_match = switch (agg.function) {
                        .count => std.mem.eql(u8, state.func, "count"),
                        .sum => std.mem.eql(u8, state.func, "sum"),
                        .avg => std.mem.eql(u8, state.func, "avg"),
                        .min => std.mem.eql(u8, state.func, "min"),
                        .max => std.mem.eql(u8, state.func, "max"),
                    };
                    if (func_match) {
                        if (std.mem.eql(u8, state.func, "count")) {
                            return state.count;
                        } else if (std.mem.eql(u8, state.func, "sum")) {
                            return @intFromFloat(state.sum);
                        } else if (std.mem.eql(u8, state.func, "avg") and state.count > 0) {
                            return @intFromFloat(state.sum / @as(f64, @floatFromInt(state.count)));
                        } else if (std.mem.eql(u8, state.func, "min")) {
                            if (state.min) |m| return m.integer;
                        } else if (std.mem.eql(u8, state.func, "max")) {
                            if (state.max) |m| return m.integer;
                        }
                    }
                }
                return 0;
            },
            else => return 0,
        }
    }

    fn op_func_call(self: *VM, inst: Instruction) !void {
        const dest_reg: usize = @intCast(inst.p1);
        const arg_start: usize = @intCast(inst.p2);
        const arg_count: usize = @intCast(inst.p3);
        const func_name = inst.p4;

        var upper_buf: [32]u8 = undefined;
        const len = @min(func_name.len, upper_buf.len);
        const upper_name = std.ascii.upperString(upper_buf[0..len], func_name[0..len]);

        if (std.mem.eql(u8, upper_name, "UPPER")) {
            if (arg_count >= 1) {
                const arg = self.registers[arg_start];
                if (arg.type == .text) {
                    const result = try self.allocator.alloc(u8, arg.text.len);
                    _ = std.ascii.upperString(result, arg.text);
                    self.registers[dest_reg] = RegisterValue.init_text(result);
                } else {
                    self.registers[dest_reg] = RegisterValue.init_null();
                }
            }
        } else if (std.mem.eql(u8, upper_name, "LOWER")) {
            if (arg_count >= 1) {
                const arg = self.registers[arg_start];
                if (arg.type == .text) {
                    const result = try self.allocator.alloc(u8, arg.text.len);
                    _ = std.ascii.lowerString(result, arg.text);
                    self.registers[dest_reg] = RegisterValue.init_text(result);
                } else {
                    self.registers[dest_reg] = RegisterValue.init_null();
                }
            }
        } else if (std.mem.eql(u8, upper_name, "LENGTH")) {
            if (arg_count >= 1) {
                const arg = self.registers[arg_start];
                if (arg.type == .text) {
                    self.registers[dest_reg] = RegisterValue.init_integer(@intCast(arg.text.len));
                } else {
                    self.registers[dest_reg] = RegisterValue.init_null();
                }
            }
        } else if (std.mem.eql(u8, upper_name, "SUBSTR")) {
            if (arg_count >= 2) {
                const str_arg = self.registers[arg_start];
                const start_arg = self.registers[arg_start + 1];
                if (str_arg.type == .text and start_arg.type == .integer) {
                    const start: usize = if (start_arg.integer > 0) @intCast(start_arg.integer - 1) else 0;
                    const text = str_arg.text;
                    if (start < text.len) {
                        const len_val: usize = if (arg_count >= 3 and self.registers[arg_start + 2].type == .integer)
                            @intCast(@max(0, self.registers[arg_start + 2].integer))
                        else
                            text.len - start;
                        const end = @min(start + len_val, text.len);
                        self.registers[dest_reg] = RegisterValue.init_text(text[start..end]);
                    } else {
                        self.registers[dest_reg] = RegisterValue.init_text("");
                    }
                } else {
                    self.registers[dest_reg] = RegisterValue.init_null();
                }
            }
        } else if (std.mem.eql(u8, upper_name, "CONCAT")) {
            var total_len: usize = 0;
            for (0..arg_count) |i| {
                const arg = self.registers[arg_start + i];
                if (arg.type == .text) total_len += arg.text.len;
            }
            const result = try self.allocator.alloc(u8, total_len);
            var pos: usize = 0;
            for (0..arg_count) |i| {
                const arg = self.registers[arg_start + i];
                if (arg.type == .text) {
                    @memcpy(result[pos .. pos + arg.text.len], arg.text);
                    pos += arg.text.len;
                }
            }
            self.registers[dest_reg] = RegisterValue.init_text(result);
        } else if (std.mem.eql(u8, upper_name, "TRIM")) {
            if (arg_count >= 1) {
                const arg = self.registers[arg_start];
                if (arg.type == .text) {
                    const trimmed = std.mem.trim(u8, arg.text, " \t\n\r");
                    self.registers[dest_reg] = RegisterValue.init_text(trimmed);
                } else {
                    self.registers[dest_reg] = RegisterValue.init_null();
                }
            }
        } else {
            self.registers[dest_reg] = RegisterValue.init_null();
        }
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
