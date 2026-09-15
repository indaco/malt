//! One-time adoption of cask artefacts and tap archives written to
//! `{prefix}/cache/{Cask,Tap}` before the tier honoured `MALT_CACHE`.
//! Once the override is set nothing reads that tree, so without this the
//! files are invisible to every sweep and to an offline rollback.

const std = @import("std");

/// Move every legacy artefact under `cache_dir`. Best-effort and
/// idempotent: a no-op when `cache_dir` is the legacy directory itself
/// (override unset), and a file already at the destination wins.
pub fn adoptLegacy(io: std.Io, prefix: []const u8, cache_dir: []const u8) void {
    var legacy_buf: [512]u8 = undefined;
    // The pre-override layout, spelled out on purpose: this is its one reader.
    const legacy_root = std.fmt.bufPrint(&legacy_buf, "{s}/cache", .{prefix}) catch return;
    if (sameDir(io, legacy_root, cache_dir)) return;
    inline for (.{ "Cask", "Tap" }) |tier| adoptTier(io, legacy_root, cache_dir, tier);
}

fn adoptTier(io: std.Io, legacy_root: []const u8, cache_dir: []const u8, tier: []const u8) void {
    var legacy_buf: [512]u8 = undefined;
    const legacy = std.fmt.bufPrint(&legacy_buf, "{s}/{s}", .{ legacy_root, tier }) catch return;
    var dest_buf: [512]u8 = undefined;
    const dest = std.fmt.bufPrint(&dest_buf, "{s}/{s}", .{ cache_dir, tier }) catch return;

    var src_dir = std.Io.Dir.openDirAbsolute(io, legacy, .{ .iterate = true }) catch return;
    defer src_dir.close(io);
    std.Io.Dir.cwd().createDirPath(io, dest) catch return;

    var it = src_dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        var from_buf: [std.fs.max_path_bytes]u8 = undefined;
        const from = std.fmt.bufPrint(&from_buf, "{s}/{s}", .{ legacy, entry.name }) catch continue;
        var to_buf: [std.fs.max_path_bytes]u8 = undefined;
        const to = std.fmt.bufPrint(&to_buf, "{s}/{s}", .{ dest, entry.name }) catch continue;
        if (std.Io.Dir.accessAbsolute(io, to, .{})) |_| {
            std.Io.Dir.cwd().deleteFile(io, from) catch {};
        } else |_| {
            moveFile(io, from, to) catch {};
        }
    }
    // Only succeeds once emptied; a leftover subdirectory keeps it, harmlessly.
    std.Io.Dir.cwd().deleteDir(io, legacy) catch {};
}

/// True when both paths resolve to one directory — the override-unset
/// case, where moving the tree onto itself would delete the only copy
/// in the "destination wins" branch.
fn sameDir(io: std.Io, a_path: []const u8, b_path: []const u8) bool {
    var a_dir = std.Io.Dir.openDirAbsolute(io, a_path, .{}) catch return false;
    defer a_dir.close(io);
    var b_dir = std.Io.Dir.openDirAbsolute(io, b_path, .{}) catch return false;
    defer b_dir.close(io);
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const na = std.Io.Dir.realPath(a_dir, io, &a) catch return false;
    const nb = std.Io.Dir.realPath(b_dir, io, &b) catch return false;
    return std.mem.eql(u8, a[0..na], b[0..nb]);
}

/// rename(2), or copy-then-unlink when `to` sits on another volume. The
/// copy publishes through a temp file next to `to`, so the destination
/// name appears whole or not at all.
pub fn moveFile(io: std.Io, from: []const u8, to: []const u8) !void {
    std.Io.Dir.renameAbsolute(from, to, io) catch |e| switch (e) {
        error.CrossDevice => {
            try std.Io.Dir.copyFileAbsolute(from, to, io, .{});
            std.Io.Dir.cwd().deleteFile(io, from) catch {};
        },
        else => return e,
    };
}

// ─── inline test scratch ──────────────────────────────────────────────

const dbg_io = std.Options.debug_io;

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Process- and call-unique scratch tree so overlapping runs never share a path.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        std.Io.Dir.cwd().deleteTree(dbg_io, base) catch {};
        return .{ .arena = arena, .base = base };
    }

    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(self.arena.allocator(), "{s}{s}", .{ self.base, sub }, 0) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        std.Io.Dir.cwd().deleteTree(dbg_io, self.base) catch {};
        self.arena.deinit();
    }
};

fn putFile(path: []const u8, body: []const u8) !void {
    const f = try std.Io.Dir.createFileAbsolute(dbg_io, path, .{});
    defer f.close(dbg_io);
    try f.writeStreamingAll(dbg_io, body);
}

fn readSmall(path: []const u8, buf: []u8) ![]const u8 {
    const f = try std.Io.Dir.openFileAbsolute(dbg_io, path, .{});
    defer f.close(dbg_io);
    return buf[0..try f.readPositionalAll(dbg_io, buf, 0)];
}

test "adoptLegacy moves both tiers under the override and clears the legacy dirs" {
    var s = try Scratch.init("artefact_adopt");
    defer s.deinit();
    try std.Io.Dir.cwd().createDirPath(dbg_io, s.p("/cache/Cask"));
    try std.Io.Dir.cwd().createDirPath(dbg_io, s.p("/cache/Tap"));
    try putFile(s.p("/cache/Cask/flux-2.0.dmg"), "dmg");
    try putFile(s.p("/cache/Cask/flux-2.0.fonts"), "spec");
    try putFile(s.p("/cache/Tap/" ++ "ab" ** 32 ++ ".tar.gz"), "tgz");

    // The override does not exist yet: the first mutating command creates it.
    adoptLegacy(dbg_io, s.base, s.p("/alt"));

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("dmg", try readSmall(s.p("/alt/Cask/flux-2.0.dmg"), &buf));
    try std.testing.expectEqualStrings("spec", try readSmall(s.p("/alt/Cask/flux-2.0.fonts"), &buf));
    try std.testing.expectEqualStrings("tgz", try readSmall(s.p("/alt/Tap/" ++ "ab" ** 32 ++ ".tar.gz"), &buf));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(dbg_io, s.p("/cache/Cask"), .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(dbg_io, s.p("/cache/Tap"), .{}));
}

test "adoptLegacy keeps the file already under the override and drops the legacy copy" {
    // A re-download under the override is the live one; the legacy copy
    // may be stale (no-sha casks re-fetch), so it must not overwrite.
    var s = try Scratch.init("artefact_adopt_dest_wins");
    defer s.deinit();
    try std.Io.Dir.cwd().createDirPath(dbg_io, s.p("/cache/Cask"));
    try std.Io.Dir.cwd().createDirPath(dbg_io, s.p("/alt/Cask"));
    try putFile(s.p("/cache/Cask/flux-2.0.dmg"), "old");
    try putFile(s.p("/alt/Cask/flux-2.0.dmg"), "new");

    adoptLegacy(dbg_io, s.base, s.p("/alt"));

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("new", try readSmall(s.p("/alt/Cask/flux-2.0.dmg"), &buf));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(dbg_io, s.p("/cache/Cask/flux-2.0.dmg"), .{}));
}

test "adoptLegacy is a no-op when the override is unset" {
    // `cache_dir` IS the legacy directory: moving onto itself would hit
    // the destination-wins branch and delete the only copy.
    var s = try Scratch.init("artefact_adopt_same_dir");
    defer s.deinit();
    try std.Io.Dir.cwd().createDirPath(dbg_io, s.p("/cache/Cask"));
    try putFile(s.p("/cache/Cask/flux-2.0.dmg"), "dmg");

    adoptLegacy(dbg_io, s.base, s.p("/cache"));
    adoptLegacy(dbg_io, s.base, s.p("/cache/"));

    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("dmg", try readSmall(s.p("/cache/Cask/flux-2.0.dmg"), &buf));
}

test "adoptLegacy leaves a legacy subdirectory alone and still empties the files" {
    var s = try Scratch.init("artefact_adopt_subdir");
    defer s.deinit();
    try std.Io.Dir.cwd().createDirPath(dbg_io, s.p("/cache/Tap/nested"));
    try putFile(s.p("/cache/Tap/" ++ "cd" ** 32 ++ ".zip"), "zip");

    adoptLegacy(dbg_io, s.base, s.p("/alt"));

    try std.Io.Dir.accessAbsolute(dbg_io, s.p("/alt/Tap/" ++ "cd" ** 32 ++ ".zip"), .{});
    try std.Io.Dir.accessAbsolute(dbg_io, s.p("/cache/Tap/nested"), .{});
}

test "adoptLegacy with no legacy tree touches nothing" {
    var s = try Scratch.init("artefact_adopt_absent");
    defer s.deinit();
    adoptLegacy(dbg_io, s.base, s.p("/alt"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(dbg_io, s.p("/alt"), .{}));
}
