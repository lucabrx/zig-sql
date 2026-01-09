const std = @import("std");
const Pager = @import("pager.zig").Pager;
const Page = @import("pager.zig").Page;
const Row = @import("row.zig").Row;
const row = @import("row.zig");
const node = @import("node.zig");
const Cursor = @import("cursor.zig").Cursor;

const print = std.debug.print;

pub const Btree = struct {
    pager: *Pager,
    root_page: u32,

    pub fn init(pager: *Pager, root_page: u32) Btree {
        return Btree{
            .pager = pager,
            .root_page = root_page,
        };
    }

    pub fn deinit(self: *Btree) void {
        _ = self;
        // Pager handles cleanup
    }

    pub fn initialize(self: *Btree) !void {
        const page = try self.pager.get_page(self.root_page);
        node.initialize_leaf_node(page);
        node.set_node_root(page, true);
        self.pager.mark_dirty(self.root_page);
        print("[BTREE] Initialized root page {}\n", .{self.root_page});
    }

    pub fn search(self: *Btree, key: u32) !Cursor {
        const page = try self.pager.get_page(self.root_page);
        return self.search_node(self.root_page, page, key);
    }

    fn search_node(self: *Btree, page_num: u32, page: *Page, key: u32) !Cursor {
        if (node.get_node_type(page) == node.NODE_INTERNAL) {
            return try self.search_internal(page, key);
        }
        return self.search_leaf(page_num, page, key);
    }

    fn search_leaf(self: *Btree, page_num: u32, page: *Page, key: u32) Cursor {
        const num_cells = node.get_num_cells(page);

        var cursor = Cursor{
            .pager = self.pager,
            .page_num = page_num,
            .cell_num = 0,
            .end_of_table = false,
        };

        // Binary search
        var min_index: u32 = 0;
        var max_index: u32 = num_cells;

        while (min_index < max_index) {
            const mid_index = (min_index + max_index) / 2;
            const mid_key = row.get_leaf_key(page, mid_index);

            if (key == mid_key) {
                cursor.cell_num = mid_index;
                return cursor;
            } else if (key < mid_key) {
                max_index = mid_index;
            } else {
                min_index = mid_index + 1;
            }
        }

        cursor.cell_num = min_index;
        return cursor;
    }

    fn search_internal(self: *Btree, initial_page: *Page, key: u32) anyerror!Cursor {
        var page = initial_page;
        var page_num: u32 = 0;

        while (node.get_node_type(page) == node.NODE_INTERNAL) {
            const num_cells = node.get_num_cells(page);

            var min_index: u32 = 0;
            var max_index: u32 = num_cells;

            while (min_index < max_index) {
                const mid_index = (min_index + max_index) / 2;
                const mid_key = node.get_internal_key(page, mid_index);

                if (key <= mid_key) {
                    max_index = mid_index;
                } else {
                    min_index = mid_index + 1;
                }
            }

            var child_page_num: u32 = undefined;
            if (min_index >= num_cells) {
                child_page_num = node.get_right_child(page);
            } else {
                child_page_num = node.get_internal_child(page, min_index);
            }

            page = try self.pager.get_page(child_page_num);
            page_num = child_page_num;
        }

        // Now we're at a leaf node
        return self.search_leaf(page_num, page, key);
    }

    pub fn insert(self: *Btree, key: u32, r: Row) !void {
        const root_page = try self.pager.get_page(self.root_page);
        const num_cells = node.get_num_cells(root_page);
        var cursor = try self.search(key);

        if (cursor.cell_num < num_cells) {
            const key_at_index = row.get_leaf_key(root_page, cursor.cell_num);
            if (key_at_index == key) {
                return error.DuplicateKey;
            }
        }

        try self.insert_leaf(&cursor, key, r);
        print("[BTREE] Inserted key {} at cell {}\n", .{ key, cursor.cell_num });
    }

    fn insert_leaf(self: *Btree, cursor: *Cursor, key: u32, r: Row) !void {
        const page = try self.pager.get_page(cursor.page_num);
        const num_cells = node.get_num_cells(page);

        if (num_cells >= row.max_leaf_cells()) {
            // Node is full - need to split
            try self.split_leaf_and_insert(cursor, key, r);
            return;
        }

        // Shift cells to make room
        if (cursor.cell_num < num_cells) {
            var i: u32 = num_cells;
            while (i > cursor.cell_num) : (i -= 1) {
                const src_offset = row.leaf_cell_offset(i - 1);
                const dest_offset = row.leaf_cell_offset(i);
                @memcpy(
                    page.data[dest_offset .. dest_offset + row.LEAF_CELL_SIZE],
                    page.data[src_offset .. src_offset + row.LEAF_CELL_SIZE],
                );
            }
        }

        row.set_leaf_key(page, cursor.cell_num, key);
        row.set_leaf_row(page, cursor.cell_num, r);
        node.set_num_cells(page, num_cells + 1);
        self.pager.mark_dirty(cursor.page_num);
    }

    fn split_leaf_and_insert(self: *Btree, cursor: *Cursor, key: u32, r: Row) !void {
        const old_page = try self.pager.get_page(cursor.page_num);
        const new_page_num = self.pager.num_pages;
        const new_page = try self.pager.get_page(new_page_num);
        node.initialize_leaf_node(new_page);

        const old_max = node.get_num_cells(old_page);
        const split_point = (old_max + 1) / 2;

        // Move cells to new page
        var i: u32 = 0;
        while (i <= old_max) : (i += 1) {
            var dest_page: *Page = undefined;
            var dest_cell: u32 = undefined;

            if (i >= split_point) {
                dest_page = new_page;
                dest_cell = i - split_point;
            } else {
                dest_page = old_page;
                dest_cell = i;
            }

            if (i == cursor.cell_num) {
                row.set_leaf_key(dest_page, dest_cell, key);
                row.set_leaf_row(dest_page, dest_cell, r);
            } else {
                var src_cell = i;
                if (i > cursor.cell_num) {
                    src_cell = i - 1;
                }
                if (src_cell < old_max) {
                    const src_key = row.get_leaf_key(old_page, src_cell);
                    const src_row = row.get_leaf_row(old_page, src_cell);
                    row.set_leaf_key(dest_page, dest_cell, src_key);
                    row.set_leaf_row(dest_page, dest_cell, src_row);
                }
            }
        }

        const left_count = split_point;
        const right_count = old_max + 1 - split_point;
        node.set_num_cells(old_page, left_count);
        node.set_num_cells(new_page, right_count);

        // Link leaf nodes
        node.set_next_leaf(new_page, node.get_next_leaf(old_page));
        node.set_next_leaf(old_page, new_page_num);

        if (node.is_node_root(old_page)) {
            try self.create_new_root(new_page_num);
        }

        self.pager.mark_dirty(cursor.page_num);
        self.pager.mark_dirty(new_page_num);

        print("[BTREE] Split leaf, new page {}\n", .{new_page_num});
    }

    fn create_new_root(self: *Btree, right_child_page_num: u32) !void {
        const old_root_page = try self.pager.get_page(self.root_page);
        const right_page = try self.pager.get_page(right_child_page_num);
        const left_child_page_num = self.pager.num_pages;
        const left_page = try self.pager.get_page(left_child_page_num);

        // Copy old root to left child
        @memcpy(&left_page.data, &old_root_page.data);
        node.set_node_root(left_page, false);
        node.set_parent_pointer(left_page, self.root_page);
        node.set_parent_pointer(right_page, self.root_page);

        // Initialize old root as internal node
        node.initialize_internal_node(old_root_page);
        node.set_node_root(old_root_page, true);
        node.set_num_cells(old_root_page, 1);
        node.set_internal_child(old_root_page, 0, left_child_page_num);

        const left_max_key = self.get_max_key(left_page);
        node.set_internal_key(old_root_page, 0, left_max_key);
        node.set_right_child(old_root_page, right_child_page_num);

        self.pager.mark_dirty(self.root_page);
        self.pager.mark_dirty(left_child_page_num);
        self.pager.mark_dirty(right_child_page_num);

        print("[BTREE] Created new root, left={}, right={}\n", .{ left_child_page_num, right_child_page_num });
    }

    pub fn get_max_key(self: *Btree, page: *Page) u32 {
        if (node.get_node_type(page) == node.NODE_LEAF) {
            const num_cells = node.get_num_cells(page);
            if (num_cells == 0) {
                return 0;
            }
            return row.get_leaf_key(page, num_cells - 1);
        } else {
            const right_child_num = node.get_right_child(page);
            const right_child = self.pager.get_page(right_child_num) catch return 0;
            return self.get_max_key(right_child);
        }
    }

    pub fn print_tree(self: *Btree) !void {
        const root_page = try self.pager.get_page(self.root_page);
        try self.print_node(root_page, 0);
    }

    fn print_node(self: *Btree, page: *Page, level: u32) !void {
        const node_type = node.get_node_type(page);
        const num_cells = node.get_num_cells(page);

        print("[BTREE] Level {} | Type: {s} | Cells: {}\n", .{
            level,
            if (node_type == node.NODE_LEAF) "leaf" else "internal",
            num_cells,
        });

        if (node_type == node.NODE_LEAF) {
            var i: u32 = 0;
            while (i < num_cells) : (i += 1) {
                const k = row.get_leaf_key(page, i);
                print("[BTREE]   Cell {}: key={}\n", .{ i, k });
            }
        } else {
            var i: u32 = 0;
            while (i < num_cells) : (i += 1) {
                const child_num = node.get_internal_child(page, i);
                const child_page = try self.pager.get_page(child_num);
                try self.print_node(child_page, level + 1);
            }
            const right_child_num = node.get_right_child(page);
            const right_child = try self.pager.get_page(right_child_num);
            try self.print_node(right_child, level + 1);
        }
    }
};

const StorageError = error{DuplicateKey};

test "btree initialization" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    var btree = Btree.init(&pager, 0);
    try btree.initialize();

    const page = try pager.get_page(0);
    try std.testing.expectEqual(node.NODE_LEAF, node.get_node_type(page));
    try std.testing.expect(node.is_node_root(page));
}

test "btree insert and search" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    var btree = Btree.init(&pager, 0);
    try btree.initialize();

    const r1 = Row.init(1, "alice", "alice@test.com");
    try btree.insert(1, r1);

    var cursor = try btree.search(1);
    try std.testing.expectEqual(0, cursor.cell_num);

    const retrieved = try cursor.get_value();
    try std.testing.expectEqual(1, retrieved.id);
}

test "btree insert multiple keys" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    var btree = Btree.init(&pager, 0);
    try btree.initialize();

    const r1 = Row.init(1, "alice", "alice@test.com");
    const r2 = Row.init(2, "bob", "bob@test.com");
    const r3 = Row.init(3, "charlie", "charlie@test.com");

    try btree.insert(2, r2);
    try btree.insert(1, r1);
    try btree.insert(3, r3);

    // Verify all keys can be found
    var c1 = try btree.search(1);
    var c2 = try btree.search(2);
    var c3 = try btree.search(3);

    try std.testing.expectEqual(1, (try c1.get_value()).id);
    try std.testing.expectEqual(2, (try c2.get_value()).id);
    try std.testing.expectEqual(3, (try c3.get_value()).id);
}

test "btree duplicate key error" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    var btree = Btree.init(&pager, 0);
    try btree.initialize();

    const r1 = Row.init(1, "alice", "alice@test.com");
    try btree.insert(1, r1);

    const r2 = Row.init(1, "bob", "bob@test.com");
    const result = btree.insert(1, r2);
    try std.testing.expectError(error.DuplicateKey, result);
}
