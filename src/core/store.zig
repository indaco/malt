const std = @import("std");
const sqlite = @import("../db/sqlite.zig");
const atomic = @import("../fs/atomic.zig");
const testing = std.testing;
const schema = @import("../db/schema.zig");

pub const StoreError = error{ CommitFailed, RemoveFailed, NotFound, OutOfMemory, RefCountError };

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *sqlite.Database,
    prefix: []const u8,
    /// Serializes write operations (commitFrom, incrementRef, decrementRef)
    /// across parallel download workers. exists() is read-only and safe without lock.
    mutex: std.Io.Mutex,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, db: *sqlite.Database, prefix: []const u8) Store {
        return .{ .allocator = allocator, .io = io, .db = db, .prefix = prefix, .mutex = .init };
    }

    /// Atomic rename from tmp/{sha256} to store/{sha256}. Idempotent.
    /// Atomic rename from a source path to store/{sha256}. Idempotent.
    /// If src_path is null, defaults to {prefix}/tmp/{sha256}.
    pub fn commit(self: *Store, sha256: []const u8) StoreError!void {
        return self.commitFrom(sha256, null);
    }

    /// Atomic rename from a specific source path to store/{sha256}. Idempotent.
    /// Thread-safe: serialized by internal mutex.
    pub fn commitFrom(self: *Store, sha256: []const u8, src_path: ?[]const u8) StoreError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        // src_buf must outlive any subsequent stack-buf write below — if a
        // future optimizer overlays it with dst_buf, the rename target
        // could be clobbered.
        var src_buf: [512]u8 = undefined;
        var dst_buf: [512]u8 = undefined;
        const src = src_path orelse std.fmt.bufPrint(&src_buf, "{s}/tmp/{s}", .{ self.prefix, sha256 }) catch return StoreError.OutOfMemory;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/store/{s}", .{ self.prefix, sha256 }) catch return StoreError.OutOfMemory;

        // Check if already committed (idempotent)
        std.Io.Dir.cwd().access(self.io, dst, .{}) catch {
            // Not exists — do the rename
            atomic.atomicRename(self.io, self.allocator, src, dst) catch return StoreError.CommitFailed;
            return;
        };
        // Already exists — idempotent success
    }

    pub fn exists(self: *Store, sha256: []const u8) bool {
        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/store/{s}", .{ self.prefix, sha256 }) catch return false;
        std.Io.Dir.cwd().access(self.io, p, .{}) catch return false;
        return true;
    }

    pub fn path(self: *Store, sha256: []const u8) StoreError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/store/{s}", .{ self.prefix, sha256 }) catch return StoreError.OutOfMemory;
    }

    /// Removes both the on-disk path AND the store_refs row.  Without the
    /// row delete, refcount-0 rows keep returning from `orphans()` on every
    /// purge run — the bug `doctor --fix` already worked around.  deleteTree
    /// is a no-op on a missing path, so phantom rows still trigger DB cleanup.
    /// The DB delete runs inside an immediate transaction so concurrent
    /// readers never observe a half-resolved store_refs state.
    pub fn remove(self: *Store, sha256: []const u8) StoreError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var buf: [512]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/store/{s}", .{ self.prefix, sha256 }) catch return StoreError.OutOfMemory;

        self.db.beginTransaction() catch return StoreError.RefCountError;
        errdefer self.db.rollback();

        std.Io.Dir.cwd().deleteTree(self.io, p) catch return StoreError.RemoveFailed;

        var stmt = self.db.prepare("DELETE FROM store_refs WHERE store_sha256 = ?1;") catch return StoreError.RefCountError;
        defer stmt.finalize();
        stmt.bindText(1, sha256) catch return StoreError.RefCountError;
        _ = stmt.step() catch return StoreError.RefCountError;

        self.db.commit() catch return StoreError.RefCountError;
    }

    pub fn incrementRef(self: *Store, sha256: []const u8) StoreError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var stmt = self.db.prepare(
            "INSERT INTO store_refs (store_sha256, refcount) VALUES (?1, 1)" ++
                " ON CONFLICT(store_sha256) DO UPDATE SET refcount = refcount + 1;",
        ) catch return StoreError.RefCountError;
        defer stmt.finalize();
        stmt.bindText(1, sha256) catch return StoreError.RefCountError;
        _ = stmt.step() catch return StoreError.RefCountError;
    }

    pub fn decrementRef(self: *Store, sha256: []const u8) StoreError!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
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
        errdefer {
            for (list.items) |item| self.allocator.free(item);
            list.deinit(self.allocator);
        }
        var stmt = self.db.prepare(
            "SELECT store_sha256 FROM store_refs WHERE refcount <= 0;",
        ) catch return StoreError.RefCountError;
        defer stmt.finalize();

        while (stmt.step() catch return StoreError.RefCountError) {
            const sha = stmt.columnText(0) orelse continue;
            const owned = self.allocator.dupe(u8, std.mem.sliceTo(sha, 0)) catch
                return StoreError.OutOfMemory;
            list.append(self.allocator, owned) catch {
                self.allocator.free(owned);
                return StoreError.OutOfMemory;
            };
        }
        return list;
    }
};

fn openSchemaDb() !sqlite.Database {
    var db = try sqlite.Database.open(":memory:");
    errdefer db.close();
    try schema.initSchema(&db);
    return db;
}

test "orphans surfaces a prepare failure as RefCountError, not an empty list" {
    var db = try openSchemaDb();
    defer db.close();
    // Drop the table the SELECT targets so prepare fails loud.
    try db.exec("DROP TABLE store_refs;");

    var store = Store.init(std.Options.debug_io, testing.allocator, &db, "");
    try testing.expectError(StoreError.RefCountError, store.orphans());
}

test "orphans frees the duplicated sha and returns OutOfMemory when the append fails" {
    var db = try openSchemaDb();
    defer db.close();
    try db.exec("INSERT INTO store_refs (store_sha256, refcount) VALUES ('a', 0);");

    // fail_index 1: the dupe (alloc #0) succeeds, the list's first growth (#1)
    // fails - so a dropped `owned` is a real leak the base allocator catches.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var store = Store.init(std.Options.debug_io, failing.allocator(), &db, "");
    try testing.expectError(StoreError.OutOfMemory, store.orphans());
}

test "orphans frees already-collected shas via errdefer on a mid-scan OOM" {
    var db = try openSchemaDb();
    defer db.close();
    try db.exec("INSERT INTO store_refs (store_sha256, refcount) VALUES ('a', 0), ('b', 0);");

    // fail_index 2: row 'a' is dupe'd (#0) and appended (#1); the second row's
    // dupe (#2) fails, so the errdefer must free the already-collected 'a'.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var store = Store.init(std.Options.debug_io, failing.allocator(), &db, "");
    try testing.expectError(StoreError.OutOfMemory, store.orphans());
}

test "orphans skips a NULL store_sha256 row and still returns the real orphan" {
    var db = try openSchemaDb();
    defer db.close();
    // SQLite permits NULL in a TEXT PRIMARY KEY that isn't NOT NULL, so the
    // `columnText orelse continue` branch is reachable, not dead.
    try db.exec("INSERT INTO store_refs (store_sha256, refcount) VALUES (NULL, 0), ('real', 0);");

    var store = Store.init(std.Options.debug_io, testing.allocator, &db, "");
    var list = try store.orphans();
    defer {
        for (list.items) |item| testing.allocator.free(item);
        list.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqualStrings("real", list.items[0]);
}

test "orphans returns exactly the refcount-zero rows and skips referenced rows" {
    var db = try openSchemaDb();
    defer db.close();
    try db.exec(
        "INSERT INTO store_refs (store_sha256, refcount) VALUES ('zero_a', 0), ('zero_b', 0), ('held', 3);",
    );

    var store = Store.init(std.Options.debug_io, testing.allocator, &db, "");
    var list = try store.orphans();
    defer {
        for (list.items) |item| testing.allocator.free(item);
        list.deinit(testing.allocator);
    }
    try testing.expectEqual(@as(usize, 2), list.items.len);
}
