const std = @import("std");
const Page = @import("pager.zig").Page;
const node = @import("node.zig");

pub const COL_ID_SIZE: usize = 4;
pub const COL_USERNAME_SIZE: usize = 32;
pub const COL_EMAIL_SIZE: usize = 255;
pub const COL_ACTIVE_SIZE: usize = 1;
pub const ROW_SIZE: usize = COL_ID_SIZE + COL_USERNAME_SIZE + COL_EMAIL_SIZE + COL_ACTIVE_SIZE;

pub const PAGE_SIZE = @import("pager.zig").PAGE_SIZE;

pub const Row = struct {
    id: u32,
    username: [COL_USERNAME_SIZE]u8,
    email: [COL_EMAIL_SIZE]u8,
    active: bool,

    pub fn init(id: u32, username: []const u8, email: []const u8) Row {
        return Row.initWithActive(id, username, email, false);
    }

    pub fn initWithActive(id: u32, username: []const u8, email: []const u8, active: bool) Row {
        var r = Row{
            .id = id,
            .username = std.mem.zeroes([COL_USERNAME_SIZE]u8),
            .email = std.mem.zeroes([COL_EMAIL_SIZE]u8),
            .active = active,
        };

        const u_len = @min(username.len, COL_USERNAME_SIZE);
        @memcpy(r.username[0..u_len], username[0..u_len]);

        const e_len = @min(email.len, COL_EMAIL_SIZE);
        @memcpy(r.email[0..e_len], email[0..e_len]);

        return r;
    }

    pub fn serialize(self: *const Row) [ROW_SIZE]u8 {
        var buf: [ROW_SIZE]u8 = undefined;

        std.mem.writeInt(u32, buf[0..4], self.id, .little);

        @memcpy(buf[COL_ID_SIZE .. COL_ID_SIZE + COL_USERNAME_SIZE], &self.username);

        const email_offset = COL_ID_SIZE + COL_USERNAME_SIZE;
        @memcpy(buf[email_offset .. email_offset + COL_EMAIL_SIZE], &self.email);

        const active_offset = email_offset + COL_EMAIL_SIZE;
        buf[active_offset] = if (self.active) 1 else 0;

        return buf;
    }
};

pub fn deserialize_row(data: []const u8) Row {
    var row: Row = undefined;

    row.id = std.mem.readInt(u32, data[0..4], .little);

    @memcpy(&row.username, data[COL_ID_SIZE .. COL_ID_SIZE + COL_USERNAME_SIZE]);

    const email_offset = COL_ID_SIZE + COL_USERNAME_SIZE;
    @memcpy(&row.email, data[email_offset .. email_offset + COL_EMAIL_SIZE]);

    const active_offset = email_offset + COL_EMAIL_SIZE;
    row.active = data[active_offset] != 0;

    return row;
}

pub fn print_row(r: Row) void {
    const user = std.mem.sliceTo(&r.username, 0);
    const mail = std.mem.sliceTo(&r.email, 0);
    std.debug.print("Row(id={}, user={s}, email={s})\n", .{ r.id, user, mail });
}

pub const LEAF_KEY_SIZE: usize = 4;
pub const LEAF_VALUE_SIZE: usize = ROW_SIZE;
pub const LEAF_CELL_SIZE: usize = LEAF_KEY_SIZE + LEAF_VALUE_SIZE;

pub fn max_leaf_cells() u32 {
    const available = PAGE_SIZE - node.LEAF_HEADER_SIZE;
    return @as(u32, @intCast(available / LEAF_CELL_SIZE));
}

pub fn leaf_cell_offset(cell_num: u32) usize {
    return node.LEAF_HEADER_SIZE + (cell_num * LEAF_CELL_SIZE);
}

pub fn get_leaf_key(page: *Page, cell_num: u32) u32 {
    const offset = leaf_cell_offset(cell_num);
    return std.mem.readInt(u32, page.data[offset..][0..4], .little);
}

pub fn set_leaf_key(page: *Page, cell_num: u32, key: u32) void {
    const offset = leaf_cell_offset(cell_num);
    std.mem.writeInt(u32, page.data[offset..][0..4], key, .little);
}

pub fn get_leaf_value(page: *Page, cell_num: u32) []u8 {
    const offset = leaf_cell_offset(cell_num) + LEAF_KEY_SIZE;
    return page.data[offset .. offset + LEAF_VALUE_SIZE];
}

pub fn set_leaf_value(page: *Page, cell_num: u32, value: []const u8) void {
    const offset = leaf_cell_offset(cell_num) + LEAF_KEY_SIZE;
    @memcpy(page.data[offset .. offset + LEAF_VALUE_SIZE], value);
}

pub fn get_leaf_row(page: *Page, cell_num: u32) Row {
    const val_data = get_leaf_value(page, cell_num);
    return deserialize_row(val_data);
}

pub fn set_leaf_row(page: *Page, cell_num: u32, r: Row) void {
    const bytes = r.serialize();
    set_leaf_value(page, cell_num, &bytes);
}

const print = std.debug.print;

pub fn debug_print_row(r: Row) void {
    const user = std.mem.sliceTo(&r.username, 0);
    const mail = std.mem.sliceTo(&r.email, 0);
    print("[ROW] id={}, username={s}, email={s}\n", .{ r.id, user, mail });
}

test "row creation and field values" {
    const row = Row.init(1, "alice", "alice@example.com");
    debug_print_row(row);

    try std.testing.expectEqual(1, row.id);

    const username = std.mem.sliceTo(&row.username, 0);
    try std.testing.expectEqualStrings("alice", username);

    const email = std.mem.sliceTo(&row.email, 0);
    try std.testing.expectEqualStrings("alice@example.com", email);
}

test "row serialization and deserialization" {
    const original = Row.init(42, "bob", "bob@test.com");
    debug_print_row(original);
    const serialized = original.serialize();
    const deserialized = deserialize_row(&serialized);
    debug_print_row(deserialized);

    try std.testing.expectEqual(original.id, deserialized.id);

    const orig_user = std.mem.sliceTo(&original.username, 0);
    const deser_user = std.mem.sliceTo(&deserialized.username, 0);
    try std.testing.expectEqualStrings(orig_user, deser_user);

    const orig_email = std.mem.sliceTo(&original.email, 0);
    const deser_email = std.mem.sliceTo(&deserialized.email, 0);
    try std.testing.expectEqualStrings(orig_email, deser_email);
}

test "row size constants" {
    try std.testing.expectEqual(4, COL_ID_SIZE);
    try std.testing.expectEqual(32, COL_USERNAME_SIZE);
    try std.testing.expectEqual(255, COL_EMAIL_SIZE);
    try std.testing.expectEqual(291, ROW_SIZE);
}

test "max leaf cells calculation" {
    const max_cells = max_leaf_cells();
    // PAGE_SIZE = 4096, LEAF_HEADER_SIZE = 14, LEAF_CELL_SIZE = 4 + 291 = 295
    // (4096 - 14) / 295 = 13
    try std.testing.expectEqual(13, max_cells);
}

test "leaf cell key operations" {
    var page = Page.init();
    node.initialize_leaf_node(&page);

    set_leaf_key(&page, 0, 100);
    try std.testing.expectEqual(100, get_leaf_key(&page, 0));

    set_leaf_key(&page, 1, 200);
    try std.testing.expectEqual(200, get_leaf_key(&page, 1));
}

test "leaf row storage and retrieval" {
    var page = Page.init();
    node.initialize_leaf_node(&page);

    const original_row = Row.init(123, "testuser", "test@email.com");
    debug_print_row(original_row);
    set_leaf_row(&page, 0, original_row);
    set_leaf_key(&page, 0, 123);

    const retrieved_row = get_leaf_row(&page, 0);
    debug_print_row(retrieved_row);
    const retrieved_key = get_leaf_key(&page, 0);

    try std.testing.expectEqual(123, retrieved_key);
    try std.testing.expectEqual(original_row.id, retrieved_row.id);

    const orig_user = std.mem.sliceTo(&original_row.username, 0);
    const retr_user = std.mem.sliceTo(&retrieved_row.username, 0);
    try std.testing.expectEqualStrings(orig_user, retr_user);
}
