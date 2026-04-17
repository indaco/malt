//! malt — filesystem permission audits for the install prefix.
//!
//! Detects the class of weak-permissions setup that lets a local
//! attacker substitute a binary out from under a later `malt run`:
//! other-writable (`o+w`), group-writable (`g+w`) when the group is
//! unexpected, or ownership by a user other than the current caller.
//! Shared-system-only concern; single-user macOS setups are fine.

const std = @import("std");
const builtin = @import("builtin");
const fs_compat = @import("../fs/compat.zig");

pub const PermReport = struct {
    group_writable: bool,
    other_writable: bool,
    wrong_owner: bool,

    pub fn isOk(self: PermReport) bool {
        return !self.group_writable and !self.other_writable and !self.wrong_owner;
    }
};

/// Classify a single path's stat result. Pure function so the logic
/// is unit-testable without real files.
pub fn classifyPermissions(
    mode: u16,
    file_uid: std.c.uid_t,
    current_uid: std.c.uid_t,
) PermReport {
    return .{
        .group_writable = (mode & 0o020) != 0,
        .other_writable = (mode & 0o002) != 0,
        .wrong_owner = file_uid != current_uid,
    };
}

pub const WalkFinding = struct {
    /// Caller-owned. Freed via `freeFindings`.
    path: []const u8,
    report: PermReport,
};

pub fn freeFindings(allocator: std.mem.Allocator, findings: []WalkFinding) void {
    for (findings) |f| allocator.free(f.path);
    allocator.free(findings);
}

/// macOS lstat — doesn't follow symlinks; used here so a malicious
/// symlink can't make the walker stat the target instead of the link
/// itself. The Stat shape matches std.c.Stat on macOS.
extern "c" fn lstat(path: [*:0]const u8, buf: *std.c.Stat) c_int;

/// Walk `prefix` recursively and collect every entry whose permissions
/// violate `classifyPermissions`. Caps at `max_findings` to bound
/// memory on pathologically large prefixes.
pub fn walkPrefix(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    current_uid: std.c.uid_t,
    max_findings: usize,
) ![]WalkFinding {
    var findings: std.ArrayList(WalkFinding) = .empty;
    errdefer {
        for (findings.items) |f| allocator.free(f.path);
        findings.deinit(allocator);
    }

    try checkPath(allocator, prefix, current_uid, &findings, max_findings);
    if (findings.items.len >= max_findings) return findings.toOwnedSlice(allocator);

    var dir = fs_compat.openDirAbsolute(prefix, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return findings.toOwnedSlice(allocator),
        else => return e,
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (walker.next() catch null) |entry| {
        if (findings.items.len >= max_findings) break;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ prefix, entry.path }) catch continue;
        try checkPath(allocator, full, current_uid, &findings, max_findings);
    }

    return findings.toOwnedSlice(allocator);
}

fn checkPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    current_uid: std.c.uid_t,
    findings: *std.ArrayList(WalkFinding),
    max_findings: usize,
) !void {
    if (findings.items.len >= max_findings) return;
    if (path.len >= std.fs.max_path_bytes) return;

    var cstr_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(cstr_buf[0..path.len], path);
    cstr_buf[path.len] = 0;
    const cstr: [*:0]const u8 = @ptrCast(&cstr_buf);

    var st: std.c.Stat = undefined;
    if (lstat(cstr, &st) != 0) return; // skip unstatable entries silently

    const mode: u16 = @intCast(st.mode & 0o777);
    const report = classifyPermissions(mode, st.uid, current_uid);
    if (report.isOk()) return;

    const owned = try allocator.dupe(u8, path);
    findings.append(allocator, .{ .path = owned, .report = report }) catch |e| {
        allocator.free(owned);
        return e;
    };
}

pub fn currentUid() std.c.uid_t {
    return std.c.getuid();
}

// Re-exports for non-macOS callers that want the type-level surface
// without pulling in the walker.
comptime {
    if (builtin.os.tag != .macos) {
        @compileError("perms.zig is macOS-only for now");
    }
}
