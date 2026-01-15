const std = @import("std");
const Pager = @import("pager.zig").Pager;
const Page = @import("pager.zig").Page;
const PAGE_SIZE = @import("pager.zig").PAGE_SIZE;

const builtin = @import("builtin");
const DEBUG = builtin.mode == .Debug;

fn debugPrint(comptime fmt: []const u8, args: anytype) void {
    if (DEBUG) {
        std.debug.print(fmt, args);
    }
}

pub const TransactionState = enum {
    none,
    active,
};

pub const IsolationLevel = enum {
    read_uncommitted,
    read_committed,
    repeatable_read,
    serializable,

    pub fn to_string(self: IsolationLevel) []const u8 {
        return switch (self) {
            .read_uncommitted => "READ UNCOMMITTED",
            .read_committed => "READ COMMITTED",
            .repeatable_read => "REPEATABLE READ",
            .serializable => "SERIALIZABLE",
        };
    }
};

const Savepoint = struct {
    name: []const u8,
    shadow_pages: std.AutoHashMap(u32, *[PAGE_SIZE]u8),
};

pub const Transaction = struct {
    allocator: std.mem.Allocator,
    pager: *Pager,
    state: TransactionState,
    isolation_level: IsolationLevel,
    shadow_pages: std.AutoHashMap(u32, *[PAGE_SIZE]u8),
    snapshot_pages: std.AutoHashMap(u32, *[PAGE_SIZE]u8),
    savepoints: std.ArrayList(Savepoint),

    pub fn init(allocator: std.mem.Allocator, pager: *Pager) Transaction {
        return Transaction{
            .allocator = allocator,
            .pager = pager,
            .state = .none,
            .isolation_level = .read_committed,
            .shadow_pages = std.AutoHashMap(u32, *[PAGE_SIZE]u8).init(allocator),
            .snapshot_pages = std.AutoHashMap(u32, *[PAGE_SIZE]u8).init(allocator),
            .savepoints = std.ArrayList(Savepoint){},
        };
    }

    pub fn deinit(self: *Transaction) void {
        var iter = self.shadow_pages.valueIterator();
        while (iter.next()) |shadow_ptr| {
            self.allocator.destroy(shadow_ptr.*);
        }
        self.shadow_pages.deinit();

        var snap_iter = self.snapshot_pages.valueIterator();
        while (snap_iter.next()) |snap_ptr| {
            self.allocator.destroy(snap_ptr.*);
        }
        self.snapshot_pages.deinit();

        for (self.savepoints.items) |*sp| {
            var sp_iter = sp.shadow_pages.valueIterator();
            while (sp_iter.next()) |shadow_ptr| {
                self.allocator.destroy(shadow_ptr.*);
            }
            sp.shadow_pages.deinit();
        }
        self.savepoints.deinit(self.allocator);
    }

    pub fn set_isolation_level(self: *Transaction, level: IsolationLevel) !void {
        if (self.state == .active) {
            return error.CannotChangeIsolationInTransaction;
        }
        self.isolation_level = level;
        debugPrint("[TXN] SET ISOLATION LEVEL {s}\n", .{level.to_string()});
    }

    pub fn begin(self: *Transaction) !void {
        if (self.state == .active) {
            return error.TransactionAlreadyActive;
        }
        self.state = .active;
        debugPrint("[TXN] BEGIN ({s})\n", .{self.isolation_level.to_string()});
    }

    pub fn commit(self: *Transaction) !void {
        if (self.state != .active) {
            return error.NoActiveTransaction;
        }

        try self.pager.flush();

        var iter = self.shadow_pages.valueIterator();
        while (iter.next()) |shadow_ptr| {
            self.allocator.destroy(shadow_ptr.*);
        }
        self.shadow_pages.clearRetainingCapacity();

        var snap_iter = self.snapshot_pages.valueIterator();
        while (snap_iter.next()) |snap_ptr| {
            self.allocator.destroy(snap_ptr.*);
        }
        self.snapshot_pages.clearRetainingCapacity();

        for (self.savepoints.items) |*sp| {
            var sp_iter = sp.shadow_pages.valueIterator();
            while (sp_iter.next()) |shadow_ptr| {
                self.allocator.destroy(shadow_ptr.*);
            }
            sp.shadow_pages.deinit();
        }
        self.savepoints.clearRetainingCapacity();

        self.state = .none;
        debugPrint("[TXN] COMMIT\n", .{});
    }

    pub fn rollback(self: *Transaction) !void {
        if (self.state != .active) {
            return error.NoActiveTransaction;
        }

        var iter = self.shadow_pages.iterator();
        while (iter.next()) |entry| {
            const page_num = entry.key_ptr.*;
            const shadow_data = entry.value_ptr.*;

            if (self.pager.pages[page_num]) |page| {
                @memcpy(&page.data, shadow_data);
                page.dirty = false;
            }

            self.allocator.destroy(shadow_data);
        }
        self.shadow_pages.clearRetainingCapacity();

        var snap_iter = self.snapshot_pages.valueIterator();
        while (snap_iter.next()) |snap_ptr| {
            self.allocator.destroy(snap_ptr.*);
        }
        self.snapshot_pages.clearRetainingCapacity();

        for (self.savepoints.items) |*sp| {
            var sp_iter = sp.shadow_pages.valueIterator();
            while (sp_iter.next()) |shadow_ptr| {
                self.allocator.destroy(shadow_ptr.*);
            }
            sp.shadow_pages.deinit();
        }
        self.savepoints.clearRetainingCapacity();

        self.state = .none;
        debugPrint("[TXN] ROLLBACK\n", .{});
    }

    pub fn get_page_data(self: *Transaction, page_num: u32) ?*[PAGE_SIZE]u8 {
        if (self.state == .active) {
            switch (self.isolation_level) {
                .serializable, .repeatable_read => {
                    if (self.snapshot_pages.get(page_num)) |snapshot| {
                        return snapshot;
                    }
                },
                else => {},
            }
        }
        return null;
    }

    pub fn snapshot_page(self: *Transaction, page_num: u32) !void {
        if (self.state != .active) return;

        switch (self.isolation_level) {
            .serializable, .repeatable_read => {},
            else => return,
        }

        if (self.snapshot_pages.contains(page_num)) return;

        const page = self.pager.pages[page_num] orelse return;

        const snapshot = try self.allocator.create([PAGE_SIZE]u8);
        @memcpy(snapshot, &page.data);

        try self.snapshot_pages.put(page_num, snapshot);
    }

    pub fn savepoint(self: *Transaction, name: []const u8) !void {
        if (self.state != .active) {
            return error.NoActiveTransaction;
        }

        var sp_shadows = std.AutoHashMap(u32, *[PAGE_SIZE]u8).init(self.allocator);

        var iter = self.shadow_pages.keyIterator();
        while (iter.next()) |page_num_ptr| {
            const page_num = page_num_ptr.*;
            if (self.pager.pages[page_num]) |page| {
                const shadow_copy = try self.allocator.create([PAGE_SIZE]u8);
                @memcpy(shadow_copy, &page.data);
                try sp_shadows.put(page_num, shadow_copy);
            }
        }

        try self.savepoints.append(self.allocator, Savepoint{
            .name = name,
            .shadow_pages = sp_shadows,
        });

        debugPrint("[TXN] SAVEPOINT {s}\n", .{name});
    }

    pub fn release_savepoint(self: *Transaction, name: []const u8) !void {
        if (self.state != .active) {
            return error.NoActiveTransaction;
        }

        var found_idx: ?usize = null;
        for (self.savepoints.items, 0..) |sp, i| {
            if (std.mem.eql(u8, sp.name, name)) {
                found_idx = i;
                break;
            }
        }

        if (found_idx) |idx| {
            var sp = self.savepoints.orderedRemove(idx);
            var sp_iter = sp.shadow_pages.valueIterator();
            while (sp_iter.next()) |shadow_ptr| {
                self.allocator.destroy(shadow_ptr.*);
            }
            sp.shadow_pages.deinit();
            debugPrint("[TXN] RELEASE SAVEPOINT {s}\n", .{name});
        } else {
            return error.SavepointNotFound;
        }
    }

    pub fn rollback_to_savepoint(self: *Transaction, name: []const u8) !void {
        if (self.state != .active) {
            return error.NoActiveTransaction;
        }

        var found_idx: ?usize = null;
        for (self.savepoints.items, 0..) |sp, i| {
            if (std.mem.eql(u8, sp.name, name)) {
                found_idx = i;
                break;
            }
        }

        const idx = found_idx orelse return error.SavepointNotFound;

        const sp = &self.savepoints.items[idx];
        var sp_iter = sp.shadow_pages.iterator();
        while (sp_iter.next()) |entry| {
            const page_num = entry.key_ptr.*;
            const savepoint_data = entry.value_ptr.*;

            if (self.pager.pages[page_num]) |page| {
                @memcpy(&page.data, savepoint_data);
                page.dirty = true;
            }
        }

        var i = self.savepoints.items.len;
        while (i > idx + 1) {
            i -= 1;
            var removed = self.savepoints.orderedRemove(i);
            var rm_iter = removed.shadow_pages.valueIterator();
            while (rm_iter.next()) |shadow_ptr| {
                self.allocator.destroy(shadow_ptr.*);
            }
            removed.shadow_pages.deinit();
        }

        debugPrint("[TXN] ROLLBACK TO SAVEPOINT {s}\n", .{name});
    }

    pub fn save_page_for_rollback(self: *Transaction, page_num: u32) !void {
        if (self.state != .active) return;

        if (self.shadow_pages.contains(page_num)) return;

        const page = self.pager.pages[page_num] orelse return;

        const shadow = try self.allocator.create([PAGE_SIZE]u8);
        @memcpy(shadow, &page.data);

        try self.shadow_pages.put(page_num, shadow);
    }

    pub fn is_active(self: *Transaction) bool {
        return self.state == .active;
    }
};

pub const TransactionError = error{
    TransactionAlreadyActive,
    NoActiveTransaction,
    SavepointNotFound,
    CannotChangeIsolationInTransaction,
};
