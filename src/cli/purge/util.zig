//! malt — purge shared helpers (allocator-free formatting, stat walking,
//! db open, confirmation prompts) used by both `wipe` and `scopes`.

const std = @import("std");
const sqlite = @import("../../db/sqlite.zig");
const output = @import("../../ui/output.zig");
const args_mod = @import("args.zig");

pub const Error = args_mod.Error;

pub const TierResult = struct {
    removed: u32 = 0,
    bytes: u64 = 0,
};

pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit: usize = 0;
    while (value >= 1024.0 and unit + 1 < units.len) {
        value /= 1024.0;
        unit += 1;
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

pub fn pathSize(io: std.Io, allocator: std.mem.Allocator, path: []const u8) u64 {
    if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
        if (st.kind != .directory) return st.size;
    } else |_| {}

    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);

    var walker = dir.walk(allocator) catch return 0;
    defer walker.deinit();

    var total: u64 = 0;
    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .file) {
            const s = std.Io.Dir.statFile(entry.dir, io, entry.basename, .{}) catch continue;
            total += s.size;
        }
    }
    return total;
}

pub fn openDb(prefix: []const u8) ?sqlite.Database {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return null;
    return sqlite.Database.open(db_path) catch null;
}

/// Tri-state DB open: distinguishes "fresh prefix, nothing yet" from
/// "the file is there but cannot be opened" (corruption, permissions).
/// Callers route the two to different UX paths — soft skip vs loud err.
pub const DbOutcome = union(enum) {
    absent,
    unreadable: sqlite.SqliteError,
    opened: sqlite.Database,
};

pub fn openDbTri(io: std.Io, prefix: []const u8) DbOutcome {
    var db_path_buf: [512]u8 = undefined;
    const db_path = std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0) catch return .absent;
    // Probe for prior existence: SQLite's OPEN_CREATE flag would mask
    // the difference between "no DB yet" and "file is there but dead".
    const pre_existed = blk: {
        std.Io.Dir.accessAbsolute(io, db_path, .{}) catch break :blk false;
        break :blk true;
    };
    if (sqlite.Database.open(db_path)) |db| {
        return .{ .opened = db };
    } else |e| {
        return if (pre_existed) .{ .unreadable = e } else .absent;
    }
}

pub fn confirmScope(yes: bool, expected: []const u8, scope_label: []const u8) Error!void {
    if (yes) return;
    var prompt_buf: [128]u8 = undefined;
    const prompt = std.fmt.bufPrint(
        &prompt_buf,
        "Type `{s}` to confirm {s} (anything else aborts): ",
        .{ expected, scope_label },
    ) catch "Type the scope name to confirm: ";
    if (!output.confirmTyped(expected, prompt)) {
        output.info("aborted", .{});
        return Error.UserAborted;
    }
}

pub fn writeStderr(s: []const u8) void {
    output.writeStderrAll(s);
}

// ── inline unit tests ──────────────────────────────────────────────────────
//
// `openDbTri` is the routing seam between "fresh prefix, no DB yet" (soft
// skip — the user just hasn't installed anything) and "the file is there
// but cannot be opened" (loud err — corruption / perms). Drift here would
// hide a real fault behind a misleading "no database" message.

const testing = std.testing;
const fs_test_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(fs_test_io, path) catch {};
}

test "openDbTri returns .absent when the db dir does not exist" {
    // SQLite open would otherwise CREATE a fresh file. The .absent
    // branch only fires when the parent dir is missing AND the file
    // never pre-existed — that's the "fresh prefix" UX contract.
    const prefix = "/tmp/malt_openDbTri_absent";
    rmrf(prefix);
    defer rmrf(prefix);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix);
    // Deliberately do NOT create the db/ subdir.

    var outcome = openDbTri(fs_test_io, prefix);
    switch (outcome) {
        .absent => {},
        .opened => |*db| {
            db.close();
            return error.UnexpectedOpened;
        },
        .unreadable => return error.UnexpectedUnreadable,
    }
}

test "openDbTri returns .unreadable when malt.db is not a valid sqlite file" {
    const prefix = "/tmp/malt_openDbTri_corrupt";
    rmrf(prefix);
    defer rmrf(prefix);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix);
    const db_dir = prefix ++ "/db";
    try std.Io.Dir.cwd().createDirPath(fs_test_io, db_dir);

    // Plant a non-sqlite blob at db/malt.db so the open path fails AFTER
    // the file has been observed to exist — that's the .unreadable branch.
    const db_path = prefix ++ "/db/malt.db";
    const f = try std.Io.Dir.createFileAbsolute(fs_test_io, db_path, .{ .truncate = true });
    defer f.close(fs_test_io);
    try f.writeStreamingAll(fs_test_io, "this is not a valid sqlite header");

    var outcome = openDbTri(fs_test_io, prefix);
    switch (outcome) {
        .unreadable => {},
        .opened => |*db| {
            db.close();
            return error.UnexpectedOpened;
        },
        .absent => return error.UnexpectedAbsent,
    }
}

test "openDbTri opens a freshly created sqlite file" {
    const prefix = "/tmp/malt_openDbTri_ok";
    rmrf(prefix);
    defer rmrf(prefix);
    try std.Io.Dir.cwd().createDirPath(fs_test_io, prefix);
    const db_dir = prefix ++ "/db";
    try std.Io.Dir.cwd().createDirPath(fs_test_io, db_dir);

    // Pre-create a real sqlite file so the open path succeeds.
    {
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
        var db = try sqlite.Database.open(db_path);
        db.close();
    }

    var outcome = openDbTri(fs_test_io, prefix);
    switch (outcome) {
        .opened => |*db| db.close(),
        .absent => return error.UnexpectedAbsent,
        .unreadable => return error.UnexpectedUnreadable,
    }
}

test "formatBytes scales B/KB/MB and caps at TB" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0.0 B", formatBytes(0, &buf));
    try testing.expectEqualStrings("1.0 KB", formatBytes(1024, &buf));
    try testing.expectEqualStrings("1.0 MB", formatBytes(1024 * 1024, &buf));
    const huge: u64 = 5 * 1024 * 1024 * 1024 * 1024;
    try testing.expect(std.mem.endsWith(u8, formatBytes(huge, &buf), "TB"));
}
