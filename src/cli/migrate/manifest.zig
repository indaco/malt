//! Resume manifest for `mt migrate`. Records successfully migrated keg
//! names so a re-run after crash, ^C, or partial failure skips work
//! already done. Append-on-success — durability matters more than
//! shrinking the file when an entry is rolled back.

const std = @import("std");
const AppCtx = @import("../../app_ctx.zig").AppCtx;
const atomic = @import("../../fs/atomic.zig");
const output = @import("../../ui/output.zig");

/// Bounds adversarial / corrupt files at parse time (8 MiB ≫ any real
/// migrate manifest).
pub const max_manifest_bytes: usize = 8 * 1024 * 1024;

/// Owns its strings via the caller's allocator so lifetime is explicit.
pub const Manifest = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Manifest {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Manifest) void {
        for (self.entries.items) |e| self.allocator.free(e);
        self.entries.deinit(self.allocator);
    }

    /// True iff `name` is recorded as completed.
    pub fn contains(self: *const Manifest, name: []const u8) bool {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e, name)) return true;
        }
        return false;
    }

    /// Add `name` to the in-memory set. Idempotent: a duplicate add is a no-op.
    pub fn add(self: *Manifest, name: []const u8) !void {
        if (self.contains(name)) return;
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.entries.append(self.allocator, owned);
    }

    /// Borrowed view of the completed names. Slices alias `entries`.
    pub fn names(self: *const Manifest) []const []const u8 {
        // ArrayList([]u8) → []const []const u8 — same layout, narrower view.
        return @ptrCast(self.entries.items);
    }

    /// Crash-safe rewrite via tempfile + rename: readers see old or new, never partial.
    pub fn writeAtomic(self: *const Manifest, io: std.Io, allocator: std.mem.Allocator, path: []const u8) !void {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        try writeJson(&aw.writer, self.names());
        try atomic.atomicWriteFile(io, path, aw.written());
    }
};

/// Bump when a future change isn't backward-readable; older binaries
/// refuse to load rather than mis-parse.
pub const schema_version: u32 = 1;

/// Empty-file and missing-key cases both yield an empty manifest so
/// first-run callers don't need to special-case them.
pub fn parseJson(allocator: std.mem.Allocator, bytes: []const u8) !Manifest {
    var m = Manifest.init(allocator);
    errdefer m.deinit();

    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len == 0) return m;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
        return error.InvalidManifest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidManifest;
    const root = parsed.value.object;

    if (root.get("version")) |v| {
        if (v != .integer or v.integer != schema_version) {
            return error.UnsupportedManifestVersion;
        }
    }

    const completed = root.get("completed") orelse return m;
    if (completed != .array) return error.InvalidManifest;
    for (completed.array.items) |entry| {
        if (entry != .string) return error.InvalidManifest;
        try m.add(entry.string);
    }
    return m;
}

/// Reuses `output.jsonStringArray` so manifest and migrate-summary JSON
/// share one escape implementation and can't drift apart.
pub fn writeJson(w: *std.Io.Writer, names: []const []const u8) !void {
    try w.print("{{\"version\":{d},\"completed\":", .{schema_version});
    try output.jsonStringArray(w, names);
    try w.writeAll("}\n");
}

/// Missing file is treated as empty so first-run callers don't need
/// to special-case it.
pub fn loadFromPath(ctx: *const AppCtx, allocator: std.mem.Allocator, path: []const u8) !Manifest {
    const file = std.Io.Dir.openFileAbsolute(ctx.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return Manifest.init(allocator),
        else => return err,
    };
    defer file.close(ctx.io);
    const st = try file.stat(ctx.io);
    const size: usize = @intCast(@min(@as(u64, max_manifest_bytes), st.size));
    const buf = try allocator.alloc(u8, size);
    const n = file.readPositionalAll(ctx.io, buf, 0) catch |err| {
        allocator.free(buf);
        return err;
    };
    const bytes = if (n == buf.len) buf else blk: {
        if (allocator.resize(buf, n)) break :blk buf[0..n];
        const trimmed = allocator.alloc(u8, n) catch |e| {
            allocator.free(buf);
            return e;
        };
        @memcpy(trimmed, buf[0..n]);
        allocator.free(buf);
        break :blk trimmed;
    };
    defer allocator.free(bytes);
    return parseJson(allocator, bytes);
}

// ── Pure-helper unit tests ──────────────────────────────────────────

test "Manifest.contains is false before any add and true after" {
    var m = Manifest.init(std.testing.allocator);
    defer m.deinit();
    try std.testing.expect(!m.contains("foo"));
    try m.add("foo");
    try std.testing.expect(m.contains("foo"));
    try std.testing.expect(!m.contains("bar"));
}

test "Manifest.add is idempotent" {
    var m = Manifest.init(std.testing.allocator);
    defer m.deinit();
    try m.add("foo");
    try m.add("foo");
    try std.testing.expectEqual(@as(usize, 1), m.entries.items.len);
}

test "writeJson emits version + completed array" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const names = [_][]const u8{ "tree", "wget" };
    try writeJson(&aw.writer, &names);

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("version").?.integer);
    const arr = root.get("completed").?.array;
    try std.testing.expectEqual(@as(usize, 2), arr.items.len);
    try std.testing.expectEqualStrings("tree", arr.items[0].string);
    try std.testing.expectEqualStrings("wget", arr.items[1].string);
}

test "parseJson round-trips writeJson" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const names = [_][]const u8{ "foo", "bar", "baz" };
    try writeJson(&aw.writer, &names);

    var m = try parseJson(std.testing.allocator, aw.written());
    defer m.deinit();
    try std.testing.expect(m.contains("foo"));
    try std.testing.expect(m.contains("bar"));
    try std.testing.expect(m.contains("baz"));
    try std.testing.expect(!m.contains("missing"));
}

test "parseJson tolerates empty input as empty manifest" {
    var m = try parseJson(std.testing.allocator, "");
    defer m.deinit();
    try std.testing.expect(!m.contains("anything"));
}

test "parseJson rejects future schema versions" {
    const m_or_err = parseJson(std.testing.allocator, "{\"version\":99,\"completed\":[]}");
    try std.testing.expectError(error.UnsupportedManifestVersion, m_or_err);
}

test "parseJson surfaces invalid JSON as an error rather than silently dropping it" {
    const m_or_err = parseJson(std.testing.allocator, "not json");
    try std.testing.expectError(error.InvalidManifest, m_or_err);
}
