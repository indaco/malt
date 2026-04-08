const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");

pub const StoreError = error{ CommitFailed, RemoveFailed, NotFound, OutOfMemory, RefCountError };

pub const Store = struct {
    allocator: std.mem.Allocator,
    db: *sqlite.Database,
    prefix: []const u8,

    pub fn init(allocator: std.mem.Allocator, db: *sqlite.Database, prefix: []const u8) Store {
        return .{ .allocator = allocator, .db = db, .prefix = prefix };
    }

    /// Atomic rename from tmp/{sha256} to store/{sha256}. Idempotent.
    pub fn commit(self: *Store, sha256: []const u8) StoreError!void {
        var src_buf: [512]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/tmp/{s}", .{ self.prefix, sha256 }) catch return StoreError.OutOfMemory;
        var dst_buf: [512]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/store/{s}", .{ self.prefix, sha256 }) catch return StoreError.OutOfMemory;

        // Check if already committed (idempotent)
        std.fs.cwd().access(dst, .{}) catch {
            // Not exists — do the rename
            atomic.atomicRename(src, dst) catch return StoreError.CommitFailed;
            return;
        };
        // Already exists — idempotent success
    }

    pub fn exists(self: *Store, sha256: []const u8) bool {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/store/{s}", .{ self.prefix, sha256 }) catch return false;
        std.fs.cwd().access(p, .{}) catch return false;
        return true;
    }

    pub fn path(self: *Store, sha256: []const u8) StoreError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/store/{s}", .{ self.prefix, sha256 }) catch return StoreError.OutOfMemory;
    }

    pub fn remove(self: *Store, sha256: []const u8) StoreError!void {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/store/{s}", .{ self.prefix, sha256 }) catch return StoreError.OutOfMemory;
        std.fs.deleteTreeAbsolute(p) catch return StoreError.RemoveFailed;
    }

    pub fn incrementRef(self: *Store, sha256: []const u8) StoreError!void {
        var stmt = self.db.prepare(
            "INSERT INTO store_refs (store_sha256, refcount) VALUES (?1, 1)" ++
                " ON CONFLICT(store_sha256) DO UPDATE SET refcount = refcount + 1;",
        ) catch return StoreError.RefCountError;
        defer stmt.finalize();
        stmt.bindText(1, sha256) catch return StoreError.RefCountError;
        _ = stmt.step() catch return StoreError.RefCountError;
    }

    pub fn decrementRef(self: *Store, sha256: []const u8) StoreError!void {
        var stmt = self.db.prepare(
            "UPDATE store_refs SET refcount = refcount - 1 WHERE store_sha256 = ?1 AND refcount > 0;",
        ) catch return StoreError.RefCountError;
        defer stmt.finalize();
        stmt.bindText(1, sha256) catch return StoreError.RefCountError;
        _ = stmt.step() catch return StoreError.RefCountError;
    }

    /// Find store entries with refcount == 0.
    pub fn orphans(self: *Store) StoreError!std.ArrayList([]const u8) {
        var list: std.ArrayList([]const u8) = .empty;
        var stmt = self.db.prepare(
            "SELECT store_sha256 FROM store_refs WHERE refcount <= 0;",
        ) catch return list;
        defer stmt.finalize();

        while (stmt.step() catch null) |has_row| {
            if (!has_row) break;
            const sha = stmt.columnText(0) orelse continue;
            const owned = self.allocator.dupe(u8, std.mem.sliceTo(sha, 0)) catch continue;
            list.append(self.allocator, owned) catch continue;
        }
        return list;
    }
};
