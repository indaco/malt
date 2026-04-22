//! malt — bottle.verify tests
//! Covers the SHA256 verification helper without hitting the network.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const bottle = @import("malt").bottle;

test "verify returns true when sha256 matches on-disk content" {
    const base = "/tmp/malt_bottle_verify_ok";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    malt.fs_compat.makeDirAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const path = "/tmp/malt_bottle_verify_ok/payload.bin";
    const f = try malt.fs_compat.createFileAbsolute(path, .{});
    try f.writeAll("hello");
    f.close();

    // SHA256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
    const expected = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
    try testing.expect(try bottle.verify(testing.allocator, path, expected));
}

test "verify returns false for a mismatching sha256" {
    const base = "/tmp/malt_bottle_verify_mismatch";
    malt.fs_compat.deleteTreeAbsolute(base) catch {};
    malt.fs_compat.makeDirAbsolute(base) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(base) catch {};

    const path = "/tmp/malt_bottle_verify_mismatch/payload.bin";
    const f = try malt.fs_compat.createFileAbsolute(path, .{});
    try f.writeAll("hello");
    f.close();

    try testing.expect(!try bottle.verify(testing.allocator, path, "00" ** 32));
}

test "verify returns false when the file does not exist" {
    try testing.expect(!try bottle.verify(testing.allocator, "/tmp/malt_bottle_verify_missing_xyz", "00" ** 32));
}

test "buildTmpArchivePath returns PathTooLong for an oversized dest_dir" {
    // 500-char dest_dir overflows the fixed tmp-path buffer; the distinct
    // tag prevents users from seeing "out of memory" for a path problem.
    var buf: [512]u8 = undefined;
    const long_dest = "/" ++ ("a" ** 499);
    try testing.expectError(bottle.BottleError.PathTooLong, bottle.buildTmpArchivePath(&buf, long_dest));
}

test "buildTmpArchivePath joins a normal dest_dir with the archive name" {
    var buf: [512]u8 = undefined;
    const path = try bottle.buildTmpArchivePath(&buf, "/tmp/malt_bottle_buildpath_ok");
    try testing.expectEqualStrings("/tmp/malt_bottle_buildpath_ok/bottle.tar.gz", path);
}
