//! malt — filesystem permission audits for the install prefix.
//!
//! Detects the class of weak-permissions setup that lets a local
//! attacker substitute a binary out from under a later `malt run`:
//! other-writable (`o+w`), group-writable (`g+w`) when the group is
//! unexpected, or ownership by a user other than the current caller.
//! Shared-system-only concern; single-user macOS setups are fine.

const std = @import("std");
const builtin = @import("builtin");

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
    file_uid: std.posix.uid_t,
    current_uid: std.posix.uid_t,
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

/// Walk `prefix` recursively and collect every entry whose permissions
/// violate `classifyPermissions`. Caps at `max_findings` to bound
/// memory on pathologically large prefixes. Returns an error instead of
/// a partial list when part of the tree cannot be audited.
pub fn walkPrefix(
    io: std.Io,
    allocator: std.mem.Allocator,
    prefix: []const u8,
    current_uid: std.posix.uid_t,
    max_findings: usize,
) ![]WalkFinding {
    var findings: std.ArrayList(WalkFinding) = .empty;
    errdefer {
        for (findings.items) |f| allocator.free(f.path);
        findings.deinit(allocator);
    }

    const prefix_z = try std.posix.toPosixPath(prefix);
    try checkPath(allocator, std.c.AT.FDCWD, &prefix_z, prefix, "", current_uid, &findings, max_findings);
    if (findings.items.len >= max_findings) return findings.toOwnedSlice(allocator);

    var dir = std.Io.Dir.openDirAbsolute(io, prefix, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return findings.toOwnedSlice(allocator),
        else => return e,
    };
    defer dir.close(io);

    // Selective, so a directory is checked before the walk opens it.
    var walker = try dir.walkSelectively(allocator);
    defer {
        // deinit frees memory only; an early return leaves entered dirs open.
        // Item 0 is `dir`, closed by its own defer.
        if (walker.stack.items.len > 1) {
            for (walker.stack.items[1..]) |item| item.iter.reader.dir.close(io);
        }
        walker.deinit();
    }

    // A directory the walk cannot open ends the audit: a partial list would read as clean.
    while (try walker.next(io)) |entry| {
        if (findings.items.len >= max_findings) break;
        // Relative to the parent handle, so deep trees never hit max_path_bytes.
        try checkPath(allocator, entry.dir.handle, entry.basename, prefix, entry.path, current_uid, &findings, max_findings);
        walker.enter(io, entry) catch |e| switch (e) {
            // Benign only if the entry is gone: a swapped-in dangling link would hide a subtree.
            error.FileNotFound => if (!isGone(entry.dir.handle, entry.basename)) return e,
            else => return e,
        };
    }

    return findings.toOwnedSlice(allocator);
}

/// Stat `name` relative to `dir_fd`; on a finding, record `prefix/rel`
/// (just `prefix` when `rel` is empty).
fn checkPath(
    allocator: std.mem.Allocator,
    dir_fd: std.posix.fd_t,
    name: [*:0]const u8,
    prefix: []const u8,
    rel: []const u8,
    current_uid: std.posix.uid_t,
    findings: *std.ArrayList(WalkFinding),
    max_findings: usize,
) !void {
    if (findings.items.len >= max_findings) return;

    // NOFOLLOW: a planted symlink must not redirect the walker to its target.
    // The prefix itself follows, because the walk runs in its target.
    // Still libc — no std peer on 0.16 surfaces st_uid.
    const flags: u32 = if (rel.len == 0) 0 else std.c.AT.SYMLINK_NOFOLLOW;
    var st: std.c.Stat = undefined;
    const rc = std.c.fstatat(dir_fd, name, &st, flags);
    if (rc != 0) switch (std.posix.errno(rc)) {
        // Removed between readdir and stat, e.g. by a concurrent purge.
        .NOENT => return,
        .ACCES, .PERM => return error.AccessDenied,
        else => return error.Unexpected,
    };

    const mode: u16 = @intCast(st.mode & 0o777);
    const report = classifyPermissions(mode, st.uid, current_uid);
    if (report.isOk()) return;

    const owned = if (rel.len == 0)
        try allocator.dupe(u8, prefix)
    else
        try std.fs.path.join(allocator, &.{ prefix, rel });
    findings.append(allocator, .{ .path = owned, .report = report }) catch |e| {
        allocator.free(owned);
        return e;
    };
}

fn isGone(dir_fd: std.posix.fd_t, name: [*:0]const u8) bool {
    var st: std.c.Stat = undefined;
    const rc = std.c.fstatat(dir_fd, name, &st, std.c.AT.SYMLINK_NOFOLLOW);
    return rc != 0 and std.posix.errno(rc) == .NOENT;
}

pub fn currentUid() std.posix.uid_t {
    return std.c.getuid();
}

/// False under a setuid/setgid wrapper, where the env-driven prefix,
/// PATH and tokens would be attacker input to a process running as the
/// prefix owner. Pure so the refusal can be unit-tested.
pub fn privilegeIdsMatch(uid: std.posix.uid_t, euid: std.posix.uid_t, gid: std.posix.gid_t, egid: std.posix.gid_t) bool {
    return uid == euid and gid == egid;
}

test "isGone: true only when the entry no longer exists" {
    const io = std.Options.debug_io;
    var buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&buf, "/tmp/malt_isgone_{d}", .{std.c.getpid()});
    std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    var dir = try std.Io.Dir.cwd().openDir(io, base, .{});
    defer dir.close(io);

    try std.testing.expect(isGone(dir.handle, "never_created"));
    // A dangling link fails the open with ENOENT but still exists, so it must
    // not pass as a removal.
    try dir.symLink(io, "nowhere", "dangling", .{});
    try std.testing.expect(!isGone(dir.handle, "dangling"));
}

// Re-exports for non-macOS callers that want the type-level surface
// without pulling in the walker.
comptime {
    if (builtin.os.tag != .macos) {
        @compileError("perms.zig is macOS-only for now");
    }
}

test "privilegeIdsMatch: equal real/effective ids are fine" {
    try std.testing.expect(privilegeIdsMatch(501, 501, 20, 20));
}

test "privilegeIdsMatch: uid != euid is a setuid wrapper" {
    try std.testing.expect(!privilegeIdsMatch(501, 0, 20, 20));
}

test "privilegeIdsMatch: gid != egid is a setgid wrapper" {
    try std.testing.expect(!privilegeIdsMatch(501, 501, 20, 0));
}
