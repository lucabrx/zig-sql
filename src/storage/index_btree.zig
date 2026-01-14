const std = @import("std");
const Pager = @import("pager.zig").Pager;
const Page = @import("pager.zig").Page;
const node = @import("node.zig");

const print = std.debug.print;

pub const INDEX_CELL_SIZE: usize = 8;
pub const INDEX_HEADER_SIZE: usize = node.LEAF_HEADER_SIZE;

pub fn max_index_cells() u32 {
    const available = @import("pager.zig").PAGE_SIZE - INDEX_HEADER_SIZE;
    return @as(u32, @intCast(available / INDEX_CELL_SIZE));
}

pub fn index_cell_offset(cell_num: u32) usize {
    return INDEX_HEADER_SIZE + (cell_num * INDEX_CELL_SIZE);
}

pub const IndexBtree = struct {
    pager: *Pager,
    root_page: u32,

    pub fn init(pager: *Pager, root_page: u32) IndexBtree {
        return IndexBtree{
            .pager = pager,
            .root_page = root_page,
        };
    }

    pub fn initialize(self: *IndexBtree) !void {
        const page = try self.pager.get_page(self.root_page);
        node.initialize_leaf_node(page);
        node.set_node_root(page, true);
        self.pager.mark_dirty(self.root_page);
    }

    pub fn insert(self: *IndexBtree, key_hash: u32, rowid: u32) !void {
        const page = try self.pager.get_page(self.root_page);
        const num_cells = node.get_num_cells(page);

        var insert_pos: u32 = 0;
        while (insert_pos < num_cells) : (insert_pos += 1) {
            const cell_key = get_index_key(page, insert_pos);
            const cell_rowid = get_index_rowid(page, insert_pos);
            if (key_hash < cell_key or (key_hash == cell_key and rowid < cell_rowid)) {
                break;
            }
            if (key_hash == cell_key and rowid == cell_rowid) {
                return;
            }
        }

        if (num_cells >= max_index_cells()) {
            return error.IndexFull;
        }

        if (insert_pos < num_cells) {
            var i: u32 = num_cells;
            while (i > insert_pos) : (i -= 1) {
                const src = index_cell_offset(i - 1);
                const dst = index_cell_offset(i);
                @memcpy(page.data[dst .. dst + INDEX_CELL_SIZE], page.data[src .. src + INDEX_CELL_SIZE]);
            }
        }

        set_index_key(page, insert_pos, key_hash);
        set_index_rowid(page, insert_pos, rowid);
        node.set_num_cells(page, num_cells + 1);
        self.pager.mark_dirty(self.root_page);
    }

    pub fn delete(self: *IndexBtree, key_hash: u32, rowid: u32) !void {
        const page = try self.pager.get_page(self.root_page);
        const num_cells = node.get_num_cells(page);

        var found_pos: ?u32 = null;
        var i: u32 = 0;
        while (i < num_cells) : (i += 1) {
            if (get_index_key(page, i) == key_hash and get_index_rowid(page, i) == rowid) {
                found_pos = i;
                break;
            }
        }

        if (found_pos) |pos| {
            var j: u32 = pos;
            while (j < num_cells - 1) : (j += 1) {
                const src = index_cell_offset(j + 1);
                const dst = index_cell_offset(j);
                @memcpy(page.data[dst .. dst + INDEX_CELL_SIZE], page.data[src .. src + INDEX_CELL_SIZE]);
            }
            node.set_num_cells(page, num_cells - 1);
            self.pager.mark_dirty(self.root_page);
        }
    }

    pub fn find(self: *IndexBtree, key_hash: u32, allocator: std.mem.Allocator, results: *std.ArrayList(u32)) !void {
        const page = try self.pager.get_page(self.root_page);
        const num_cells = node.get_num_cells(page);

        var i: u32 = 0;
        while (i < num_cells) : (i += 1) {
            if (get_index_key(page, i) == key_hash) {
                try results.append(allocator, get_index_rowid(page, i));
            }
        }
    }

    pub fn contains(self: *IndexBtree, key_hash: u32) !bool {
        const page = try self.pager.get_page(self.root_page);
        const num_cells = node.get_num_cells(page);

        var i: u32 = 0;
        while (i < num_cells) : (i += 1) {
            if (get_index_key(page, i) == key_hash) {
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *IndexBtree) !u32 {
        const page = try self.pager.get_page(self.root_page);
        return node.get_num_cells(page);
    }
};

fn get_index_key(page: *Page, cell_num: u32) u32 {
    const offset = index_cell_offset(cell_num);
    return std.mem.readInt(u32, page.data[offset..][0..4], .little);
}

fn set_index_key(page: *Page, cell_num: u32, key: u32) void {
    const offset = index_cell_offset(cell_num);
    std.mem.writeInt(u32, page.data[offset..][0..4], key, .little);
}

fn get_index_rowid(page: *Page, cell_num: u32) u32 {
    const offset = index_cell_offset(cell_num) + 4;
    return std.mem.readInt(u32, page.data[offset..][0..4], .little);
}

fn set_index_rowid(page: *Page, cell_num: u32, rowid: u32) void {
    const offset = index_cell_offset(cell_num) + 4;
    std.mem.writeInt(u32, page.data[offset..][0..4], rowid, .little);
}

pub fn hash_value(value: anytype) u32 {
    const T = @TypeOf(value);
    if (T == []const u8) {
        return hash_bytes(value);
    } else if (T == i64) {
        return hash_int(value);
    } else if (T == f64) {
        return hash_float(value);
    } else if (T == bool) {
        return if (value) 1 else 0;
    }
    return 0;
}

pub fn hash_bytes(data: []const u8) u32 {
    var h: u32 = 0;
    for (data) |b| {
        h = h *% 31 +% @as(u32, b);
    }
    return h;
}

pub fn hash_int(value: i64) u32 {
    const bytes = std.mem.asBytes(&value);
    return hash_bytes(bytes);
}

pub fn hash_float(value: f64) u32 {
    const bytes = std.mem.asBytes(&value);
    return hash_bytes(bytes);
}

test "index btree basic operations" {
    const allocator = std.testing.allocator;
    var pager = try Pager.init(allocator, ":memory:");
    defer pager.deinit();

    _ = try pager.get_page(0);

    var idx = IndexBtree.init(&pager, 1);
    _ = try pager.get_page(1);
    try idx.initialize();

    try idx.insert(100, 1);
    try idx.insert(200, 2);
    try idx.insert(100, 3);

    try std.testing.expectEqual(@as(u32, 3), try idx.count());

    var results = std.ArrayList(u32){};
    defer results.deinit(allocator);

    try idx.find(100, allocator, &results);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);

    try idx.delete(100, 1);
    try std.testing.expectEqual(@as(u32, 2), try idx.count());

    try std.testing.expect(try idx.contains(200));
}
