//! malt — parse the on-disk `outdated.json` snapshot into TUI outdated rows.
//!
//! Leaf module: imports only `std` and the sibling `--json` parser. Feeds the
//! Outdated tab a warm paint the instant the dashboard opens, before the live
//! `mt outdated` refresh lands. The snapshot carries no per-row `pinned`/`tap`
//! (both are DB-derived at emit time), so rows come back unpinned and untagged
//! — a provisional view the refresh corrects. Safe: `mt upgrade` enforces pins
//! itself, so an unpinned provisional row can never be upgraded past its pin.

const std = @import("std");
const outdated_json = @import("outdated.zig");

/// The snapshot's per-entry shape: name + versions only. `formulas`/`casks`
/// default so a document missing either array still parses.
const Entry = struct { name: []const u8, installed: []const u8, latest: []const u8 };
const Snapshot = struct { formulas: []Entry = &.{}, casks: []Entry = &.{} };

/// The `--json` wire row the sibling parser reads. `pinned`/`tap` take their
/// safe defaults since the snapshot cannot supply them.
const WireRow = struct {
    name: []const u8,
    installed: []const u8,
    latest: []const u8,
    type: []const u8,
    pinned: bool = false,
    tap: []const u8 = "",
};
const WireDoc = struct { outdated: []const WireRow };

/// Parse snapshot bytes into `outdated_json.Parsed`. Re-emits the snapshot as
/// the `--json` wire shape and delegates to the live parser, so the returned
/// row storage and lifetime match the refresh path byte-for-byte (one `deinit`).
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) outdated_json.Error!outdated_json.Parsed {
    const snap = std.json.parseFromSlice(Snapshot, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch |e| switch (e) {
        error.OutOfMemory => |o| return o,
        else => return error.BadJson,
    };
    defer snap.deinit();

    var rows: std.ArrayList(WireRow) = .empty;
    defer rows.deinit(allocator);
    for (snap.value.formulas) |e| rows.append(allocator, wireRow(e, "formula")) catch return error.OutOfMemory;
    for (snap.value.casks) |e| rows.append(allocator, wireRow(e, "cask")) catch return error.OutOfMemory;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    std.json.Stringify.value(WireDoc{ .outdated = rows.items }, .{}, &aw.writer) catch return error.OutOfMemory;

    // The live parser copies every string into its own arena, so `snap`/`aw`
    // are free to release once it returns.
    return outdated_json.parse(allocator, aw.written());
}

fn wireRow(e: Entry, kind: []const u8) WireRow {
    return .{ .name = e.name, .installed = e.installed, .latest = e.latest, .type = kind };
}

/// Cap the warm-read: a snapshot is a handful of KB, so a larger file is
/// corrupt and not worth loading before the live audit lands.
const read_cap: u64 = 1 << 20;

/// Read `{cache_dir}/outdated.json` and parse it, or null if absent, unreadable,
/// or malformed — the caller then just lets the live audit populate the tab.
pub fn read(io: std.Io, allocator: std.mem.Allocator, cache_dir: []const u8) ?outdated_json.Parsed {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/outdated.json", .{cache_dir}) catch return null;
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    const size: usize = @intCast(@min(read_cap, st.size));
    const bytes = allocator.alloc(u8, size) catch return null;
    defer allocator.free(bytes);
    const n = file.readPositionalAll(io, bytes, 0) catch return null;
    return parse(allocator, bytes[0..n]) catch null;
}

// ─── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

const fs_test_io = std.Options.debug_io;

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Stands in for std.testing.tmpDir, which builds under .zig-cache — a tree the
/// build system owns and rewrites underneath concurrent test runs. The base is
/// process- and call-unique so overlapping runs can't delete each other's
/// fixtures.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,
    dir: std.Io.Dir,

    fn init(comptime tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const raw = try std.fmt.allocPrintSentinel(
            arena.allocator(),
            "/tmp/malt_" ++ tag ++ "_{d}_{d}",
            .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
            0,
        );
        std.Io.Dir.cwd().deleteTree(fs_test_io, raw) catch {};
        try std.Io.Dir.cwd().createDirPath(fs_test_io, raw);
        // /tmp is a symlink to /private/tmp on macOS; resolve once so paths the
        // code under test returns compare equal to `base`.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        var d = try std.Io.Dir.cwd().openDir(fs_test_io, raw, .{});
        errdefer d.close(fs_test_io);
        const n = try std.Io.Dir.realPath(d, fs_test_io, &buf);
        const base = try arena.allocator().dupeZ(u8, buf[0..n]);
        return .{ .arena = arena, .base = base, .dir = d };
    }

    /// Absolute path to `sub` (leading slash included); valid until deinit.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        self.dir.close(fs_test_io);
        std.Io.Dir.cwd().deleteTree(fs_test_io, self.base) catch {};
        self.arena.deinit();
    }
};

test "parse maps formulas and casks to kinded rows, unpinned and untagged" {
    const bytes =
        \\{"version":2,"generated_at_ms":1700000000000,
        \\"formulas":[{"name":"wget","installed":"1.24.5","latest":"1.25.0"}],
        \\"casks":[{"name":"firefox","installed":"120.0","latest":"121.0"}]}
    ;
    var p = try parse(testing.allocator, bytes);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.items.len);
    // formulas come first, then casks.
    try testing.expectEqualStrings("wget", p.items[0].name);
    try testing.expectEqual(outdated_json.Kind.formula, p.items[0].kind);
    try testing.expectEqualStrings("1.25.0", p.items[0].latest);
    try testing.expectEqual(outdated_json.Kind.cask, p.items[1].kind);
    // No snapshot field supplies these, so every warm row is safe-by-default.
    try testing.expectEqual(false, p.items[0].pinned);
    try testing.expectEqualStrings("", p.items[0].tap);
}

test "parse yields zero rows for an all-current snapshot" {
    var p = try parse(testing.allocator, "{\"version\":2,\"generated_at_ms\":0,\"formulas\":[],\"casks\":[]}");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.items.len);
}

test "parse tolerates a missing casks array" {
    var p = try parse(testing.allocator, "{\"version\":2,\"generated_at_ms\":0,\"formulas\":[{\"name\":\"a\",\"installed\":\"1\",\"latest\":\"2\"}]}");
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.items.len);
    try testing.expectEqual(outdated_json.Kind.formula, p.items[0].kind);
}

test "parse rejects malformed input as BadJson" {
    try testing.expectError(error.BadJson, parse(testing.allocator, "not json"));
    try testing.expectError(error.BadJson, parse(testing.allocator, ""));
}

test "parse propagates a parse-time OOM instead of relabeling it BadJson" {
    // A real allocator exhaustion during the envelope parse is fatal, not a
    // malformed snapshot; the fatal-OOM guard must restore the terminal.
    const bytes =
        \\{"version":2,"generated_at_ms":0,"formulas":[{"name":"wget","installed":"1.24.5","latest":"1.25.0"}],"casks":[]}
    ;
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, parse(fa.allocator(), bytes));
}

test "read returns null when the snapshot file is absent" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    try testing.expect(read(threaded.io(), testing.allocator, "/nonexistent/malt/cache") == null);
}

test "read round-trips a snapshot written to a temp cache dir" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("snapshot_read_roundtrip");
    defer s.deinit();
    const cache_dir = s.base;

    var f = try s.dir.createFile(io, "outdated.json", .{});
    try f.writeStreamingAll(io, "{\"version\":2,\"generated_at_ms\":0,\"formulas\":[{\"name\":\"tree\",\"installed\":\"2.1.0\",\"latest\":\"2.2.0\"}],\"casks\":[]}");
    f.close(io);

    var p = read(io, testing.allocator, cache_dir) orelse return error.TestExpectedWarmRead;
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.items.len);
    try testing.expectEqualStrings("tree", p.items[0].name);
    try testing.expectEqual(outdated_json.Kind.formula, p.items[0].kind);
}

test "parsed rows own their bytes — the snapshot buffer can be freed" {
    const src =
        \\{"version":2,"generated_at_ms":0,"formulas":[{"name":"dav1d","installed":"1.5.3","latest":"1.5.4"}],"casks":[]}
    ;
    const buf = try testing.allocator.dupe(u8, src);
    var p = try parse(testing.allocator, buf);
    defer p.deinit();
    @memset(buf, 'X'); // scribble the source; a referencing parse would now read garbage
    testing.allocator.free(buf);
    try testing.expectEqualStrings("dav1d", p.items[0].name);
    try testing.expectEqualStrings("1.5.4", p.items[0].latest);
}
