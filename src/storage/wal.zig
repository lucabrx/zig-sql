const std = @import("std");
const fs = std.fs;
const Pager = @import("pager.zig").Pager;
const PAGE_SIZE = @import("pager.zig").PAGE_SIZE;

const print = std.debug.print;

pub const WAL_MAGIC: *const [4]u8 = "ZWAL";
pub const WAL_VERSION: u32 = 1;

pub const WalRecordType = enum(u8) {
    page_write = 1,
    commit = 2,
    checkpoint = 3,
};

pub const WalHeader = extern struct {
    magic: [4]u8,
    version: u32,
    page_size: u32,
    checkpoint_seq: u32,
};

pub const WalRecordHeader = extern struct {
    record_type: u8,
    page_num: u32,
    size: u32,
    checksum: u32,
};

pub const Wal = struct {
    allocator: std.mem.Allocator,
    file: ?fs.File,
    filename: []const u8,
    enabled: bool,
    current_seq: u32,
    uncommitted_pages: std.AutoHashMap(u32, *[PAGE_SIZE]u8),

    pub fn init(allocator: std.mem.Allocator, db_filename: []const u8) !Wal {
        if (std.mem.eql(u8, db_filename, ":memory:")) {
            return Wal{
                .allocator = allocator,
                .file = null,
                .filename = "",
                .enabled = false,
                .current_seq = 0,
                .uncommitted_pages = std.AutoHashMap(u32, *[PAGE_SIZE]u8).init(allocator),
            };
        }

        var wal_filename_buf: [256]u8 = undefined;
        const wal_filename = std.fmt.bufPrint(&wal_filename_buf, "{s}-wal", .{db_filename}) catch return error.FilenameTooLong;
        const owned_filename = try allocator.dupe(u8, wal_filename);

        var wal = Wal{
            .allocator = allocator,
            .file = null,
            .filename = owned_filename,
            .enabled = true,
            .current_seq = 0,
            .uncommitted_pages = std.AutoHashMap(u32, *[PAGE_SIZE]u8).init(allocator),
        };

        try wal.open_or_create();
        return wal;
    }

    pub fn deinit(self: *Wal) void {
        var iter = self.uncommitted_pages.valueIterator();
        while (iter.next()) |page_ptr| {
            self.allocator.destroy(page_ptr.*);
        }
        self.uncommitted_pages.deinit();

        if (self.file) |f| {
            f.close();
        }

        if (self.filename.len > 0) {
            self.allocator.free(self.filename);
        }
    }

    fn open_or_create(self: *Wal) !void {
        const file = fs.cwd().openFile(self.filename, .{ .mode = .read_write }) catch |err| {
            if (err == error.FileNotFound) {
                const new_file = try fs.cwd().createFile(self.filename, .{ .read = true });
                self.file = new_file;
                try self.write_header();
                print("[WAL] Created new WAL file: {s}\n", .{self.filename});
                return;
            }
            return err;
        };

        self.file = file;
        try self.read_header();
        print("[WAL] Opened existing WAL file: {s}\n", .{self.filename});
    }

    fn write_header(self: *Wal) !void {
        const f = self.file orelse return;
        try f.seekTo(0);

        var header: WalHeader = undefined;
        @memcpy(&header.magic, WAL_MAGIC);
        header.version = WAL_VERSION;
        header.page_size = PAGE_SIZE;
        header.checkpoint_seq = 0;

        const header_bytes = std.mem.asBytes(&header);
        try f.writeAll(header_bytes);
    }

    fn read_header(self: *Wal) !void {
        const f = self.file orelse return;
        try f.seekTo(0);

        var header: WalHeader = undefined;
        const header_bytes = std.mem.asBytes(&header);
        const bytes_read = try f.read(header_bytes);

        if (bytes_read < @sizeOf(WalHeader)) {
            try self.write_header();
            return;
        }

        if (!std.mem.eql(u8, &header.magic, WAL_MAGIC)) {
            return error.InvalidWalFile;
        }

        self.current_seq = header.checkpoint_seq;
    }

    pub fn log_page_write(self: *Wal, page_num: u32, data: *const [PAGE_SIZE]u8) !void {
        if (!self.enabled) return;

        const page_copy = try self.allocator.create([PAGE_SIZE]u8);
        @memcpy(page_copy, data);

        if (self.uncommitted_pages.get(page_num)) |old| {
            self.allocator.destroy(old);
        }
        try self.uncommitted_pages.put(page_num, page_copy);

        const f = self.file orelse return;
        try f.seekFromEnd(0);

        var record: WalRecordHeader = undefined;
        record.record_type = @intFromEnum(WalRecordType.page_write);
        record.page_num = page_num;
        record.size = PAGE_SIZE;
        record.checksum = compute_checksum(data);

        const record_bytes = std.mem.asBytes(&record);
        try f.writeAll(record_bytes);
        try f.writeAll(data);

        print("[WAL] Logged page {} write\n", .{page_num});
    }

    pub fn log_commit(self: *Wal) !void {
        if (!self.enabled) return;

        const f = self.file orelse return;
        try f.seekFromEnd(0);

        var record: WalRecordHeader = undefined;
        record.record_type = @intFromEnum(WalRecordType.commit);
        record.page_num = 0;
        record.size = 0;
        record.checksum = 0;

        const record_bytes = std.mem.asBytes(&record);
        try f.writeAll(record_bytes);

        var iter = self.uncommitted_pages.valueIterator();
        while (iter.next()) |page_ptr| {
            self.allocator.destroy(page_ptr.*);
        }
        self.uncommitted_pages.clearRetainingCapacity();

        self.current_seq += 1;
        print("[WAL] Logged commit (seq={})\n", .{self.current_seq});
    }

    pub fn recover(self: *Wal, pager: *Pager) !u32 {
        if (!self.enabled) return 0;

        const f = self.file orelse return 0;
        try f.seekTo(@sizeOf(WalHeader));

        var records_applied: u32 = 0;
        var in_transaction = false;
        var pending_pages = std.AutoHashMap(u32, [PAGE_SIZE]u8).init(self.allocator);
        defer pending_pages.deinit();

        while (true) {
            var record: WalRecordHeader = undefined;
            const record_bytes = std.mem.asBytes(&record);
            const bytes_read = f.read(record_bytes) catch break;

            if (bytes_read < @sizeOf(WalRecordHeader)) break;

            const record_type: WalRecordType = @enumFromInt(record.record_type);

            switch (record_type) {
                .page_write => {
                    var page_data: [PAGE_SIZE]u8 = undefined;
                    const data_read = f.read(&page_data) catch break;
                    if (data_read < PAGE_SIZE) break;

                    const checksum = compute_checksum(&page_data);
                    if (checksum != record.checksum) {
                        print("[WAL] Checksum mismatch for page {}, skipping\n", .{record.page_num});
                        continue;
                    }

                    try pending_pages.put(record.page_num, page_data);
                    in_transaction = true;
                },
                .commit => {
                    if (in_transaction) {
                        var iter = pending_pages.iterator();
                        while (iter.next()) |entry| {
                            const page = try pager.get_page(entry.key_ptr.*);
                            @memcpy(&page.data, &entry.value_ptr.*);
                            page.dirty = true;
                            records_applied += 1;
                        }
                        pending_pages.clearRetainingCapacity();
                        in_transaction = false;
                    }
                },
                .checkpoint => {
                    pending_pages.clearRetainingCapacity();
                    in_transaction = false;
                },
            }
        }

        if (records_applied > 0) {
            print("[WAL] Recovery: applied {} page writes\n", .{records_applied});
        }

        return records_applied;
    }

    pub fn checkpoint(self: *Wal, pager: *Pager) !void {
        if (!self.enabled) return;

        try pager.flush();

        const f = self.file orelse return;
        try f.seekTo(0);
        try f.setEndPos(@sizeOf(WalHeader));

        var header: WalHeader = undefined;
        @memcpy(&header.magic, WAL_MAGIC);
        header.version = WAL_VERSION;
        header.page_size = PAGE_SIZE;
        header.checkpoint_seq = self.current_seq;

        const header_bytes = std.mem.asBytes(&header);
        try f.writeAll(header_bytes);

        print("[WAL] Checkpoint complete (seq={})\n", .{self.current_seq});
    }

    pub fn truncate(self: *Wal) !void {
        if (!self.enabled) return;

        const f = self.file orelse return;
        try f.setEndPos(@sizeOf(WalHeader));
        try f.seekTo(@sizeOf(WalHeader));

        print("[WAL] Truncated\n", .{});
    }
};

fn compute_checksum(data: *const [PAGE_SIZE]u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= PAGE_SIZE) : (i += 4) {
        const word = std.mem.readInt(u32, data[i..][0..4], .little);
        sum = sum +% word;
    }
    return sum;
}
