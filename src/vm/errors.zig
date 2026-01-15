const std = @import("std");

pub const VmErrors = error{
    Halted,
    InvalidOp,
    RegisterOOB,
    NoCursor,
    NoTable,
    NullConstraintViolation,
    TypeMismatch,
    CheckConstraintViolation,
    UniqueConstraintViolation,
    ForeignKeyViolation,
};

pub const ErrorContext = struct {
    error_type: ErrorType = .none,
    table_name: []const u8 = "",
    column_name: []const u8 = "",
    constraint_name: []const u8 = "",
    expected_type: []const u8 = "",
    actual_type: []const u8 = "",
    ref_table: []const u8 = "",
    ref_column: []const u8 = "",
    value: []const u8 = "",

    pub const ErrorType = enum {
        none,
        null_constraint,
        type_mismatch,
        check_constraint,
        unique_constraint,
        foreign_key_missing_ref,
        foreign_key_restrict,
    };

    pub fn format(self: ErrorContext, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self.error_type) {
            .none => try allocator.dupe(u8, "Unknown error"),
            .null_constraint => try std.fmt.allocPrint(
                allocator,
                "NOT NULL constraint failed: {s}.{s}",
                .{ self.table_name, self.column_name },
            ),
            .type_mismatch => try std.fmt.allocPrint(
                allocator,
                "Type mismatch for column '{s}': expected {s}, got {s}",
                .{ self.column_name, self.expected_type, self.actual_type },
            ),
            .check_constraint => try std.fmt.allocPrint(
                allocator,
                "CHECK constraint failed: {s}.{s}",
                .{ self.table_name, self.column_name },
            ),
            .unique_constraint => try std.fmt.allocPrint(
                allocator,
                "UNIQUE constraint failed: {s}.{s} (value: {s})",
                .{ self.table_name, self.column_name, self.value },
            ),
            .foreign_key_missing_ref => try std.fmt.allocPrint(
                allocator,
                "FOREIGN KEY constraint failed: {s}.{s} references {s}.{s} - referenced value not found",
                .{ self.table_name, self.column_name, self.ref_table, self.ref_column },
            ),
            .foreign_key_restrict => try std.fmt.allocPrint(
                allocator,
                "FOREIGN KEY constraint failed: cannot delete/update {s}.{s} - referenced by other rows",
                .{ self.table_name, self.column_name },
            ),
        };
    }

    pub fn reset(self: *ErrorContext) void {
        self.* = ErrorContext{};
    }
};
