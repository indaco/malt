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

/// Sha-256 in hex: the key of the store entry the file belongs to.
const sha_len = 64;

/// Room for `<sha> <tag>\n`.
pub const buf_len = sha_len + 1 + max_len + 1;

fn validSha(sha: []const u8) bool {
    if (sha.len != sha_len) return false;
    for (sha) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// Write `<sha> <tag>\n` into `dir_path`. Whatever the archive left at
/// `file_name` goes first, even when the tag is refused: a planted file must
/// not outlive the commit. A link there would otherwise take the write.
pub fn write(io: std.Io, dir_path: []const u8, sha: []const u8, tag: []const u8) !void {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer dir.close(io);
    try dir.deleteTree(io, file_name);
    if (!valid(tag) or !validSha(sha)) return error.InvalidTag;
    const file = try dir.createFile(io, file_name, .{ .exclusive = true });
    defer file.close(io);
    var line: [buf_len]u8 = undefined;
    const text = try std.fmt.bufPrint(&line, "{s} {s}\n", .{ sha, tag });
    try file.writeStreamingAll(io, text);
}

/// The tag stored beside the entry at `entry_path` for `sha`, or null when the
/// file is missing, not a plain file, too long, malformed, or written for
/// another sha. An archive cannot contain its own digest, so a file it ships
/// never passes. The slice aliases `buf`.
pub fn read(io: std.Io, entry_path: []const u8, sha: []const u8, buf: *[buf_len]u8) ?[]const u8 {
    if (!validSha(sha)) return null;
    var dir = std.Io.Dir.openDirAbsolute(io, entry_path, .{}) catch return null;
    defer dir.close(io);
    const file = dir.openFile(io, file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch return null;
    defer file.close(io);
    const st = file.stat(io) catch return null;
    if (st.kind != .file or st.size > buf_len) return null;
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    const text = buf[0..n];
    if (text.len < sha_len + 3 or text[text.len - 1] != '\n') return null;
    if (!std.mem.eql(u8, text[0..sha_len], sha) or text[sha_len] != ' ') return null;
    const tag = text[sha_len + 1 .. text.len - 1];
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

const sha_a: []const u8 = std.mem.asBytes(&@as([32][2]u8, @splat("ab".*)));
const sha_b: []const u8 = std.mem.asBytes(&@as([32][2]u8, @splat("cd".*)));

fn putAt(path: []const u8, body: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(test_io, path) catch {};
    const h = try std.Io.Dir.cwd().createFile(test_io, path, .{});
    defer h.close(test_io);
    try h.writeStreamingAll(test_io, body);
}

test "a tag survives a write and a read" {
    const s = try Scratch.init();
    defer s.deinit();
    var buf: [buf_len]u8 = undefined;
    try write(test_io, s.path, sha_a, "/opt/malt-brew/Cellar");
    try testing.expectEqualStrings("/opt/malt-brew/Cellar", read(test_io, s.path, sha_a, &buf).?);
    try write(test_io, s.path, sha_a, ":any");
    try testing.expectEqualStrings(":any", read(test_io, s.path, sha_a, &buf).?);
}

test "read refuses a file written for another sha" {
    const s = try Scratch.init();
    defer s.deinit();
    var buf: [buf_len]u8 = undefined;
    try write(test_io, s.path, sha_a, "/opt/malt-brew/Cellar");
    try testing.expect(read(test_io, s.path, sha_b, &buf) == null);
}

test "read refuses a bare tag an archive could ship" {
    const s = try Scratch.init();
    defer s.deinit();
    const path = try s.sub(file_name);
    defer testing.allocator.free(path);
    var buf: [buf_len]u8 = undefined;
    try putAt(path, "/evil/Cellar");
    try testing.expect(read(test_io, s.path, sha_a, &buf) == null);
    try putAt(path, sha_a ++ " /evil/Cellar");
    try testing.expect(read(test_io, s.path, sha_a, &buf) == null);
}

test "write replaces a file the archive planted" {
    const s = try Scratch.init();
    defer s.deinit();
    const planted = try s.sub(file_name);
    defer testing.allocator.free(planted);
    try putAt(planted, "/evil/Cellar");
    var buf: [buf_len]u8 = undefined;
    try write(test_io, s.path, sha_a, "/real/Cellar");
    try testing.expectEqualStrings("/real/Cellar", read(test_io, s.path, sha_a, &buf).?);
}

test "write removes a planted file even when it refuses the tag" {
    const s = try Scratch.init();
    defer s.deinit();
    const planted = try s.sub(file_name);
    defer testing.allocator.free(planted);
    try putAt(planted, sha_a ++ " /evil/Cellar\n");
    try testing.expectError(error.InvalidTag, write(test_io, s.path, sha_a, ""));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(test_io, planted, .{}));
}

test "write does not follow a link the archive planted" {
    const s = try Scratch.init();
    defer s.deinit();
    const victim = try s.sub("victim");
    defer testing.allocator.free(victim);
    try putAt(victim, "keep");
    const link = try s.sub(file_name);
    defer testing.allocator.free(link);
    try std.Io.Dir.cwd().symLink(test_io, victim, link, .{});

    try write(test_io, s.path, sha_a, "/real/Cellar");
    var buf: [buf_len]u8 = undefined;
    try testing.expectEqualStrings("/real/Cellar", read(test_io, s.path, sha_a, &buf).?);
    var kept: [8]u8 = undefined;
    const f = try std.Io.Dir.cwd().openFile(test_io, victim, .{});
    defer f.close(test_io);
    const n = try f.readPositionalAll(test_io, &kept, 0);
    try testing.expectEqualStrings("keep", kept[0..n]);
}

test "write replaces a directory the archive planted" {
    const s = try Scratch.init();
    defer s.deinit();
    const dir = try s.sub(file_name ++ "/inner");
    defer testing.allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(test_io, dir);
    var buf: [buf_len]u8 = undefined;
    try write(test_io, s.path, sha_a, "/real/Cellar");
    try testing.expectEqualStrings("/real/Cellar", read(test_io, s.path, sha_a, &buf).?);
}

test "write refuses a tag or sha that read would refuse" {
    const s = try Scratch.init();
    defer s.deinit();
    for ([_][]const u8{ "", "relative/Cellar", "/a\nb", "/a\x00b", "/caf\xc3\xa9" }) |bad| {
        try testing.expectError(error.InvalidTag, write(test_io, s.path, sha_a, bad));
    }
    try testing.expectError(error.InvalidTag, write(test_io, s.path, "short", "/ok/Cellar"));
}

test "read gives null for a missing, linked, oversized or malformed file" {
    const s = try Scratch.init();
    defer s.deinit();
    var buf: [buf_len]u8 = undefined;
    try testing.expect(read(test_io, s.path, sha_a, &buf) == null);

    const path = try s.sub(file_name);
    defer testing.allocator.free(path);
    try putAt(path, sha_a ++ " relative\n");
    try testing.expect(read(test_io, s.path, sha_a, &buf) == null);
    try putAt(path, sha_a ++ " /a\n\n");
    try testing.expect(read(test_io, s.path, sha_a, &buf) == null);
    try putAt(path, sha_a ++ " /no-newline");
    try testing.expect(read(test_io, s.path, sha_a, &buf) == null);
    try putAt(path, "");
    try testing.expect(read(test_io, s.path, sha_a, &buf) == null);
    var long: [buf_len + 8]u8 = @splat('x');
    @memcpy(long[0..sha_a.len], sha_a);
    long[sha_a.len] = ' ';
    long[sha_a.len + 1] = '/';
    try putAt(path, &long);
    try testing.expect(read(test_io, s.path, sha_a, &buf) == null);

    const real = try s.sub("real");
    defer testing.allocator.free(real);
    try putAt(real, sha_a ++ " /good/Cellar\n");
    try std.Io.Dir.cwd().deleteFile(test_io, path);
    try std.Io.Dir.cwd().symLink(test_io, real, path, .{});
    try testing.expect(read(test_io, s.path, sha_a, &buf) == null);
}
