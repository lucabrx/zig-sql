const std = @import("std");
const StorageError = @import("errors.zig").StorageError;

pub const Type = enum {
    Integer,
    Text,
    Real,
    Blob,
    Boolean,
    Date, // Stored as i64 (days since epoch)
    Time, // Stored as i64 (seconds since midnight)
    Datetime, // Stored as i64 (unix timestamp)
};

pub const DefaultValue = union(enum) {
    none: void,
    integer: i64,
    real: f64,
    text: []const u8,
    boolean: bool,
    // Special defaults
    current_timestamp: void, // For Date/Time/Datetime columns
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

    pub fn get_column_index(self: *Schema, name: []const u8) StorageError!usize {
        for (self.columns, 0..) |col, i| {
            if (std.mem.eql(u8, col.name, name)) {
                return i;
            }
        }
        return StorageError.ColumnNotFound;
    }

    pub fn column_size(col_type: Type) usize {
        switch (col_type) {
            .Integer => return 8,
            .Real => return 8,
            .Text => return 4 + 256,
            .Blob => return 4 + 512,
            .Boolean => return 1,
            .Date => return 8,
            .Time => return 8,
            .Datetime => return 8,
        }
    }

    pub fn row_size(self: *Schema) usize {
        var size: usize = 0;
        for (self.columns) |col| {
            size += self.column_size(col.type);
        }
        return size;
    }
};

pub const Value = struct {
    type: []const u8,
    is_null: bool,
    integer: ?i64,
    real: ?f64,
    text: ?[]const u8,
    blob: ?[]const u8,
    boolean: ?bool,
};

pub const DynamicRow = struct {
    values: []Value,

    pub fn init(num_cols: u32) DynamicRow {
        var allocator = std.heap.page_allocator;
        const values = try allocator.alloc(Value, num_cols);
        defer allocator.free(values);
        return DynamicRow{ .values = values };
    }

    pub fn deinit(self: *DynamicRow) void {
        var allocator = std.heap.page_allocator;
        allocator.free(self.values);
    }

    pub fn set_integer(self: *DynamicRow, index: usize, value: i64) void {
        self.values[index] = Value{
            .type = .Integer,
            .is_null = false,
            .integer = value,
            .real = null,
            .text = null,
            .blob = null,
            .boolean = null,
        };
    }

    pub fn set_real(self: *DynamicRow, index: usize, value: f64) void {
        self.values[index] = Value{
            .type = .Real,
            .is_null = false,
            .integer = null,
            .real = value,
            .text = null,
            .blob = null,
            .boolean = null,
        };
    }

    pub fn set_text(self: *DynamicRow, index: usize, value: []const u8) void {
        self.values[index] = Value{
            .type = .Text,
            .is_null = false,
            .integer = null,
            .real = null,
            .text = value,
            .blob = null,
            .boolean = null,
        };
    }

    pub fn set_null(self: *DynamicRow, index: usize) void {
        self.values[index] = Value{
            .type = "",
            .is_null = true,
            .integer = null,
            .real = null,
            .text = null,
            .blob = null,
            .boolean = null,
        };
    }

    pub fn set_boolean(self: *DynamicRow, index: usize, value: bool) void {
        self.values[index] = Value{
            .type = .Boolean,
            .is_null = false,
            .integer = null,
            .real = null,
            .text = null,
            .blob = null,
            .boolean = value,
        };
    }

    pub fn apply_defaults(self: *DynamicRow, schema: *const Schema) StorageError!void {
        for (schema.columns, 0..) |col, i| {
            if (self.values[i].is_null) {
                switch (col.default) {
                    .none => {},
                    .integer => |v| {
                        if (col.type != .Integer and col.type != .Date and col.type != .Time and col.type != .Datetime) {
                            return StorageError.InvalidDefaultValue;
                        }
                        self.set_integer(i, v);
                    },
                    .real => |v| {
                        if (col.type != .Real) {
                            return StorageError.InvalidDefaultValue;
                        }
                        self.set_real(i, v);
                    },
                    .text => |v| {
                        if (col.type != .Text and col.type != .Blob) {
                            return StorageError.InvalidDefaultValue;
                        }
                        self.set_text(i, v);
                    },
                    .boolean => |v| {
                        if (col.type != .Boolean) {
                            return StorageError.InvalidDefaultValue;
                        }
                        self.set_boolean(i, v);
                    },
                    .current_timestamp => {
                        if (col.type != .Date and col.type != .Time and col.type != .Datetime) {
                            return StorageError.InvalidDefaultValue;
                        }
                        const now = std.time.timestamp();
                        switch (col.type) {
                            .Date => self.set_integer(i, @divFloor(now, 86400)), // days since epoch
                            .Time => self.set_integer(i, @mod(now, 86400)), // seconds since midnight
                            .Datetime => self.set_integer(i, now),
                            else => return StorageError.InvalidDefaultValue,
                        }
                    },
                }
            }
        }
    }

    pub fn get_integer(self: *DynamicRow, index: usize) StorageError!i64 {
        const val = self.values[index];
        if (val.is_null) {
            return StorageError.NullValueNotAllowed;
        }
        if (val.integer) |i| {
            return i;
        } else {
            return StorageError.TypeMismatch;
        }
    }

    pub fn get_real(self: *DynamicRow, index: usize) StorageError!f64 {
        const val = self.values[index];
        if (val.is_null) {
            return StorageError.NullValueNotAllowed;
        }
        if (val.real) |r| {
            return r;
        } else {
            return StorageError.TypeMismatch;
        }
    }

    pub fn get_text(self: *DynamicRow, index: usize) StorageError![]const u8 {
        const val = self.values[index];
        if (val.is_null) {
            return StorageError.NullValueNotAllowed;
        }
        if (val.text) |t| {
            return t;
        } else {
            return StorageError.TypeMismatch;
        }
    }

    pub fn get_boolean(self: *DynamicRow, index: usize) StorageError!bool {
        const val = self.values[index];
        if (val.is_null) {
            return StorageError.NullValueNotAllowed;
        }
        if (val.boolean) |b| {
            return b;
        } else {
            return StorageError.TypeMismatch;
        }
    }

    pub fn serialize(self: *DynamicRow, schema: *Schema, buffer: []u8) StorageError!void {
        var offset: usize = 0;
        for (schema.columns, 0..) |col, i| {
            const val = self.values[i];
            if (val.is_null) {
                if (col.not_null) {
                    return StorageError.NullValueNotAllowed;
                }
                // Write null representation
                std.mem.set(u8, buffer[offset .. offset + schema.column_size(col.type)], 0);
            } else {
                switch (col.type) {
                    .Integer => {
                        const int_val = try self.get_integer(i);
                        std.mem.copy(u8, buffer[offset .. offset + 8], @as([]const u8, &int_val));
                    },
                    .Real => {
                        const real_val = try self.get_real(i);
                        std.mem.copy(u8, buffer[offset .. offset + 8], @as([]const u8, &real_val));
                    },
                    .Text => {
                        const text_val = try self.get_text(i);
                        const len = text_val.len;
                        std.mem.copy(u8, buffer[offset .. offset + 4], @as([]const u8, &len));
                        std.mem.copy(u8, buffer[offset + 4 .. offset + 4 + len], text_val);
                    },
                    .Boolean => {
                        const bool_val = try self.get_boolean(i);
                        std.mem.copy(u8, buffer[offset .. offset + 1], @as([]const u8, &bool_val));
                    },
                    else => return StorageError.TypeMismatch,
                }
            }
            offset += schema.column_size(col.type);
        }
    }
};

pub fn deserialize_dynamic_row(data: []const u8, schema: *Schema) StorageError!DynamicRow {
    var row = try DynamicRow.init(@intCast(schema.columns.len));
    var offset: usize = 0;
    for (schema.columns, 0..) |col, i| {
        switch (col.type) {
            .Integer => {
                const int_val = @as(*const i64, &data[offset])[0];
                row.set_integer(i, int_val);
                offset += 8;
            },
            .Real => {
                const real_val = @as(*const f64, &data[offset])[0];
                row.set_real(i, real_val);
                offset += 8;
            },
            .Text => {
                const len = @as(*const u32, &data[offset])[0];
                offset += 4;
                const text_val = data[offset .. offset + len];
                row.set_text(i, text_val);
                offset += len;
            },
            .Boolean => {
                const bool_val = data[offset] != 0;
                row.set_boolean(i, bool_val);
                offset += 1;
            },
            else => return StorageError.TypeMismatch,
        }
    }
    return row;
}
