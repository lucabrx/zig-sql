const std = @import("std");
const fs = std.fs;
const print = std.debug.print;

// [  Page 0 (4096 bytes)  ]
// |-----------------------|
// | Header (Node info)    |  <-- ~14 bytes
// |-----------------------|
// | Row 1 (Alice)         |  <-- 291 bytes
// |-----------------------|
// |                       |
// |   (Empty Space)       |  <-- ~3791 bytes of Zeros
// |                       |
// |-----------------------|

pub const PAGE_SIZE: usize = 4096; // 4KB
pub const MAX_PAGES: usize = 100; // temp

pub const Page = struct {
    data: [PAGE_SIZE]u8,
    dirty: bool, // indicates if the page has been modified

    pub fn init() Page {
        return Page{
            .data = std.mem.zeroes([PAGE_SIZE]u8),
            .dirty = false,
        };
    }
};

pub const Pager = struct {
    file: ?fs.File,
    file_length: u64,
    num_pages: u32,
    pages: [MAX_PAGES]?*Page,
    allocator: std.mem.Allocator,
    in_memory: bool,

    pub fn init(allocator: std.mem.Allocator, filename: []const u8) !Pager {
        var pages: [MAX_PAGES]?*Page = undefined;
        @memset(&pages, null); // sets all entries to null

        if (std.mem.eql(u8, filename, ":memory:")) {
            print("[PAGER] Created in-memory database\n", .{});
            return Pager{
                .file = null,
                .file_length = 0,
                .num_pages = 0,
                .pages = pages,
                .allocator = allocator,
                .in_memory = true,
            };
        }

        const file = try fs.cwd().createFile(filename, .{ .read = true, .truncate = false });
        const stat = try file.stat();
        const file_len = stat.size;

        if (file_len % PAGE_SIZE != 0) {
            print("[PAGER] Warning: file size not aligned to page boundary\n", .{});
        }

        const num_pages = @as(u32, @intCast(file_len / PAGE_SIZE));

        print("[PAGER] Opened database: {s} ({} pages)\n", .{ filename, num_pages });

        return Pager{
            .file = file,
            .file_length = file_len,
            .num_pages = num_pages,
            .pages = pages,
            .allocator = allocator,
            .in_memory = false,
        };
    }

    pub fn deinit(self: *Pager) void {
        self.flush() catch |err| {
            print("[PAGER] Error flushing on close: {}\n", .{err});
        };

        if (self.file) |f| {
            f.close();
        }

        for (0..MAX_PAGES) |i| {
            if (self.pages[i]) |p| {
                self.allocator.destroy(p);
                self.pages[i] = null;
            }
        }
        print("[PAGER] Database closed\n", .{});
    }

    pub fn get_page(self: *Pager, page_num: u32) !*Page {
        if (page_num >= MAX_PAGES) return error.PageOutOfBounds;

        if (self.pages[page_num]) |p| {
            return p;
        }

        const page = try self.allocator.create(Page);
        page.* = Page.init();

        if (!self.in_memory and page_num < self.num_pages) {
            const offset = @as(u64, page_num) * PAGE_SIZE;
            if (self.file) |f| {
                try f.seekTo(offset);
                const bytes_read = try f.read(&page.data);
                if (bytes_read != PAGE_SIZE) return error.IncompleteRead;
            }
            print("[PAGER] Loaded page {} from disk\n", .{page_num});
        } else {
            print("[PAGER] Allocated new page {}\n", .{page_num});
        }

        self.pages[page_num] = page;

        if (page_num >= self.num_pages) {
            self.num_pages = page_num + 1;
        }

        return page;
    }

    pub fn flush_page(self: *Pager, page_num: u32) !void {
        if (self.in_memory) return;

        const page_ptr = self.pages[page_num];
        if (page_ptr == null) return error.PageNotFound;
        const page = page_ptr.?;

        const offset = @as(u64, page_num) * PAGE_SIZE;
        if (self.file) |f| {
            try f.seekTo(offset);
            try f.writeAll(&page.data);
        }

        page.dirty = false;
        print("[PAGER] Flushed page {} to disk\n", .{page_num});
    }

    pub fn flush(self: *Pager) !void {
        if (self.in_memory) return;
        for (0..self.num_pages) |i| {
            const idx = @as(u32, @intCast(i));
            if (self.pages[idx]) |p| {
                if (p.dirty) {
                    try self.flush_page(idx);
                }
            }
        }
    }

    pub fn mark_dirty(self: *Pager, page_num: u32) void {
        if (page_num < MAX_PAGES) {
            if (self.pages[page_num]) |p| {
                p.dirty = true;
            }
        }
    }

    pub fn debug_print_status(self: *Pager) void {
        print("[PAGER] Status: {} pages, in_memory={}\n", .{ self.num_pages, self.in_memory });
        var loaded: u32 = 0;
        var dirty: u32 = 0;
        for (0..MAX_PAGES) |i| {
            if (self.pages[i]) |p| {
                loaded += 1;
                if (p.dirty) dirty += 1;
            }
        }
        print("[PAGER] Loaded pages: {}, Dirty pages: {}\n", .{ loaded, dirty });
    }
};

test "page initialization" {
    const page = Page.init();

    for (page.data) |byte| {
        try std.testing.expectEqual(0, byte);
    }
    try std.testing.expect(!page.dirty);
}

test "in-memory pager creation" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    try std.testing.expect(pager.in_memory);
    try std.testing.expect(pager.file == null);
    try std.testing.expectEqual(0, pager.num_pages);
}

test "in-memory pager page allocation" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    const page0 = try pager.get_page(0);
    try std.testing.expectEqual(1, pager.num_pages);

    page0.data[0] = 42;
    pager.mark_dirty(0);
    try std.testing.expect(page0.dirty);

    const page0_again = try pager.get_page(0);
    try std.testing.expectEqual(42, page0_again.data[0]);
}

test "in-memory pager multiple pages" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    const page0 = try pager.get_page(0);
    const page1 = try pager.get_page(1);
    const page2 = try pager.get_page(2);

    page0.data[0] = 10;
    page1.data[0] = 20;
    page2.data[0] = 30;

    try std.testing.expectEqual(3, pager.num_pages);
    try std.testing.expectEqual(10, page0.data[0]);
    try std.testing.expectEqual(20, page1.data[0]);
    try std.testing.expectEqual(30, page2.data[0]);
}

test "pager page out of bounds" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    const result = pager.get_page(MAX_PAGES);
    try std.testing.expectError(error.PageOutOfBounds, result);
}

test "pager mark dirty" {
    var pager = try Pager.init(std.testing.allocator, ":memory:");
    defer pager.deinit();

    const page = try pager.get_page(0);
    try std.testing.expect(!page.dirty);

    pager.mark_dirty(0);
    try std.testing.expect(page.dirty);
}
