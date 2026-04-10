//! malt — purge command tests
//! Covers the pure helpers (parseArgs, buildPlan, formatBytes) plus a
//! filesystem-level check that the plan, when applied with
//! std.fs.deleteTreeAbsolute, actually removes every target path under
//! a throwaway prefix built in /tmp.  The execute() function is NOT
//! exercised here because it touches global output state, stdin, and
//! the real database — covered by manual end-to-end runs instead.

const std = @import("std");
const testing = std.testing;
const purge = @import("malt").purge;

// ── parseArgs ────────────────────────────────────────────────────────────

test "parseArgs returns defaults for an empty argv" {
    const opts = try purge.parseArgs(&.{});
    try testing.expectEqual(false, opts.keep_cache);
    try testing.expectEqual(false, opts.yes);
    try testing.expectEqual(false, opts.remove_binary);
    try testing.expectEqual(@as(?[]const u8, null), opts.backup_path);
}

test "parseArgs recognises every long flag" {
    const argv = [_][]const u8{ "--keep-cache", "--yes", "--remove-binary" };
    const opts = try purge.parseArgs(&argv);
    try testing.expect(opts.keep_cache);
    try testing.expect(opts.yes);
    try testing.expect(opts.remove_binary);
}

test "parseArgs recognises short aliases" {
    const argv = [_][]const u8{"-y"};
    const opts = try purge.parseArgs(&argv);
    try testing.expect(opts.yes);
}

test "parseArgs reads --backup with a separate value" {
    const argv = [_][]const u8{ "--backup", "/tmp/snap.txt" };
    const opts = try purge.parseArgs(&argv);
    try testing.expectEqualStrings("/tmp/snap.txt", opts.backup_path.?);
}

test "parseArgs reads --backup=<path>" {
    const argv = [_][]const u8{"--backup=/tmp/snap.txt"};
    const opts = try purge.parseArgs(&argv);
    try testing.expectEqualStrings("/tmp/snap.txt", opts.backup_path.?);
}

test "parseArgs reads -b <path>" {
    const argv = [_][]const u8{ "-b", "/tmp/snap.txt" };
    const opts = try purge.parseArgs(&argv);
    try testing.expectEqualStrings("/tmp/snap.txt", opts.backup_path.?);
}

test "parseArgs errors when --backup lacks a value" {
    const argv = [_][]const u8{"--backup"};
    try testing.expectError(purge.Error.InvalidArgs, purge.parseArgs(&argv));
}

test "parseArgs errors on unknown flags" {
    const argv = [_][]const u8{"--nope"};
    try testing.expectError(purge.Error.InvalidArgs, purge.parseArgs(&argv));
}

test "parseArgs rejects positional arguments" {
    // purge takes no positional args — stray tokens should error, not be
    // silently accepted as package names.
    const argv = [_][]const u8{"git"};
    try testing.expectError(purge.Error.InvalidArgs, purge.parseArgs(&argv));
}

// ── buildPlan ────────────────────────────────────────────────────────────

fn findCategory(plan: []const purge.Target, cat: purge.Category) ?usize {
    for (plan, 0..) |t, i| {
        if (t.category == cat) return i;
    }
    return null;
}

fn countCategory(plan: []const purge.Target, cat: purge.Category) usize {
    var n: usize = 0;
    for (plan) |t| {
        if (t.category == cat) n += 1;
    }
    return n;
}

test "buildPlan includes every core prefix target by default" {
    const opts: purge.Options = .{};
    const plan = try purge.buildPlan(testing.allocator, opts, "/tmp/mt-fake", "/tmp/mt-fake/cache");
    defer purge.freePlan(testing.allocator, plan);

    // Core categories that must always be present.
    try testing.expect(findCategory(plan, .cellar) != null);
    try testing.expect(findCategory(plan, .caskroom) != null);
    try testing.expect(findCategory(plan, .store) != null);
    try testing.expect(findCategory(plan, .opt) != null);
    try testing.expect(findCategory(plan, .cache) != null);
    try testing.expect(findCategory(plan, .tmp) != null);
    try testing.expect(findCategory(plan, .db) != null);
    try testing.expect(findCategory(plan, .prefix_root) != null);

    // Six standard linked dirs: bin, sbin, lib, include, share, etc.
    try testing.expectEqual(@as(usize, 6), countCategory(plan, .linked_dir));

    // No binary targets without --remove-binary.
    try testing.expectEqual(@as(usize, 0), countCategory(plan, .binary));
}

test "buildPlan omits the cache target when --keep-cache is set" {
    const opts: purge.Options = .{ .keep_cache = true };
    const plan = try purge.buildPlan(testing.allocator, opts, "/tmp/mt-fake", "/tmp/mt-fake/cache");
    defer purge.freePlan(testing.allocator, plan);
    try testing.expectEqual(@as(usize, 0), countCategory(plan, .cache));
}

test "buildPlan adds both binary paths when --remove-binary is set" {
    const opts: purge.Options = .{ .remove_binary = true };
    const plan = try purge.buildPlan(testing.allocator, opts, "/tmp/mt-fake", "/tmp/mt-fake/cache");
    defer purge.freePlan(testing.allocator, plan);

    try testing.expectEqual(@as(usize, 2), countCategory(plan, .binary));

    var found_mt = false;
    var found_malt = false;
    for (plan) |t| {
        if (t.category != .binary) continue;
        if (std.mem.eql(u8, t.path, "/usr/local/bin/mt")) found_mt = true;
        if (std.mem.eql(u8, t.path, "/usr/local/bin/malt")) found_malt = true;
    }
    try testing.expect(found_mt);
    try testing.expect(found_malt);
}

test "buildPlan orders the db target after the store target" {
    // The lock file lives under {prefix}/db, so `db` must be the last
    // in-prefix target so execute() can drop the lock before unlinking it.
    const opts: purge.Options = .{};
    const plan = try purge.buildPlan(testing.allocator, opts, "/tmp/mt-fake", "/tmp/mt-fake/cache");
    defer purge.freePlan(testing.allocator, plan);

    const store_idx = findCategory(plan, .store).?;
    const db_idx = findCategory(plan, .db).?;
    const prefix_idx = findCategory(plan, .prefix_root).?;
    try testing.expect(store_idx < db_idx);
    try testing.expect(db_idx < prefix_idx);
}

test "buildPlan uses the passed cache_dir path literally" {
    // Lets callers point purge at $MALT_CACHE values that live outside
    // {prefix}. If this test fails, a custom cache location would leak.
    const opts: purge.Options = .{};
    const plan = try purge.buildPlan(testing.allocator, opts, "/tmp/mt-fake", "/var/tmp/malt-cache-xyz");
    defer purge.freePlan(testing.allocator, plan);
    const cache_idx = findCategory(plan, .cache).?;
    try testing.expectEqualStrings("/var/tmp/malt-cache-xyz", plan[cache_idx].path);
}

test "buildPlan produces absolute paths for every target" {
    const opts: purge.Options = .{ .remove_binary = true };
    const plan = try purge.buildPlan(testing.allocator, opts, "/tmp/mt-fake", "/tmp/mt-fake/cache");
    defer purge.freePlan(testing.allocator, plan);
    for (plan) |t| {
        try testing.expect(std.fs.path.isAbsolute(t.path));
    }
}

// ── formatBytes ──────────────────────────────────────────────────────────

test "formatBytes renders common magnitudes" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0.0 B", purge.formatBytes(0, &buf));
    try testing.expectEqualStrings("512.0 B", purge.formatBytes(512, &buf));
    try testing.expectEqualStrings("1.0 KB", purge.formatBytes(1024, &buf));
    try testing.expectEqualStrings("1.5 KB", purge.formatBytes(1536, &buf));
    try testing.expectEqualStrings("1.0 MB", purge.formatBytes(1024 * 1024, &buf));
    try testing.expectEqualStrings("2.0 GB", purge.formatBytes(2 * 1024 * 1024 * 1024, &buf));
}

test "formatBytes caps at TB and never overflows the buffer" {
    var buf: [32]u8 = undefined;
    const huge: u64 = 5 * 1024 * 1024 * 1024 * 1024; // 5 TB
    const s = purge.formatBytes(huge, &buf);
    try testing.expect(std.mem.endsWith(u8, s, "TB"));
}

// ── Filesystem-level plan application ────────────────────────────────────
// Pre-populate a temp prefix with the directory layout that purge expects,
// then call std.fs.deleteTreeAbsolute on each plan target and verify that
// everything is gone.  This covers the deletion ordering that execute()
// relies on without requiring stdin, sqlite, or the global output state.

fn makeDir(path: []const u8) !void {
    std.fs.makeDirAbsolute(path) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
}

fn makeFile(path: []const u8, content: []const u8) !void {
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "applying the plan removes every pre-populated directory under a temp prefix" {
    const allocator = testing.allocator;

    // Unique temp prefix — std.crypto random bytes keep parallel runs safe.
    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var hex_buf: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }

    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "/tmp/malt-purge-test-{s}", .{&hex_buf});

    // Best-effort cleanup in case a prior run aborted mid-way.
    std.fs.deleteTreeAbsolute(prefix) catch {};
    try makeDir(prefix);
    defer std.fs.deleteTreeAbsolute(prefix) catch {};

    // Populate the directories the plan will target.
    const subdirs = [_][]const u8{
        "bin",      "sbin",  "lib",   "include",
        "share",    "etc",   "opt",   "Cellar",
        "Caskroom", "store", "cache", "tmp",
        "db",
    };
    for (subdirs) |name| {
        var sub_buf: [256]u8 = undefined;
        const sub = try std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ prefix, name });
        try makeDir(sub);
        // Drop a file inside so the directory isn't empty — exercises
        // deleteTree's recursive branch, not the fast path.
        var file_buf: [256]u8 = undefined;
        const file = try std.fmt.bufPrint(&file_buf, "{s}/marker", .{sub});
        try makeFile(file, "x");
    }

    // Build the plan pointing at the temp prefix (cache stays in-prefix).
    var cache_buf: [256]u8 = undefined;
    const cache_dir = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{prefix});

    const plan = try purge.buildPlan(allocator, .{}, prefix, cache_dir);
    defer purge.freePlan(allocator, plan);

    // Apply the plan in order (skipping .prefix_root; we verify it separately).
    for (plan) |t| {
        if (t.category == .prefix_root) continue;
        std.fs.deleteTreeAbsolute(t.path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }

    // Every target except the prefix root must now be gone.
    for (plan) |t| {
        if (t.category == .prefix_root) continue;
        try testing.expect(!pathExists(t.path));
    }

    // Prefix itself should be empty — a final deleteDirAbsolute succeeds.
    try std.fs.deleteDirAbsolute(prefix);
    try testing.expect(!pathExists(prefix));
}

test "applying the plan with --keep-cache leaves the cache directory intact" {
    const allocator = testing.allocator;

    var rand_bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_bytes);
    var hex_buf: [16]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (rand_bytes, 0..) |b, i| {
        hex_buf[i * 2] = hex_chars[b >> 4];
        hex_buf[i * 2 + 1] = hex_chars[b & 0x0f];
    }

    var prefix_buf: [128]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "/tmp/malt-purge-keepcache-{s}", .{&hex_buf});
    std.fs.deleteTreeAbsolute(prefix) catch {};
    try makeDir(prefix);
    defer std.fs.deleteTreeAbsolute(prefix) catch {};

    // Pre-create cache, Cellar, and db — enough to prove the kept path
    // survives while deleted paths do not.
    var cache_buf: [256]u8 = undefined;
    const cache_dir = try std.fmt.bufPrint(&cache_buf, "{s}/cache", .{prefix});
    try makeDir(cache_dir);

    var cellar_buf: [256]u8 = undefined;
    const cellar_dir = try std.fmt.bufPrint(&cellar_buf, "{s}/Cellar", .{prefix});
    try makeDir(cellar_dir);
    var marker_buf: [256]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "{s}/CANARY", .{cache_dir});
    try makeFile(marker, "keep me");

    const plan = try purge.buildPlan(allocator, .{ .keep_cache = true }, prefix, cache_dir);
    defer purge.freePlan(allocator, plan);

    for (plan) |t| {
        if (t.category == .prefix_root) continue;
        std.fs.deleteTreeAbsolute(t.path) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }

    // Cache must still exist and still contain the canary file.
    try testing.expect(pathExists(cache_dir));
    try testing.expect(pathExists(marker));
    // Cellar must be gone.
    try testing.expect(!pathExists(cellar_dir));
}
