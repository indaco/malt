//! The cellar tag a bottle declares, kept beside its store entry so a later
//! rollback can size relocated text for the prefix the bottle was built for.
//! The file sits in the staging directory before the entry is committed, so
//! it is published and removed with the entry. Bottle content must not
//! decide what it holds: `write` always replaces what the archive put there.

const std = @import("std");

pub const file_name = ".malt-cellar-tag";
pub const max_len = 255;

/// A real tag is an absolute path (`/opt/homebrew/Cellar`) or a Homebrew
/// marker (`:any`). Printable ASCII only, so it cannot carry a line break or
/// a control byte into a log or a path.
pub fn valid(tag: []const u8) bool {
    if (tag.len == 0 or tag.len > max_len) return false;
    if (tag[0] != '/' and tag[0] != ':') return false;
    for (tag) |c| if (c < 0x20 or c > 0x7e) return false;
    return true;
}

/// Write `tag` into `dir_path`. Whatever the archive left at `file_name`
/// goes first: a link there would otherwise take the write.
pub fn write(io: std.Io, dir_path: []const u8, tag: []const u8) !void {
    if (!valid(tag)) return error.InvalidTag;
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    try dir.deleteTree(io, file_name);
    const file = try dir.createFile(io, file_name, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, tag);
}

/// The tag stored beside the entry at `entry_path`, or null when the file is
/// missing, not a plain file, too long or malformed. The slice aliases `buf`.
pub fn read(io: std.Io, entry_path: []const u8, buf: *[max_len + 1]u8) ?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, entry_path, .{}) catch return null;
    defer dir.close(io);
    const file = dir.openFile(io, file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    if (st.kind != .file or st.size > max_len) return null;
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    const tag = buf[0..n];
    return if (valid(tag)) tag else null;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const test_io = std.Options.debug_io;

var scratch_seq: std.atomic.Value(u32) = .init(0);

const Scratch = struct {
    path: []u8,

    fn init() !Scratch {
        const path = try std.fmt.allocPrint(testing.allocator, "/tmp/mt_ctag_{d}_{d}", .{ std.c.getpid(), scratch_seq.fetchAdd(1, .monotonic) });
        std.Io.Dir.cwd().deleteTree(test_io, path) catch {};
        try std.Io.Dir.cwd().createDirPath(test_io, path);
        return .{ .path = path };
    }

    fn deinit(self: Scratch) void {
        std.Io.Dir.cwd().deleteTree(test_io, self.path) catch {};
        testing.allocator.free(self.path);
    }

    fn sub(self: Scratch, comptime rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/" ++ rel, .{self.path});
    }
};

test "a tag survives a write and a read" {
    const s = try Scratch.init();
    defer s.deinit();
    var buf: [max_len + 1]u8 = undefined;
    try write(test_io, s.path, "/opt/malt-brew/Cellar");
    try testing.expectEqualStrings("/opt/malt-brew/Cellar", read(test_io, s.path, &buf).?);
    try write(test_io, s.path, ":any");
    try testing.expectEqualStrings(":any", read(test_io, s.path, &buf).?);
}

test "write replaces a file the archive planted" {
    const s = try Scratch.init();
    defer s.deinit();
    const planted = try s.sub(file_name);
    defer testing.allocator.free(planted);
    const f = try std.Io.Dir.cwd().createFile(test_io, planted, .{});
    try f.writeStreamingAll(test_io, "/evil/Cellar");
    f.close(test_io);
    var buf: [max_len + 1]u8 = undefined;
    try write(test_io, s.path, "/real/Cellar");
    try testing.expectEqualStrings("/real/Cellar", read(test_io, s.path, &buf).?);
}

test "write does not follow a link the archive planted" {
    const s = try Scratch.init();
    defer s.deinit();
    const victim = try s.sub("victim");
    defer testing.allocator.free(victim);
    const f = try std.Io.Dir.cwd().createFile(test_io, victim, .{});
    try f.writeStreamingAll(test_io, "keep");
    f.close(test_io);
    const link = try s.sub(file_name);
    defer testing.allocator.free(link);
    try std.Io.Dir.cwd().symLink(test_io, victim, link, .{});

    try write(test_io, s.path, "/real/Cellar");
    var buf: [max_len + 1]u8 = undefined;
    try testing.expectEqualStrings("/real/Cellar", read(test_io, s.path, &buf).?);
    var kept: [8]u8 = undefined;
    const n = try (try std.Io.Dir.cwd().openFile(test_io, victim, .{})).readPositionalAll(test_io, &kept, 0);
    try testing.expectEqualStrings("keep", kept[0..n]);
}

test "write replaces a directory the archive planted" {
    const s = try Scratch.init();
    defer s.deinit();
    const dir = try s.sub(file_name ++ "/inner");
    defer testing.allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(test_io, dir);
    var buf: [max_len + 1]u8 = undefined;
    try write(test_io, s.path, "/real/Cellar");
    try testing.expectEqualStrings("/real/Cellar", read(test_io, s.path, &buf).?);
}

test "write refuses a tag that read would refuse" {
    const s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ "", "relative/Cellar", "/a\nb", "/a\x00b", "/caf\xc3\xa9" }) |bad| {
        try testing.expectError(error.InvalidTag, write(test_io, s.path, bad));
    }
}

test "read gives null for a missing, linked, oversized or malformed file" {
    const s = try Scratch.init();
    defer s.deinit();
    var buf: [max_len + 1]u8 = undefined;
    try testing.expect(read(test_io, s.path, &buf) == null);

    const path = try s.sub(file_name);
    defer testing.allocator.free(path);
    const put = struct {
        fn f(p: []const u8, body: []const u8) !void {
            std.Io.Dir.cwd().deleteFile(test_io, p) catch {};
            const h = try std.Io.Dir.cwd().createFile(test_io, p, .{});
            defer h.close(test_io);
            try h.writeStreamingAll(test_io, body);
        }
    }.f;
    try put(path, "relative");
    try testing.expect(read(test_io, s.path, &buf) == null);
    try put(path, "/a\n");
    try testing.expect(read(test_io, s.path, &buf) == null);
    try put(path, "");
    try testing.expect(read(test_io, s.path, &buf) == null);
    var long: [max_len + 1]u8 = @splat('x');
    long[0] = '/';
    try put(path, &long);
    try testing.expect(read(test_io, s.path, &buf) == null);

    const real = try s.sub("real");
    defer testing.allocator.free(real);
    try put(real, "/good/Cellar");
    try std.Io.Dir.cwd().deleteFile(test_io, path);
    try std.Io.Dir.cwd().symLink(test_io, real, path, .{});
    try testing.expect(read(test_io, s.path, &buf) == null);
}
