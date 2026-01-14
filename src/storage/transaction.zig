const std = @import("std");
const Pager = @import("pager.zig").Pager;
const Page = @import("pager.zig").Page;
const PAGE_SIZE = @import("pager.zig").PAGE_SIZE;

const print = std.debug.print;

pub const TransactionState = enum {
    none,
    active,
};

pub const Transaction = struct {
    allocator: std.mem.Allocator,
    pager: *Pager,
    state: TransactionState,
    shadow_pages: std.AutoHashMap(u32, *[PAGE_SIZE]u8),

    pub fn init(allocator: std.mem.Allocator, pager: *Pager) Transaction {
        return Transaction{
            .allocator = allocator,
            .pager = pager,
            .state = .none,
            .shadow_pages = std.AutoHashMap(u32, *[PAGE_SIZE]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Transaction) void {
        var iter = self.shadow_pages.valueIterator();
        while (iter.next()) |shadow_ptr| {
            self.allocator.destroy(shadow_ptr.*);
        }
        self.shadow_pages.deinit();
    }

    pub fn begin(self: *Transaction) !void {
        if (self.state == .active) {
            return error.TransactionAlreadyActive;
        }
        self.state = .active;
        print("[TXN] BEGIN\n", .{});
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

        self.state = .none;
        print("[TXN] COMMIT\n", .{});
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

        self.state = .none;
        print("[TXN] ROLLBACK\n", .{});
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
};
