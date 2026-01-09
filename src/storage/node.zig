const std = @import("std");
const Page = @import("pager.zig").Page;

pub const NODE_INTERNAL: u8 = 0;
pub const NODE_LEAF: u8 = 1;

// Node Header Offsets
pub const OFF_NODE_TYPE: usize = 0;
pub const OFF_IS_ROOT: usize = 1;
pub const OFF_PARENT_PTR: usize = 2;
pub const OFF_NUM_CELLS: usize = 6;
pub const NODE_HEADER_SIZE: usize = 10;

// Leaf Layout
pub const LEAF_NEXT_LEAF_OFF: usize = NODE_HEADER_SIZE;
pub const LEAF_HEADER_SIZE: usize = NODE_HEADER_SIZE + 4;

// Internal Layout
pub const INTERNAL_RIGHT_CHILD_OFF: usize = NODE_HEADER_SIZE;
pub const INTERNAL_HEADER_SIZE: usize = NODE_HEADER_SIZE + 4;
pub const INTERNAL_CELL_SIZE: usize = 8; // 4 bytes child + 4 bytes key

pub fn get_node_type(page: *Page) u8 {
    return page.data[OFF_NODE_TYPE];
}

pub fn set_node_type(page: *Page, node_type: u8) void {
    page.data[OFF_NODE_TYPE] = node_type;
}

pub fn is_node_root(page: *Page) bool {
    return page.data[OFF_IS_ROOT] == 1;
}

pub fn set_node_root(page: *Page, is_root: bool) void {
    page.data[OFF_IS_ROOT] = if (is_root) 1 else 0;
}

pub fn get_parent_pointer(page: *Page) u32 {
    return std.mem.readInt(u32, page.data[OFF_PARENT_PTR..][0..4], .little);
}

pub fn set_parent_pointer(page: *Page, parent: u32) void {
    std.mem.writeInt(u32, page.data[OFF_PARENT_PTR..][0..4], parent, .little);
}

pub fn get_num_cells(page: *Page) u32 {
    return std.mem.readInt(u32, page.data[OFF_NUM_CELLS..][0..4], .little);
}

pub fn set_num_cells(page: *Page, num_cells: u32) void {
    std.mem.writeInt(u32, page.data[OFF_NUM_CELLS..][0..4], num_cells, .little);
}

// leaf
pub fn get_next_leaf(page: *Page) u32 {
    return std.mem.readInt(u32, page.data[LEAF_NEXT_LEAF_OFF..][0..4], .little);
}

pub fn set_next_leaf(page: *Page, next_leaf: u32) void {
    std.mem.writeInt(u32, page.data[LEAF_NEXT_LEAF_OFF..][0..4], next_leaf, .little);
}

pub fn initialize_leaf_node(page: *Page) void {
    set_node_type(page, NODE_LEAF);
    set_node_root(page, false);
    set_num_cells(page, 0);
    set_next_leaf(page, 0);
}

// --- Internal Specifics ---

pub fn get_right_child(page: *Page) u32 {
    return std.mem.readInt(u32, page.data[INTERNAL_RIGHT_CHILD_OFF..][0..4], .little);
}

pub fn set_right_child(page: *Page, child: u32) void {
    std.mem.writeInt(u32, page.data[INTERNAL_RIGHT_CHILD_OFF..][0..4], child, .little);
}

pub fn initialize_internal_node(page: *Page) void {
    set_node_type(page, NODE_INTERNAL);
    set_node_root(page, false);
    set_num_cells(page, 0);
    set_right_child(page, 0);
}

pub fn get_internal_child(page: *Page, index: u32) u32 {
    const num_cells = get_num_cells(page);
    if (index > num_cells) {
        return get_right_child(page);
    }
    const offset = INTERNAL_HEADER_SIZE + index * INTERNAL_CELL_SIZE;
    return std.mem.readInt(u32, page.data[offset..][0..4], .little);
}

pub fn get_internal_key(page: *Page, index: u32) u32 {
    const offset = INTERNAL_HEADER_SIZE + index * INTERNAL_CELL_SIZE + 4;
    return std.mem.readInt(u32, page.data[offset..][0..4], .little);
}

pub fn set_internal_child(page: *Page, index: u32, child: u32) void {
    const offset = INTERNAL_HEADER_SIZE + index * INTERNAL_CELL_SIZE;
    std.mem.writeInt(u32, page.data[offset..][0..4], child, .little);
}

pub fn set_internal_key(page: *Page, index: u32, key: u32) void {
    const offset = INTERNAL_HEADER_SIZE + index * INTERNAL_CELL_SIZE + 4;
    std.mem.writeInt(u32, page.data[offset..][0..4], key, .little);
}

const print = std.debug.print;

pub fn debug_print_node(page: *Page) void {
    const node_type = get_node_type(page);
    const is_root = is_node_root(page);
    const num_cells = get_num_cells(page);
    const parent = get_parent_pointer(page);

    print("[NODE] Type: {s}, Root: {}, Parent: {}, Cells: {}\n", .{
        if (node_type == NODE_LEAF) "Leaf" else "Internal",
        is_root,
        parent,
        num_cells,
    });

    if (node_type == NODE_LEAF) {
        print("[NODE] NextLeaf: {}\n", .{get_next_leaf(page)});
    } else {
        print("[NODE] RightChild: {}\n", .{get_right_child(page)});
    }
}

test "leaf node initialization" {
    var page = Page.init();

    initialize_leaf_node(&page);
    debug_print_node(&page);

    try std.testing.expectEqual(NODE_LEAF, get_node_type(&page));
    try std.testing.expect(!is_node_root(&page));
    try std.testing.expectEqual(0, get_num_cells(&page));
    try std.testing.expectEqual(0, get_next_leaf(&page));
}

test "internal node initialization" {
    var page = Page.init();

    initialize_internal_node(&page);
    debug_print_node(&page);

    try std.testing.expectEqual(NODE_INTERNAL, get_node_type(&page));
    try std.testing.expect(!is_node_root(&page));
    try std.testing.expectEqual(0, get_num_cells(&page));
    try std.testing.expectEqual(0, get_right_child(&page));
}

test "node type and root setters" {
    var page = Page.init();

    set_node_type(&page, NODE_LEAF);
    try std.testing.expectEqual(NODE_LEAF, get_node_type(&page));

    set_node_type(&page, NODE_INTERNAL);
    try std.testing.expectEqual(NODE_INTERNAL, get_node_type(&page));

    set_node_root(&page, true);
    debug_print_node(&page);
    try std.testing.expect(is_node_root(&page));

    set_node_root(&page, false);
    try std.testing.expect(!is_node_root(&page));
}

test "parent pointer operations" {
    var page = Page.init();

    set_parent_pointer(&page, 42);
    debug_print_node(&page);
    try std.testing.expectEqual(42, get_parent_pointer(&page));

    set_parent_pointer(&page, 0);
    try std.testing.expectEqual(0, get_parent_pointer(&page));
}

test "num cells operations" {
    var page = Page.init();

    set_num_cells(&page, 10);
    debug_print_node(&page);
    try std.testing.expectEqual(10, get_num_cells(&page));

    set_num_cells(&page, 100);
    try std.testing.expectEqual(100, get_num_cells(&page));
}

test "leaf next leaf operations" {
    var page = Page.init();
    initialize_leaf_node(&page);

    set_next_leaf(&page, 5);
    debug_print_node(&page);
    try std.testing.expectEqual(5, get_next_leaf(&page));
}

test "internal node child and key operations" {
    var page = Page.init();
    initialize_internal_node(&page);
    set_num_cells(&page, 3);

    set_internal_child(&page, 0, 100);
    set_internal_key(&page, 0, 10);

    set_internal_child(&page, 1, 200);
    set_internal_key(&page, 1, 20);

    set_internal_child(&page, 2, 300);
    set_internal_key(&page, 2, 30);

    set_right_child(&page, 400);

    debug_print_node(&page);

    try std.testing.expectEqual(100, get_internal_child(&page, 0));
    try std.testing.expectEqual(10, get_internal_key(&page, 0));

    try std.testing.expectEqual(200, get_internal_child(&page, 1));
    try std.testing.expectEqual(20, get_internal_key(&page, 1));

    try std.testing.expectEqual(300, get_internal_child(&page, 2));
    try std.testing.expectEqual(30, get_internal_key(&page, 2));

    // Index > num_cells should return right child
    try std.testing.expectEqual(400, get_internal_child(&page, 10));
}
