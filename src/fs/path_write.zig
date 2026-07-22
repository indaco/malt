//! Non-atomic writes to a user-supplied output path (`backup -o`,
//! `purge --backup`): creates the parent chain and accepts absolute or
//! relative paths. Use `atomic.zig` when a partial write must never be
//! visible. Leaf: depends only on `std`; errors are typed and UI-agnostic
//! so callers own the messaging.

const std = @import("std");

pub const ParentError = error{MakeParentDirFailed};
pub const WriteError = ParentError || error{ OpenFileFailed, WriteFailed };

/// Create the parent chain of `path` (recursive; absolute or relative).
///
/// `createDirPath`'s existence check is nofollow, so an existing
/// symlink-to-dir parent (e.g. macOS `/tmp`) would be rejected as `NotDir` —
/// skip creation when the parent already resolves to a directory.
pub fn ensureParentDir(io: std.Io, path: []const u8) ParentError!void {
    const dir = std.fs.path.dirname(path) orelse return;
    if (dir.len == 0) return;

    // Follows symlinks, so a symlink-to-dir parent counts as already present.
    if (std.Io.Dir.cwd().statFile(io, dir, .{})) |st| {
        if (st.kind == .directory) return;
    } else |_| {}

    std.Io.Dir.cwd().createDirPath(io, dir) catch return error.MakeParentDirFailed;
}

/// Write `bytes` to `path`, creating parent directories as needed and
/// truncating any existing file. Not atomic — a crash mid-write can leave a
/// partial file; use `atomic.zig` when readers must never see one.
pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) WriteError!void {
    try ensureParentDir(io, path);
    // createFileAbsolute is createFile on cwd for an absolute path, so one
    // call covers both path kinds.
    const file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch
        return error.OpenFileFailed;
    defer file.close(io);
    file.writeStreamingAll(io, bytes) catch return error.WriteFailed;
}

// ── tests ──────────────────────────────────────────────────────────────

const fs_test_io = std.Options.debug_io;

fn rmrf(path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(fs_test_io, path) catch {};
}

var scratch_seq: std.atomic.Value(u32) = .init(0);

/// Scratch tree under a process- and call-unique base: overlapping test runs
/// share /tmp and would otherwise delete each other's fixtures.
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
        rmrf(base);
        return .{ .arena = arena, .base = base };
    }

    /// Absolute path to `sub` (leading slash included) inside the scratch
    /// tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) [:0]const u8 {
        return std.fmt.allocPrintSentinel(
            self.arena.allocator(),
            "{s}{s}",
            .{ self.base, sub },
            0,
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        rmrf(self.base);
        self.arena.deinit();
    }
};

test "writeFile creates a full absolute parent chain with a missing grandparent" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("pathwrite_abschain");
    defer s.deinit();

    const dest = s.p("/a/b/out.txt");

    try writeFile(io, dest, "data\n");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    try std.testing.expect((try f.stat(io)).size > 0);
}

test "writeFile creates a relative nested parent chain" {
    // Stays relative on purpose — that is what this test covers — so it gets
    // the pid+seq uniqueness by hand instead of the /tmp-rooted Scratch.
    const io = std.Options.debug_io;
    var rel_buf: [64]u8 = undefined;
    const rel_root = try std.fmt.bufPrint(
        &rel_buf,
        "zz_malt_pathwrite_rel_{d}_{d}",
        .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) },
    );
    std.Io.Dir.cwd().deleteTree(io, rel_root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, rel_root) catch {};

    var dest_buf: [128]u8 = undefined;
    const dest = try std.fmt.bufPrint(&dest_buf, "{s}/sub/out.txt", .{rel_root});

    try writeFile(io, dest, "data\n");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    try std.testing.expect((try f.stat(io)).size > 0);
}

test "writeFile accepts a symlink-to-directory parent (e.g. /tmp)" {
    // createDirPath's nofollow kind check rejects an existing symlink-to-dir
    // as NotDir; the writer must still succeed (macOS /tmp → /private/tmp).
    const io = std.Options.debug_io;
    var s = try Scratch.init("pathwrite_symlink");
    defer s.deinit();
    // The scratch base itself is the destination file — its parent is /tmp,
    // which is the symlink-to-dir under test.
    const dest = s.base;

    try writeFile(io, dest, "data\n");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    try std.testing.expect((try f.stat(io)).size > 0);
}

test "writeFile surfaces MakeParentDirFailed when a parent component is a file" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("pathwrite_parentfile");
    defer s.deinit();
    try std.Io.Dir.cwd().createDirPath(io, s.base);

    const blocker = s.p("/afile");
    (try std.Io.Dir.cwd().createFile(io, blocker, .{ .truncate = true })).close(io);

    const dest = s.p("/afile/sub/out.txt");

    try std.testing.expectError(error.MakeParentDirFailed, writeFile(io, dest, "data\n"));
}

test "writeFile surfaces OpenFileFailed when the destination is a directory" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("pathwrite_destdir");
    defer s.deinit();

    const dest = s.p("/target");
    try std.Io.Dir.cwd().createDirPath(io, dest); // dest is a dir

    try std.testing.expectError(error.OpenFileFailed, writeFile(io, dest, "data\n"));
}

test "ensureParentDir is a no-op for a bare filename (no directory component)" {
    // dirname("out.txt") is null → nothing to create, no error.
    try ensureParentDir(std.Options.debug_io, "out.txt");
}

test "ensureParentDir creates a missing directory chain" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("pathwrite_ensure");
    defer s.deinit();

    try ensureParentDir(io, s.p("/x/y/out.txt"));

    const st = try std.Io.Dir.cwd().statFile(io, s.p("/x/y"), .{});
    try std.testing.expect(st.kind == .directory);
}

test "writeFile truncates an existing file and reuses its existing parent" {
    // A second write to the same path: parent already exists (skip create),
    // and a shorter payload must leave no stale tail.
    const io = std.Options.debug_io;
    var s = try Scratch.init("pathwrite_trunc");
    defer s.deinit();
    const dest = s.base;

    try writeFile(io, dest, "a long first payload");
    try writeFile(io, dest, "x");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    try std.testing.expectEqual(@as(u64, 1), (try f.stat(io)).size);
}

test "writeFile writes a zero-length file for empty bytes" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("pathwrite_empty");
    defer s.deinit();
    const dest = s.base;

    try writeFile(io, dest, "");

    const f = try std.Io.Dir.cwd().openFile(io, dest, .{});
    defer f.close(io);
    try std.testing.expectEqual(@as(u64, 0), (try f.stat(io)).size);
}
