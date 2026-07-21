//! malt — permission audit tests
//!
//! Covers the pure classifier exhaustively and exercises the walker
//! against a scratch /tmp tree with known mode bits.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const perms = malt.perms;

test "classify: 0755 + current uid is ok" {
    const r = perms.classifyPermissions(0o755, 501, 501);
    try testing.expect(r.isOk());
}

test "classify: 0644 + current uid is ok" {
    const r = perms.classifyPermissions(0o644, 501, 501);
    try testing.expect(r.isOk());
}

test "classify: 0777 flagged as group+other writable" {
    const r = perms.classifyPermissions(0o777, 501, 501);
    try testing.expect(!r.isOk());
    try testing.expect(r.group_writable);
    try testing.expect(r.other_writable);
    try testing.expect(!r.wrong_owner);
}

test "classify: 0775 flagged as group writable only" {
    const r = perms.classifyPermissions(0o775, 501, 501);
    try testing.expect(!r.isOk());
    try testing.expect(r.group_writable);
    try testing.expect(!r.other_writable);
}

test "classify: 0757 flagged as other writable (non-standard but real)" {
    const r = perms.classifyPermissions(0o757, 501, 501);
    try testing.expect(!r.isOk());
    try testing.expect(!r.group_writable);
    try testing.expect(r.other_writable);
}

test "classify: wrong_owner flagged independently" {
    const r = perms.classifyPermissions(0o755, 0, 501); // root-owned
    try testing.expect(!r.isOk());
    try testing.expect(r.wrong_owner);
    try testing.expect(!r.group_writable);
    try testing.expect(!r.other_writable);
}

test "classify: all three flags compose" {
    const r = perms.classifyPermissions(0o777, 0, 501);
    try testing.expect(r.wrong_owner);
    try testing.expect(r.group_writable);
    try testing.expect(r.other_writable);
}

test "classify: setuid bit does not count as writable" {
    const r = perms.classifyPermissions(0o4755, 501, 501);
    try testing.expect(r.isOk());
}

// ── walker integration ────────────────────────────────────────────

/// Scratch tree under a process-unique base, so overlapping test runs cannot
/// wipe each other's fixtures.
const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    base: [:0]const u8,

    fn init(tag: []const u8) !Fixture {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const base = try test_io.uniqueTempPath(arena.allocator(), "perms", tag);
        const base_z = try arena.allocator().dupeZ(u8, base);
        test_io.deleteTreeAbsolute(std.Options.debug_io, base_z) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, base_z);
        return .{ .arena = arena, .base = base_z };
    }

    /// Absolute path to `sub` inside the fixture; valid until `deinit`.
    fn p(self: *Fixture, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}/{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Fixture) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.base) catch {};
        self.arena.deinit();
    }
};

const c = struct {
    extern "c" fn chmod(path: [*:0]const u8, mode: u16) c_int;
};

test "walkPrefix: clean tree yields no findings" {
    var fx = try Fixture.init("clean");
    defer fx.deinit();
    try test_io.cwd().createDirPath(std.Options.debug_io, fx.p("bin"));
    (try test_io.createFileAbsolute(std.Options.debug_io, fx.p("bin/foo"), .{})).close(std.Options.debug_io);

    const findings = try perms.walkPrefix(std.Options.debug_io, testing.allocator, fx.base, perms.currentUid(), 64);
    defer perms.freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "walkPrefix: detects other-writable file" {
    var fx = try Fixture.init("other_writable");
    defer fx.deinit();
    const path = fx.p("world_writable.txt");
    (try test_io.createFileAbsolute(std.Options.debug_io, path, .{})).close(std.Options.debug_io);

    // chmod o+w
    if (c.chmod(path, 0o666) != 0) return error.TestUnexpectedResult;

    const findings = try perms.walkPrefix(std.Options.debug_io, testing.allocator, fx.base, perms.currentUid(), 64);
    defer perms.freeFindings(testing.allocator, findings);

    // Must find at least the world_writable file; may also flag the
    // base dir if its default mode is 0o775 (umask-dependent).
    var saw_target = false;
    for (findings) |f| {
        if (std.mem.endsWith(u8, f.path, "/world_writable.txt")) {
            try testing.expect(f.report.other_writable);
            saw_target = true;
        }
    }
    try testing.expect(saw_target);
}

test "walkPrefix: a symlink is judged on itself, not its target" {
    // The walker stats with SYMLINK_NOFOLLOW so a symlink planted in the prefix
    // cannot make it report (or clear) the permissions of something elsewhere.
    var fx = try Fixture.init("nofollow");
    defer fx.deinit();
    // The target lives outside the walked tree, so only following the link
    // could surface its mode.
    var outside = try Fixture.init("nofollow_target");
    defer outside.deinit();

    const target = outside.p("target.txt");
    (try test_io.createFileAbsolute(std.Options.debug_io, target, .{})).close(std.Options.debug_io);
    if (c.chmod(target, 0o666) != 0) return error.TestUnexpectedResult;

    try std.Io.Dir.symLinkAbsolute(std.Options.debug_io, target, fx.p("link"), .{});

    const findings = try perms.walkPrefix(std.Options.debug_io, testing.allocator, fx.base, perms.currentUid(), 64);
    defer perms.freeFindings(testing.allocator, findings);

    // Following would inherit the target's 0o666 and flag the link.
    for (findings) |f| {
        if (std.mem.endsWith(u8, f.path, "/link")) return error.TestUnexpectedResult;
    }
}

test "walkPrefix: missing prefix returns empty findings, no error" {
    const findings = try perms.walkPrefix(
        std.Options.debug_io,
        testing.allocator,
        "/tmp/malt_perms_definitely_does_not_exist_xyz",
        perms.currentUid(),
        64,
    );
    defer perms.freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "walkPrefix: respects max_findings cap" {
    var fx = try Fixture.init("cap");
    defer fx.deinit();
    // Seed 5 world-writable files.
    for (0..5) |i| {
        var buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "f{d}", .{i});
        const p = fx.p(name);
        (try test_io.createFileAbsolute(std.Options.debug_io, p, .{})).close(std.Options.debug_io);
        if (c.chmod(p.ptr, 0o666) != 0) return error.TestUnexpectedResult;
    }

    const findings = try perms.walkPrefix(std.Options.debug_io, testing.allocator, fx.base, perms.currentUid(), 2);
    defer perms.freeFindings(testing.allocator, findings);
    try testing.expect(findings.len <= 2);
}
