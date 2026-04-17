//! malt — permission audit tests
//!
//! Covers the pure classifier exhaustively and exercises the walker
//! against a scratch /tmp tree with known mode bits.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
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
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.cwd().makePath(base ++ "/bin");
    (try malt.fs_compat.createFileAbsolute(base ++ "/bin/foo", .{})).close();

    const findings = try perms.walkPrefix(testing.allocator, base, perms.currentUid(), 64);
    defer perms.freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);
}

test "walkPrefix: detects other-writable file" {
    const base = "/tmp/malt_perms_other_writable";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.cwd().makePath(base);
    const path = base ++ "/world_writable.txt";
    (try malt.fs_compat.createFileAbsolute(path, .{})).close();

    // chmod o+w
    const c = struct {
        extern "c" fn chmod(path: [*:0]const u8, mode: u16) c_int;
    };
    if (c.chmod(path, 0o666) != 0) return error.TestUnexpectedResult;

    const findings = try perms.walkPrefix(testing.allocator, base, perms.currentUid(), 64);
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

test "walkPrefix: missing prefix returns empty findings, no error" {
    const findings = try perms.walkPrefix(
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
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};
    try malt.fs_compat.cwd().makePath(base);
    const c = struct {
        extern "c" fn chmod(path: [*:0]const u8, mode: u16) c_int;
    };
    // Seed 5 world-writable files.
    for (0..5) |i| {
        var buf: [64]u8 = undefined;
        const p = try std.fmt.bufPrintSentinel(&buf, "{s}/f{d}", .{ base, i }, 0);
        (try malt.fs_compat.createFileAbsolute(p, .{})).close();
        if (c.chmod(p.ptr, 0o666) != 0) return error.TestUnexpectedResult;
    }

    const findings = try perms.walkPrefix(testing.allocator, base, perms.currentUid(), 2);
    defer perms.freeFindings(testing.allocator, findings);
    try testing.expect(findings.len <= 2);
}
