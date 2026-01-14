const std = @import("std");
const fs = std.fs;
const print = std.debug.print;

pub const PAGE_SIZE: usize = 4096;
pub const MAX_PAGES: usize = 100;
pub const CACHE_SIZE: usize = 32;
const CHECKSUM_OFFSET: usize = PAGE_SIZE - 4;
const FREE_LIST_PAGE: u32 = 0;
const FREE_LIST_HEADER_SIZE: usize = 8;

pub const Page = struct {
    data: [PAGE_SIZE]u8,
    dirty: bool,

    pub fn init() Page {
        return Page{
            .data = std.mem.zeroes([PAGE_SIZE]u8),
            .dirty = false,
        };
    }
};

const CacheEntry = struct {
    page: *Page,
    page_num: u32,
    access_count: u64,
};

fn compute_checksum(data: []const u8) u32 {
    var hash: u32 = 0;
    for (data[0..CHECKSUM_OFFSET]) |byte| {
        hash = hash *% 31 +% byte;
    }
    return hash;
}

fn write_checksum(data: *[PAGE_SIZE]u8) void {
    const checksum = compute_checksum(data);
    std.mem.writeInt(u32, data[CHECKSUM_OFFSET..][0..4], checksum, .little);
}

fn verify_checksum(data: *const [PAGE_SIZE]u8) bool {
    const stored = std.mem.readInt(u32, data[CHECKSUM_OFFSET..][0..4], .little);
    const computed = compute_checksum(data);
    return stored == computed or stored == 0;
}

pub const PagerError = error{
    PageOutOfBounds,
    PageNotFound,
    IncompleteRead,
    PageCorrupted,
    NoFreePages,
};

pub const Pager = struct {
    file: ?fs.File,
    file_length: u64,
    num_pages: u32,
    pages: [MAX_PAGES]?*Page,
    allocator: std.mem.Allocator,
    in_memory: bool,
    use_checksums: bool,
    access_counter: u64,
    cache_hits: u64,
    cache_misses: u64,
    free_pages: std.ArrayList(u32),

    pub fn init(allocator: std.mem.Allocator, filename: []const u8) !Pager {
        return initWithOptions(allocator, filename, true);
    }

    pub fn initWithOptions(allocator: std.mem.Allocator, filename: []const u8, use_checksums: bool) !Pager {
        var pages: [MAX_PAGES]?*Page = undefined;
        @memset(&pages, null);

        if (std.mem.eql(u8, filename, ":memory:")) {
            return Pager{
                .file = null,
                .file_length = 0,
                .num_pages = 0,
                .pages = pages,
                .allocator = allocator,
                .in_memory = true,
                .use_checksums = false,
                .access_counter = 0,
                .cache_hits = 0,
                .cache_misses = 0,
                .free_pages = std.ArrayList(u32){},
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

        var pager = Pager{
            .file = file,
            .file_length = file_len,
            .num_pages = num_pages,
            .pages = pages,
            .allocator = allocator,
            .in_memory = false,
            .use_checksums = use_checksums,
            .access_counter = 0,
            .cache_hits = 0,
            .cache_misses = 0,
            .free_pages = std.ArrayList(u32){},
        };

        pager.load_free_list() catch {};

        return pager;
    }

    pub fn deinit(self: *Pager) void {
        self.save_free_list() catch {};

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

        self.free_pages.deinit(self.allocator);

        print("[PAGER] Database closed\n", .{});
    }

    fn count_cached_pages(self: *Pager) usize {
        var count: usize = 0;
        for (0..MAX_PAGES) |i| {
            if (self.pages[i] != null) count += 1;
        }
        return count;
    }

    fn evict_lru_page(self: *Pager) !void {
        var oldest_idx: ?usize = null;
        var oldest_access: u64 = std.math.maxInt(u64);

        for (0..MAX_PAGES) |i| {
            if (self.pages[i]) |_| {
                const page_num: u32 = @intCast(i);
                if (page_num < 2) continue;

                if (i < oldest_access) {
                    oldest_idx = i;
                    oldest_access = i;
                }
            }
        }

        if (oldest_idx) |idx| {
            const page_num: u32 = @intCast(idx);
            if (self.pages[idx]) |p| {
                if (p.dirty) {
                    try self.flush_page(page_num);
                }
                self.allocator.destroy(p);
                self.pages[idx] = null;
            }
        }
    }

    pub fn get_page(self: *Pager, page_num: u32) !*Page {
        if (page_num >= MAX_PAGES) return error.PageOutOfBounds;

        self.access_counter += 1;

        if (self.pages[page_num]) |p| {
            self.cache_hits += 1;
            return p;
        }

        self.cache_misses += 1;

        if (self.count_cached_pages() >= CACHE_SIZE) {
            try self.evict_lru_page();
        }

        const page = try self.allocator.create(Page);
        page.* = Page.init();

        if (!self.in_memory and page_num < self.num_pages) {
            const offset = @as(u64, page_num) * PAGE_SIZE;
            if (self.file) |f| {
                try f.seekTo(offset);
                const bytes_read = try f.read(&page.data);
                if (bytes_read != PAGE_SIZE) return error.IncompleteRead;

                if (self.use_checksums and !verify_checksum(&page.data)) {
                    print("[PAGER] ERROR: Page {} checksum mismatch - corrupted!\n", .{page_num});
                    self.allocator.destroy(page);
                    return error.PageCorrupted;
                }
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

    pub fn allocate_page(self: *Pager) !u32 {
        if (self.free_pages.items.len > 0) {
            const page_num = self.free_pages.pop();
            print("[PAGER] Reusing free page {}\n", .{page_num});
            return page_num;
        }

        const new_page_num = self.num_pages;
        if (new_page_num >= MAX_PAGES) return error.NoFreePages;

        _ = try self.get_page(new_page_num);
        return new_page_num;
    }

    pub fn free_page(self: *Pager, page_num: u32) !void {
        if (page_num < 2) return;

        if (self.pages[page_num]) |p| {
            @memset(&p.data, 0);
            p.dirty = false;
            self.allocator.destroy(p);
            self.pages[page_num] = null;
        }

        try self.free_pages.append(self.allocator, page_num);
        print("[PAGER] Freed page {}\n", .{page_num});
    }

    fn load_free_list(self: *Pager) !void {
        if (self.in_memory or self.num_pages == 0) return;

        const page = try self.get_page(0);
        const magic = std.mem.readInt(u32, page.data[0..4], .little);
        if (magic != 0x5A444246) return;

        const count = std.mem.readInt(u32, page.data[4..8], .little);
        const max_entries = (PAGE_SIZE - FREE_LIST_HEADER_SIZE) / 4;
        const entries_to_read = @min(count, max_entries);

        for (0..entries_to_read) |i| {
            const offset = FREE_LIST_HEADER_SIZE + i * 4;
            const free_page_num = std.mem.readInt(u32, page.data[offset..][0..4], .little);
            if (free_page_num > 0 and free_page_num < MAX_PAGES) {
                try self.free_pages.append(self.allocator, free_page_num);
            }
        }
    }

    fn save_free_list(self: *Pager) !void {
        if (self.in_memory or self.free_pages.items.len == 0) return;

        const page = try self.get_page(0);

        std.mem.writeInt(u32, page.data[0..4], 0x5A444246, .little);
        std.mem.writeInt(u32, page.data[4..8], @intCast(self.free_pages.items.len), .little);

        const max_entries = (PAGE_SIZE - FREE_LIST_HEADER_SIZE) / 4;
        const entries_to_write = @min(self.free_pages.items.len, max_entries);

        for (0..entries_to_write) |i| {
            const offset = FREE_LIST_HEADER_SIZE + i * 4;
            std.mem.writeInt(u32, page.data[offset..][0..4], self.free_pages.items[i], .little);
        }

        page.dirty = true;
    }

    pub fn flush_page(self: *Pager, page_num: u32) !void {
        if (self.in_memory) return;

        const page_ptr = self.pages[page_num];
        if (page_ptr == null) return error.PageNotFound;
        const page = page_ptr.?;

        if (self.use_checksums) {
            write_checksum(&page.data);
        }

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

    pub fn sync(self: *Pager) !void {
        if (self.in_memory) return;
        try self.flush();
        if (self.file) |f| {
            try f.sync();
            print("[PAGER] Synced to disk\n", .{});
        }
    }

    pub fn mark_dirty(self: *Pager, page_num: u32) void {
        if (page_num < MAX_PAGES) {
            if (self.pages[page_num]) |p| {
                p.dirty = true;
            }
        }
    }

    pub fn get_cache_stats(self: *Pager) struct { hits: u64, misses: u64, ratio: f64 } {
        const total = self.cache_hits + self.cache_misses;
        const ratio = if (total > 0) @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total)) else 0.0;
        return .{ .hits = self.cache_hits, .misses = self.cache_misses, .ratio = ratio };
    }

    pub fn get_free_page_count(self: *Pager) usize {
        return self.free_pages.items.len;
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
        const stats = self.get_cache_stats();
        print("[PAGER] Cache hits: {}, misses: {}, ratio: {d:.2}%\n", .{ stats.hits, stats.misses, stats.ratio * 100 });
        print("[PAGER] Free pages: {}\n", .{self.free_pages.items.len});
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

test "checksum computation" {
    var data: [PAGE_SIZE]u8 = std.mem.zeroes([PAGE_SIZE]u8);
    data[0] = 42;
    data[100] = 255;
    write_checksum(&data);
    try std.testing.expect(verify_checksum(&data));
    data[50] = 1;
    try std.testing.expect(!verify_checksum(&data));
}
