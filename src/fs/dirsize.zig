//! malt — recursive on-disk size of a directory tree.
//!
//! A leaf helper used by `mt list --json --size` to report `size_bytes`
//! per installed keg/cask. Symlink-safe: regular files are summed,
//! real subdirectories are recursed, and symlinks are neither counted
//! nor followed — so a keg's internal symlinks and a cask's `app_path`
//! symlink-into-Caskroom never double-count or escape the tree.

const std = @import("std");
const testing = std.testing;

/// Sum the byte size of every regular file under `path`, recursively.
/// Missing or unreadable directories contribute 0 rather than failing —
/// a partial/absent keg dir must not crash the row writer.
pub fn dirSizeBytes(io: std.Io, path: []const u8) u64 {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    return sumDir(io, &dir);
}

/// Walk one directory level: count regular files, recurse real
/// subdirectories. Anything else (symlinks, sockets, devices) is left
/// alone so symlinks are never counted nor traversed. Saturating add
/// guards the theoretical u64 overflow on a pathological tree.
fn sumDir(io: std.Io, dir: *std.Io.Dir) u64 {
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        switch (entry.kind) {
            .file => {
                const st = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch continue;
                total +|= st.size;
            },
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                total +|= sumDir(io, &sub);
            },
            else => {},
        }
    }
    return total;
}

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

test "dirSizeBytes sums nested regular files and skips symlinks" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("dirsize_nested");
    defer s.deinit();
    const root = s.base;
    try std.Io.Dir.cwd().createDirPath(io, s.p("/sub"));

    {
        const f = try std.Io.Dir.createFileAbsolute(io, s.p("/a.txt"), .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "12345"); // 5 bytes
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, s.p("/sub/b.txt"), .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "678"); // 3 bytes
    }
    // A symlink to a real 5-byte file must contribute nothing.
    var sub = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer sub.close(io);
    sub.symLink(io, s.p("/a.txt"), "link", .{}) catch {};

    try testing.expectEqual(@as(u64, 8), dirSizeBytes(io, root));
}

test "dirSizeBytes does not follow a symlink that points at a directory" {
    // The escape/double-count guard: a keg/cask can contain a symlink to
    // another directory. Following it would count bytes outside the tree.
    const io = std.Options.debug_io;
    // One scratch tree holds both sides so the symlink relationship (and its
    // cleanup) stays within a single process-unique base.
    var s = try Scratch.init("dirsize_dirlink");
    defer s.deinit();
    const root = s.p("/inside");
    const outside = s.p("/outside");
    try std.Io.Dir.cwd().createDirPath(io, s.p("/inside/real"));
    try std.Io.Dir.cwd().createDirPath(io, outside);

    {
        const f = try std.Io.Dir.createFileAbsolute(io, s.p("/inside/real/keep"), .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "1234"); // 4 bytes — the only thing counted
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, s.p("/outside/escaped"), .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "SHOULD-NOT-COUNT"); // behind a dir symlink
    }
    var rd = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer rd.close(io);
    rd.symLink(io, outside, "danger", .{}) catch {};

    try testing.expectEqual(@as(u64, 4), dirSizeBytes(io, root));
}

test "dirSizeBytes returns 0 for a missing directory" {
    const io = std.Options.debug_io;
    // Unique but deliberately never created — another run must not be able to
    // materialise this path underneath us.
    var s = try Scratch.init("dirsize_does_not_exist_xyz");
    defer s.deinit();
    try testing.expectEqual(@as(u64, 0), dirSizeBytes(io, s.base));
}

test "dirSizeBytes counts a zero-byte file as 0 without skipping the tree" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("dirsize_zerofile");
    defer s.deinit();
    const root = s.base;
    try std.Io.Dir.createDirAbsolute(io, root, .default_dir);
    {
        const f = try std.Io.Dir.createFileAbsolute(io, s.p("/empty"), .{});
        f.close(io);
    }
    {
        const f = try std.Io.Dir.createFileAbsolute(io, s.p("/data"), .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "xyz"); // 3 bytes
    }
    try testing.expectEqual(@as(u64, 3), dirSizeBytes(io, root));
}

test "dirSizeBytes returns 0 for an empty directory" {
    const io = std.Options.debug_io;
    var s = try Scratch.init("dirsize_empty");
    defer s.deinit();
    const root = s.base;
    try std.Io.Dir.createDirAbsolute(io, root, .default_dir);
    try testing.expectEqual(@as(u64, 0), dirSizeBytes(io, root));
}
