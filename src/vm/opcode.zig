const std = @import("std");

pub const Opcode = enum(u8) {
    // VM control
    init,
    halt,
    goto,
    if_zero,

    // Table operations
    open_read,
    open_write,
    close,

    // Cursor operations
    rewind,
    next,
    seek,

    // Row operations
    column,
    row_id,
    make_row,
    insert,
    delete,

    // Result operations
    result_row,

    // Register operations
    integer,
    string,
    real,
    null,
    copy,

    // Comparison operations
    eq,
    ne,
    lt,
    le,
    gt,
    ge,

    // Logical operations
    @"and",
    @"or",
    not,

    // Arithmetic
    add,
    sub,
    mul,
    div,

    // Schema operations
    create_table,
    drop_table,

    pub fn to_string(self: Opcode) []const u8 {
        return switch (self) {
            .init => "INIT",
            .halt => "HALT",
            .goto => "GOTO",
            .if_zero => "IF_ZERO",
            .open_read => "OPEN_READ",
            .open_write => "OPEN_WRITE",
            .close => "CLOSE",
            .rewind => "REWIND",
            .next => "NEXT",
            .seek => "SEEK",
            .column => "COLUMN",
            .row_id => "ROW_ID",
            .make_row => "MAKE_ROW",
            .insert => "INSERT",
            .delete => "DELETE",
            .result_row => "RESULT_ROW",
            .integer => "INTEGER",
            .string => "STRING",
            .real => "REAL",
            .null => "NULL",
            .copy => "COPY",
            .eq => "EQ",
            .ne => "NE",
            .lt => "LT",
            .le => "LE",
            .gt => "GT",
            .ge => "GE",
            .@"and" => "AND",
            .@"or" => "OR",
            .not => "NOT",
            .add => "ADD",
            .sub => "SUB",
            .mul => "MUL",
            .div => "DIV",
            .create_table => "CREATE_TABLE",
            .drop_table => "DROP_TABLE",
        };
    }
};

pub const Instruction = struct {
    op: Opcode,
    p1: i32 = 0, // First parameter (often register number)
    p2: i32 = 0, // Second parameter (often jump target or column index)
    p3: i32 = 0, // Third parameter
    p4: []const u8 = "", // String parameter (table name, string literal)
    p5: ?*anyopaque = null, // Generic parameter (for complex data)

    pub fn init(op: Opcode) Instruction {
        return Instruction{ .op = op };
    }

    pub fn with_p1(self: Instruction, p1: i32) Instruction {
        var inst = self;
        inst.p1 = p1;
        return inst;
    }

    pub fn with_p2(self: Instruction, p2: i32) Instruction {
        var inst = self;
        inst.p2 = p2;
        return inst;
    }

    pub fn with_p3(self: Instruction, p3: i32) Instruction {
        var inst = self;
        inst.p3 = p3;
        return inst;
    }

    pub fn with_p4(self: Instruction, p4: []const u8) Instruction {
        var inst = self;
        inst.p4 = p4;
        return inst;
    }

    pub fn debug(self: *const Instruction) void {
        std.debug.print("[VM] {s} p1={} p2={} p3={} p4={s}\n", .{
            self.op.to_string(),
            self.p1,
            self.p2,
            self.p3,
            self.p4,
        });
    }
};

test "opcode to_string" {
    try std.testing.expectEqualStrings("INIT", Opcode.init.to_string());
    try std.testing.expectEqualStrings("HALT", Opcode.halt.to_string());
    try std.testing.expectEqualStrings("RESULT_ROW", Opcode.result_row.to_string());
}

test "instruction creation" {
    const inst = Instruction.init(.open_read)
        .with_p1(0)
        .with_p4("users");

    try std.testing.expectEqual(Opcode.open_read, inst.op);
    try std.testing.expectEqual(0, inst.p1);
    try std.testing.expectEqualStrings("users", inst.p4);
}
