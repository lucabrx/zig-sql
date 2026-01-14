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
    aggregate: *AggregateExpression,
    between: *BetweenExpression,
    in_list: *InListExpression,
    in_subquery: *InSubqueryExpression,
    like: *LikeExpression,
    is_null: *IsNullExpression,
    case_expr: *CaseExpression,
    function_call: *FunctionCall,
};

pub const FunctionCall = struct {
    name: []const u8,
    args: []const Expression,
};

pub const WhenClause = struct {
    condition: Expression,
    result: Expression,
};

pub const CaseExpression = struct {
    operand: ?Expression,
    when_clauses: []const WhenClause,
    else_result: ?Expression,
};

pub const SelectColumn = struct {
    expr: Expression,
    alias: ?[]const u8,
};

pub const TableRef = struct {
    name: []const u8,
    alias: ?[]const u8,
};

pub const BetweenExpression = struct {
    expr: Expression,
    low: Expression,
    high: Expression,
    negated: bool,
};

pub const InListExpression = struct {
    expr: Expression,
    list: []const Expression,
    negated: bool,
};

pub const InSubqueryExpression = struct {
    expr: Expression,
    subquery: SelectStatement,
    negated: bool,
};

pub const LikeExpression = struct {
    expr: Expression,
    pattern: Expression,
    negated: bool,
};

pub const IsNullExpression = struct {
    expr: Expression,
    negated: bool,
};

pub const AggregateFunction = enum {
    count,
    sum,
    avg,
    min,
    max,
};

pub const AggregateExpression = struct {
    function: AggregateFunction,
    arg: ?Expression,
    distinct: bool,
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
    union_stmt: UnionStatement,
    alter_table_stmt: AlterTableStatement,
};

pub const Node = union(enum) {
    stmt: Statement,
    expr: Expression,
};

// --- Statements ---

pub const SelectStatement = struct {
    distinct: bool,
    columns: []const SelectColumn,
    from: []const TableRef,
    joins: []const JoinClause,
    where: ?Expression,
    group_by: []const []const u8,
    having: ?Expression,
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
    table: TableRef,
    condition: ?Expression,
};

pub const OrderBy = struct {
    column: []const u8,
    desc: bool,
};

pub const InsertStatement = struct {
    table: []const u8,
    columns: []const []const u8,
    source: InsertSource,
};

pub const InsertSource = union(enum) {
    values: []const []const Expression,
    select: SelectStatement,
};

pub const CreateTableStatement = struct {
    table: []const u8,
    columns: []const ColumnDef,
};

pub const ColumnDef = struct {
    name: []const u8,
    type_name: []const u8,
    primary_key: bool,
    not_null: bool,
    check: ?[]const u8 = null,
    unique: bool = false,
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

pub const UnionStatement = struct {
    left: SelectStatement,
    right: *UnionOrSelect,
    all: bool,
};

pub const UnionOrSelect = union(enum) {
    select: SelectStatement,
    union_stmt: UnionStatement,
};

pub const AlterTableStatement = struct {
    table: []const u8,
    action: AlterAction,
};

pub const AlterAction = union(enum) {
    add_column: ColumnDef,
    drop_column: []const u8,
    rename_table: []const u8,
    rename_column: struct { old_name: []const u8, new_name: []const u8 },
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

    var columns = try std.ArrayList(SelectColumn).initCapacity(allocator, 1);
    columns.appendAssumeCapacity(SelectColumn{ .expr = Expression{ .star_expression = .{} }, .alias = null });

    var from_tables = try std.ArrayList(TableRef).initCapacity(allocator, 1);
    from_tables.appendAssumeCapacity(TableRef{ .name = "users", .alias = null });

    const stmt = Statement{
        .select_stmt = SelectStatement{
            .distinct = false,
            .columns = columns.items,
            .from = from_tables.items,
            .joins = &[_]JoinClause{},
            .where = Expression{ .binary_expression = bin_expr },
            .group_by = &[_][]const u8{},
            .having = null,
            .order_by = &[_]OrderBy{},
            .limit = 10,
            .offset = null,
        },
    };

    switch (stmt) {
        .select_stmt => |s| {
            std.debug.print("Selecting from table: {s}\n", .{s.from[0].name});
            if (s.limit) |l| {
                std.debug.print("Limit is: {d}\n", .{l});
            }
        },
        else => std.debug.print("Not a select statement\n", .{}),
    }
}
