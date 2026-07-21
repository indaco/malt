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

test "walkPrefix: clean tree yields no findings" {
    const base = "/tmp/malt_perms_clean";
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, base ++ "/bin");
    (try test_io.createFileAbsolute(std.Options.debug_io, base ++ "/bin/foo", .{})).close(std.Options.debug_io);

    const findings = try perms.walkPrefix(std.Options.debug_io, testing.allocator, base, perms.currentUid(), 64);
    defer perms.freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "walkPrefix: detects other-writable file" {
    const base = "/tmp/malt_perms_other_writable";
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, base);
    const path = base ++ "/world_writable.txt";
    (try test_io.createFileAbsolute(std.Options.debug_io, path, .{})).close(std.Options.debug_io);

    // chmod o+w
    const c = struct {
        extern "c" fn chmod(path: [*:0]const u8, mode: u16) c_int;
    };
    if (c.chmod(path, 0o666) != 0) return error.TestUnexpectedResult;

    const findings = try perms.walkPrefix(std.Options.debug_io, testing.allocator, base, perms.currentUid(), 64);
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
    const base = "/tmp/malt_perms_nofollow";
    const target = "/tmp/malt_perms_nofollow_target.txt";
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    test_io.deleteTreeAbsolute(std.Options.debug_io, target) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, target) catch {};

    try test_io.cwd().createDirPath(std.Options.debug_io, base);
    (try test_io.createFileAbsolute(std.Options.debug_io, target, .{})).close(std.Options.debug_io);

    const c = struct {
        extern "c" fn chmod(path: [*:0]const u8, mode: u16) c_int;
    };
    if (c.chmod(target, 0o666) != 0) return error.TestUnexpectedResult;

    const link = base ++ "/link";
    try std.Io.Dir.symLinkAbsolute(std.Options.debug_io, target, link, .{});

    const findings = try perms.walkPrefix(std.Options.debug_io, testing.allocator, base, perms.currentUid(), 64);
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
    const base = "/tmp/malt_perms_cap";
    test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, base) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, base);
    const c = struct {
        extern "c" fn chmod(path: [*:0]const u8, mode: u16) c_int;
    };
    // Seed 5 world-writable files.
    for (0..5) |i| {
        var buf: [64]u8 = undefined;
        const p = try std.fmt.bufPrintSentinel(&buf, "{s}/f{d}", .{ base, i }, 0);
        (try test_io.createFileAbsolute(std.Options.debug_io, p, .{})).close(std.Options.debug_io);
        if (c.chmod(p.ptr, 0o666) != 0) return error.TestUnexpectedResult;
    }

    const findings = try perms.walkPrefix(std.Options.debug_io, testing.allocator, base, perms.currentUid(), 2);
    defer perms.freeFindings(testing.allocator, findings);
    try testing.expect(findings.len <= 2);
}
