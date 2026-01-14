const std = @import("std");
const StorageError = @import("errors.zig").StorageError;

pub const Type = enum {
    Integer,
    Text,
    Real,
    Blob,
    Boolean,
    Date,
    Time,
    Datetime,
};

pub const DefaultValue = union(enum) {
    none: void,
    integer: i64,
    real: f64,
    text: []const u8,
    boolean: bool,
    current_timestamp: void,
};

pub const Column = struct {
    name: []const u8,
    type: Type,
    primary_key: bool,
    not_null: bool,
    default: DefaultValue = .{ .none = {} },
};

pub const Schema = struct {
    table_name: []const u8,
    columns: []Column,
    pk_index: ?usize,

    pub fn init(table_name: []const u8, columns: []Column) Schema {
        var pk_index: ?usize = null;
        for (columns, 0..) |col, i| {
            if (col.primary_key) {
                if (pk_index) |_| {
                    @panic("Multiple primary keys defined");
                } else {
                    pk_index = i;
                }
            }
        }
        return Schema{
            .table_name = table_name,
            .columns = columns,
            .pk_index = pk_index,
        };
    }

    pub fn get_column_index(self: *const Schema, name: []const u8) StorageError!usize {
        for (self.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, name)) {
                return i;
            }
        }
        return StorageError.ColumnNotFound;
    }
};

pub const IndexDef = struct {
    name: []const u8,
    table: []const u8,
    columns: []const []const u8,
    unique: bool,
    root_page: u32,
};
