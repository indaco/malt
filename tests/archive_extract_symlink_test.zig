//! malt — end-to-end symlink-target guard for the subprocess extractors.
//!
//! `extractTarXzFile` (system `tar`) and `extractZip` (system `unzip`)
//! validate entry *names* via a listing pass, but the listing never surfaces
//! symlink *targets*. These tests build real archives whose only escape is a
//! symlink target climbing out of the destination, and assert the extractor
//! refuses them while a benign archive still extracts.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const archive = malt.archive;

const setup_io = std.Options.debug_io;

/// Stands in for `std.testing.tmpDir`, which builds under `.zig-cache` — a tree
/// the build system owns and rewrites underneath concurrent test runs. The path
/// is process- and call-unique so overlapping runs cannot wipe each other.
const Scratch = struct {
    arena: std.heap.ArenaAllocator,
    base: []const u8,
    dir: std.Io.Dir,

    fn init(tag: []const u8) !Scratch {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const raw = try test_io.uniqueTempPath(arena.allocator(), "archive_symlink", tag);
        test_io.deleteTreeAbsolute(setup_io, raw) catch {};
        try test_io.makeDirAbsolute(setup_io, raw);
        var dir = try test_io.openDirAbsolute(setup_io, raw, .{});
        errdefer dir.close(setup_io);
        // /tmp is a symlink to /private/tmp on macOS; resolve once so the paths
        // handed to the extractors match what it resolves them to.
        var buf: [test_io.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.realPath(dir, setup_io, &buf);
        const base = try arena.allocator().dupe(u8, buf[0..n]);
        return .{ .arena = arena, .base = base, .dir = dir };
    }

    /// Absolute path to `sub` inside the scratch tree; valid until `deinit`.
    fn p(self: *Scratch, sub: []const u8) []const u8 {
        return std.fmt.allocPrint(
            self.arena.allocator(),
            "{s}/{s}",
            .{ self.base, sub },
        ) catch @panic("OOM");
    }

    fn deinit(self: *Scratch) void {
        self.dir.close(setup_io);
        test_io.deleteTreeAbsolute(setup_io, self.base) catch {};
        self.arena.deinit();
    }
};

/// Run `argv` (optionally in `cwd`) and fail the test if it doesn't exit 0.
fn run(io: std.Io, argv: []const []const u8, cwd: std.process.Child.Cwd) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

test "extractTarXzFile rejects a tar.xz symlink target that escapes the destination" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("txz_escape");
    defer s.deinit();
    try s.dir.createDirPath(io, "src");
    try s.dir.createDirPath(io, "dest");
    var src = try s.dir.openDir(io, "src", .{});
    defer src.close(io);
    try src.symLink(io, "../../../../etc/evil", "escape", .{});

    const arc = s.p("evil.tar.xz");
    try run(io, &.{ "tar", "-cJf", arc, "-C", "src", "escape" }, .{ .dir = s.dir });

    const dst = s.p("dest");
    try testing.expectError(error.ExtractionFailed, archive.extractTarXzFile(io, arc, dst));
    // The guard wipes the tree, so no escaping symlink is left behind.
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, dst, .{}));
}

test "extractZip rejects a zip symlink target that escapes the destination" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("zip_escape");
    defer s.deinit();
    try s.dir.createDirPath(io, "src");
    try s.dir.createDirPath(io, "dest");
    var src = try s.dir.openDir(io, "src", .{});
    defer src.close(io);
    try src.symLink(io, "../../../../etc/evil", "escape", .{});

    const arc = s.p("evil.zip");
    // `--symlinks` stores the link as a symlink rather than dereferencing it.
    try run(io, &.{ "zip", "-q", "--symlinks", arc, "escape" }, .{ .dir = src });

    const dst = s.p("dest");
    try testing.expectError(error.ExtractionFailed, archive.extractZip(io, arc, dst));
    try testing.expectError(error.FileNotFound, std.Io.Dir.accessAbsolute(io, dst, .{}));
}

test "extractZip still extracts a benign archive" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("zip_benign");
    defer s.deinit();
    try s.dir.createDirPath(io, "src");
    try s.dir.createDirPath(io, "dest");
    try s.dir.writeFile(io, .{ .sub_path = "src/hello", .data = "hi" });
    var src = try s.dir.openDir(io, "src", .{});
    defer src.close(io);

    const arc = s.p("ok.zip");
    try run(io, &.{ "zip", "-q", arc, "hello" }, .{ .dir = src });

    const dst = s.p("dest");
    try archive.extractZip(io, arc, dst);

    try std.Io.Dir.accessAbsolute(io, s.p("dest/hello"), .{});
}

test "extractTarXzFile still extracts a benign archive with an in-tree symlink" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var s = try Scratch.init("txz_benign");
    defer s.deinit();
    try s.dir.createDirPath(io, "src");
    try s.dir.createDirPath(io, "dest");
    try s.dir.writeFile(io, .{ .sub_path = "src/hello", .data = "hi" });
    var src = try s.dir.openDir(io, "src", .{});
    defer src.close(io);
    // A relative in-tree symlink must survive — the guard rejects only escapes.
    try src.symLink(io, "hello", "alias", .{});

    const arc = s.p("ok.tar.xz");
    try run(io, &.{ "tar", "-cJf", arc, "-C", "src", "hello", "alias" }, .{ .dir = s.dir });

    const dst = s.p("dest");
    try archive.extractTarXzFile(io, arc, dst);

    // Both the regular file and the in-tree symlink land.
    var dest_dir = try std.Io.Dir.openDirAbsolute(io, dst, .{});
    defer dest_dir.close(io);
    try dest_dir.access(io, "hello", .{});
    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const target = link_buf[0..try dest_dir.readLink(io, "alias", &link_buf)];
    try testing.expectEqualStrings("hello", target);
}
