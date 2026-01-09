const std = @import("std");
const Pager = @import("pager.zig").Pager;
const row = @import("row.zig");
const node = @import("node.zig");

pub const Cursor = struct {
    pager: *Pager,
    page_num: u32,
    cell_num: u32,
    end_of_table: bool,

    pub fn init_start(pager: *Pager, root_page: u32) !Cursor {
        var cursor = Cursor{
            .pager = pager,
            .page_num = root_page,
            .cell_num = 0,
            .end_of_table = false,
        };

        var page = try pager.get_page(root_page);

        // Navigate to leftmost leaf
        while (node.get_node_type(page) != node.NODE_LEAF) {
            const child_num = node.get_internal_child(page, 0);
            cursor.page_num = child_num;
            page = try pager.get_page(child_num);
        }

        const num_cells = node.get_num_cells(page);
        cursor.end_of_table = (num_cells == 0);

        return cursor;
    }

    pub fn init_end(pager: *Pager, root_page: u32) !Cursor {
        var cursor = Cursor{
            .pager = pager,
            .page_num = root_page,
            .cell_num = 0,
            .end_of_table = true,
        };

        var page = try pager.get_page(root_page);

        // Navigate to rightmost leaf
        while (node.get_node_type(page) != node.NODE_LEAF) {
            const right_child = node.get_right_child(page);
            cursor.page_num = right_child;
            page = try pager.get_page(right_child);
        }

        cursor.cell_num = node.get_num_cells(page);
        return cursor;
    }

    pub fn get_value(self: *Cursor) !row.Row {
        const page = try self.pager.get_page(self.page_num);
        return row.get_leaf_row(page, self.cell_num);
    }

    pub fn get_key(self: *Cursor) !u32 {
        const page = try self.pager.get_page(self.page_num);
        return row.get_leaf_key(page, self.cell_num);
    }

    pub fn advance(self: *Cursor) !void {
        const page = try self.pager.get_page(self.page_num);
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

    pub fn debug_print(self: *Cursor) !void {
        const r = try self.get_value();
        row.debug_print_row(r);
    }
};

test "cursor initialization" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    const page = try pager.get_page(0);
    node.initialize_leaf_node(page);
    node.set_node_root(page, true);

    const cursor = try Cursor.init_start(&pager, 0);

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

    var cursor = try Cursor.init_start(&pager, 0);

    try std.testing.expect(!cursor.end_of_table);
    try std.testing.expectEqual(0, cursor.cell_num);

    const key = try cursor.get_key();
    try std.testing.expectEqual(1, key);

    const retrieved = try cursor.get_value();
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

    var cursor = try Cursor.init_start(&pager, 0);

    try std.testing.expect(!cursor.end_of_table);
    try std.testing.expectEqual(0, cursor.cell_num);

    try cursor.advance();
    try std.testing.expect(!cursor.end_of_table);
    try std.testing.expectEqual(1, cursor.cell_num);

    try cursor.advance();
    try std.testing.expect(cursor.end_of_table);
}
