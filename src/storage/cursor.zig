const std = @import("std");
const Pager = @import("pager.zig").Pager;
const row = @import("row.zig");
const node = @import("node.zig");
const Btree = @import("btree.zig").Btree;

const print = std.debug.print;

pub const Cursor = struct {
    btree: *Btree,
    page_num: u32,
    cell_num: u32,
    end_of_table: bool,

    pub fn new_cursor_start(btree: *Btree) !Cursor {
        var cursor = Cursor{
            .btree = btree,
            .page_num = btree.root_page,
            .cell_num = 0,
            .end_of_table = false,
        };

        var page = try btree.pager.get_page(btree.root_page);

        // Navigate to leftmost leaf
        while (node.get_node_type(page) != node.NODE_LEAF) {
            const child_page_num = node.get_internal_child(page, 0);
            cursor.page_num = child_page_num;
            page = try btree.pager.get_page(child_page_num);
        }

        const num_cells = node.get_num_cells(page);
        cursor.end_of_table = (num_cells == 0);

        return cursor;
    }

    pub fn new_cursor_end(btree: *Btree) !Cursor {
        var cursor = Cursor{
            .btree = btree,
            .page_num = btree.root_page,
            .cell_num = 0,
            .end_of_table = true,
        };

        var page = try btree.pager.get_page(btree.root_page);

        // Navigate to rightmost leaf
        while (node.get_node_type(page) != node.NODE_LEAF) {
            const right_child = node.get_right_child(page);
            cursor.page_num = right_child;
            page = try btree.pager.get_page(right_child);
        }

        cursor.cell_num = node.get_num_cells(page);
        return cursor;
    }

    pub fn value(self: *Cursor) !row.Row {
        const page = try self.btree.pager.get_page(self.page_num);
        return row.get_leaf_row(page, self.cell_num);
    }

    pub fn advance(self: *Cursor) !void {
        const page = try self.btree.pager.get_page(self.page_num);
        self.cell_num += 1;

        if (self.cell_num >= node.get_num_cells(page)) {
            const next_leaf = node.get_next_leaf(page);
            if (next_leaf == 0) {
                self.end_of_table = true;
            } else {
                self.page_num = next_leaf;
                self.cell_num = 0;
            }
        }
    }

    pub fn is_end(self: *const Cursor) bool {
        return self.end_of_table;
    }

    pub fn key(self: *Cursor) !u32 {
        const page = try self.btree.pager.get_page(self.page_num);
        return row.get_leaf_key(page, self.cell_num);
    }

    pub fn debug(self: *Cursor) void {
        print("[CURSOR] page={}, cell={}, end={}\n", .{ self.page_num, self.cell_num, self.end_of_table });
    }

    pub fn page_number(self: *const Cursor) u32 {
        return self.page_num;
    }

    pub fn cell_number(self: *const Cursor) u32 {
        return self.cell_num;
    }
};

test "cursor initialization" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    const page = try pager.get_page(0);
    node.initialize_leaf_node(page);
    node.set_node_root(page, true);

    var btree = Btree.init(&pager, 0);
    const cursor = try Cursor.new_cursor_start(&btree);

    try std.testing.expectEqual(0, cursor.page_num);
    try std.testing.expectEqual(0, cursor.cell_num);
    try std.testing.expect(cursor.end_of_table); // Empty table
}

test "cursor with data" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    const page = try pager.get_page(0);
    node.initialize_leaf_node(page);
    node.set_node_root(page, true);

    // Insert a row
    const r = row.Row.init(1, "alice", "alice@test.com");
    row.set_leaf_row(page, 0, r);
    row.set_leaf_key(page, 0, 1);
    node.set_num_cells(page, 1);

    var btree = Btree.init(&pager, 0);
    var cursor = try Cursor.new_cursor_start(&btree);

    try std.testing.expect(!cursor.end_of_table);
    try std.testing.expectEqual(0, cursor.cell_num);

    const k = try cursor.key();
    try std.testing.expectEqual(1, k);

    const retrieved = try cursor.value();
    try std.testing.expectEqual(1, retrieved.id);
}

test "cursor advance" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    const page = try pager.get_page(0);
    node.initialize_leaf_node(page);
    node.set_node_root(page, true);

    // Insert two rows
    const r1 = row.Row.init(1, "alice", "alice@test.com");
    const r2 = row.Row.init(2, "bob", "bob@test.com");

    row.set_leaf_row(page, 0, r1);
    row.set_leaf_key(page, 0, 1);
    row.set_leaf_row(page, 1, r2);
    row.set_leaf_key(page, 1, 2);
    node.set_num_cells(page, 2);

    var btree = Btree.init(&pager, 0);
    var cursor = try Cursor.new_cursor_start(&btree);

    try std.testing.expect(!cursor.end_of_table);
    try std.testing.expectEqual(0, cursor.cell_num);

    try cursor.advance();
    try std.testing.expect(!cursor.end_of_table);
    try std.testing.expectEqual(1, cursor.cell_num);

    try cursor.advance();
    try std.testing.expect(cursor.end_of_table);
}

test "cursor end" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    const page = try pager.get_page(0);
    node.initialize_leaf_node(page);
    node.set_node_root(page, true);

    // Insert two rows
    const r1 = row.Row.init(1, "alice", "alice@test.com");
    const r2 = row.Row.init(2, "bob", "bob@test.com");

    row.set_leaf_row(page, 0, r1);
    row.set_leaf_key(page, 0, 1);
    row.set_leaf_row(page, 1, r2);
    row.set_leaf_key(page, 1, 2);
    node.set_num_cells(page, 2);

    var btree = Btree.init(&pager, 0);
    const cursor = try Cursor.new_cursor_end(&btree);

    try std.testing.expect(cursor.end_of_table);
    try std.testing.expectEqual(2, cursor.cell_num); // Points past last cell
}
