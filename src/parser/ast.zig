const std = @import("std");

pub const Expression = union(enum) {
    identifier: Identifier,
    integer_literal: IntegerLiteral,
    float_literal: FloatLiteral,
    string_literal: StringLiteral,
    boolean_literal: BooleanLiteral,
    null_literal: NullLiteral,
    star_expression: StarExpression,
    binary_expression: *BinaryExpression,
    unary_expression: *UnaryExpression,
    subquery: *SubqueryExpression,
};

pub const SubqueryExpression = struct {
    select: SelectStatement,
};

pub const Statement = union(enum) {
    select_stmt: SelectStatement,
    insert_stmt: InsertStatement,
    create_table_stmt: CreateTableStatement,
    create_index_stmt: CreateIndexStatement,
    delete_stmt: DeleteStatement,
    update_stmt: UpdateStatement,
    drop_table_stmt: DropTableStatement,
    drop_index_stmt: DropIndexStatement,
    begin_stmt: BeginStatement,
    commit_stmt: CommitStatement,
    rollback_stmt: RollbackStatement,
    savepoint_stmt: SavepointStatement,
    release_savepoint_stmt: ReleaseSavepointStatement,
    set_transaction_stmt: SetTransactionStatement,
};

pub const Node = union(enum) {
    stmt: Statement,
    expr: Expression,
};

// --- Statements ---

pub const SelectStatement = struct {
    columns: []const Expression,
    from: []const u8,
    joins: []const JoinClause,
    where: ?Expression,
    order_by: []const OrderBy,
    limit: ?i64,
    offset: ?i64,
};

pub const JoinType = enum {
    inner,
    left,
    right,
    cross,
};

pub const JoinClause = struct {
    join_type: JoinType,
    table: []const u8,
    condition: ?Expression,
};

pub const OrderBy = struct {
    column: []const u8,
    desc: bool,
};

pub const InsertStatement = struct {
    table: []const u8,
    columns: []const []const u8, // []string
    values: []const Expression,
};

pub const CreateTableStatement = struct {
    table: []const u8,
    columns: []const ColumnDef,
};

pub const ColumnDef = struct {
    name: []const u8,
    type_name: []const u8, // 'type' is a reserved keyword in Zig
    primary_key: bool,
    not_null: bool,
};

pub const DeleteStatement = struct {
    table: []const u8,
    where: ?Expression,
};

pub const UpdateStatement = struct {
    table: []const u8,
    set: []const Assignment,
    where: ?Expression,
};

pub const Assignment = struct {
    column: []const u8,
    value: Expression,
};

pub const DropTableStatement = struct {
    table: []const u8,
    if_exists: bool,
};

pub const DropIndexStatement = struct {
    index_name: []const u8,
    if_exists: bool,
};

pub const BeginStatement = struct {};
pub const CommitStatement = struct {};
pub const RollbackStatement = struct {
    savepoint_name: ?[]const u8 = null,
};
pub const SavepointStatement = struct {
    name: []const u8,
};
pub const ReleaseSavepointStatement = struct {
    name: []const u8,
};

pub const IsolationLevel = enum {
    read_uncommitted,
    read_committed,
    repeatable_read,
    serializable,
};

pub const SetTransactionStatement = struct {
    isolation_level: IsolationLevel,
};

pub const CreateIndexStatement = struct {
    index_name: []const u8,
    table: []const u8,
    columns: []const []const u8,
    unique: bool,
};

// --- Expressions ---

pub const Identifier = struct {
    name: []const u8,
};

pub const IntegerLiteral = struct {
    value: i64,
};

pub const FloatLiteral = struct {
    value: f64,
};

pub const StringLiteral = struct {
    value: []const u8,
};

pub const NullLiteral = struct {};

pub const BooleanLiteral = struct {
    value: bool,
};

pub const StarExpression = struct {};

pub const BinaryExpression = struct {
    left: Expression,
    operator: []const u8,
    right: Expression,
};

pub const UnaryExpression = struct {
    operator: []const u8,
    right: Expression,
};

test "usage example" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bin_expr = try allocator.create(BinaryExpression);
    bin_expr.* = BinaryExpression{
        .left = Expression{ .identifier = .{ .name = "id" } },
        .operator = "=",
        .right = Expression{ .integer_literal = .{ .value = 5 } },
    };

    var columns = try std.ArrayList(Expression).initCapacity(allocator, 1);
    columns.appendAssumeCapacity(Expression{ .star_expression = .{} });

    const stmt = Statement{
        .select_stmt = SelectStatement{
            .columns = columns.items,
            .from = "users",
            .joins = &[_]JoinClause{},
            .where = Expression{ .binary_expression = bin_expr },
            .order_by = &[_]OrderBy{},
            .limit = 10,
            .offset = null,
        },
    };

    switch (stmt) {
        .select_stmt => |s| {
            std.debug.print("Selecting from table: {s}\n", .{s.from});
            if (s.limit) |l| {
                std.debug.print("Limit is: {d}\n", .{l});
            }
        },
        else => std.debug.print("Not a select statement\n", .{}),
    }
}
