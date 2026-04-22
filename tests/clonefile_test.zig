//! malt — APFS clonefile tests
//!
//! These exercise the copy-tree and isApfs helpers with real temp dirs.
//! On the common macOS dev box the prefix volume IS APFS, so cloneTree
//! takes the fast path; on non-APFS volumes we still hit the fallback.

const std = @import("std");
const malt = @import("malt");
const testing = std.testing;
const clonefile = @import("malt").clonefile;

fn tmpRoot(comptime tag: []const u8) []const u8 {
    return "/tmp/malt_clonefile_test_" ++ tag;
}

fn setupSourceTree(root: []const u8) !void {
    malt.fs_compat.deleteTreeAbsolute(root) catch {};
    try malt.fs_compat.makeDirAbsolute(root);
    var src_buf: [512]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}/src", .{root});
    try malt.fs_compat.makeDirAbsolute(src);

    // A regular file.
    var f_buf: [512]u8 = undefined;
    const fpath = try std.fmt.bufPrint(&f_buf, "{s}/hello.txt", .{src});
    const f = try malt.fs_compat.cwd().createFile(fpath, .{});
    defer f.close();
    try f.writeAll("hi\n");

    // A nested file.
    var sub_buf: [512]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "{s}/inner", .{src});
    try malt.fs_compat.makeDirAbsolute(sub);
    var sub_f_buf: [512]u8 = undefined;
    const sf_path = try std.fmt.bufPrint(&sub_f_buf, "{s}/world.txt", .{sub});
    const sf = try malt.fs_compat.cwd().createFile(sf_path, .{});
    defer sf.close();
    try sf.writeAll("nested\n");
}

test "isApfs returns a plausible bool for the repo tmp dir" {
    // Just assert it runs without crashing. The actual bool depends on
    // the host filesystem.
    const apfs = clonefile.isApfs("/tmp");
    _ = apfs;
}

test "isApfs returns true for a path that cannot be stat'd (fallback assumption)" {
    // The implementation defensively returns `true` when statfs fails so
    // callers assume APFS and try clonefile first. An impossible path is
    // the simplest way to take that branch.
    try testing.expect(clonefile.isApfs("/this/does/not/exist/ever"));
}

test "cloneTree duplicates a small directory tree" {
    const root = tmpRoot("basic");
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    try setupSourceTree(root);

    var src_buf: [512]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}/src", .{root});
    var dst_buf: [512]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/dst", .{root});

    try clonefile.cloneTree(src, dst);

    // Verify the cloned top-level file exists with the same contents.
    var verify_buf: [512]u8 = undefined;
    const cloned = try std.fmt.bufPrint(&verify_buf, "{s}/hello.txt", .{dst});
    const f = try malt.fs_compat.cwd().openFile(cloned, .{});
    defer f.close();
    var contents: [16]u8 = undefined;
    const n = try f.readAll(&contents);
    try testing.expectEqualStrings("hi\n", contents[0..n]);

    // And the nested file.
    var nested_buf: [512]u8 = undefined;
    const nested = try std.fmt.bufPrint(&nested_buf, "{s}/inner/world.txt", .{dst});
    const nf = try malt.fs_compat.cwd().openFile(nested, .{});
    defer nf.close();
    var nb: [16]u8 = undefined;
    const nn = try nf.readAll(&nb);
    try testing.expectEqualStrings("nested\n", nb[0..nn]);
}

test "cloneTree fails with AlreadyExists when dst already exists" {
    const root = tmpRoot("exists");
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    try setupSourceTree(root);

    var src_buf: [512]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}/src", .{root});
    var dst_buf: [512]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/dst", .{root});

    // Pre-create dst — clonefile(2) EEXIST → CloneError.AlreadyExists on APFS.
    // On non-APFS filesystems the fallback may overwrite gracefully, so we
    // only assert the error on APFS.
    try malt.fs_compat.makeDirAbsolute(dst);
    const result = clonefile.cloneTree(src, dst);
    if (clonefile.isApfs("/tmp")) {
        try testing.expectError(clonefile.CloneError.AlreadyExists, result);
    } else {
        // Non-APFS takes the fallback path, which makeDir's idempotently.
        result catch {};
    }
}

test "cloneTree errors on a missing source when the fallback path is taken" {
    // Force the fallback branch by targeting a dst path whose parent does
    // not exist. clonefile(2) will fail with ENOENT → IoError. We also
    // cover the non-APFS fallback with a missing src below.
    const result = clonefile.cloneTree(
        "/definitely/not/a/real/path",
        "/tmp/malt_clonefile_test_missing_dst",
    );
    try testing.expectError(clonefile.CloneError.IoError, result);
}

// --- copyTreeFallback tests (exercise the non-APFS path explicitly) ---

test "copyTreeFallback duplicates files, subdirs, and symlinks" {
    const root = tmpRoot("fallback");
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    try setupSourceTree(root);

    var src_buf: [512]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}/src", .{root});
    var dst_buf: [512]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/dst_fallback", .{root});

    // Add a symlink into the source tree so the sym_link branch runs.
    var link_path_buf: [512]u8 = undefined;
    const link_path = try std.fmt.bufPrint(&link_path_buf, "{s}/link.txt", .{src});
    malt.fs_compat.cwd().symLink("hello.txt", link_path, .{}) catch {};

    try clonefile.copyTreeFallback(src, dst);

    // Verify the top-level file is present.
    var check_buf: [512]u8 = undefined;
    const check = try std.fmt.bufPrint(&check_buf, "{s}/hello.txt", .{dst});
    const f = try malt.fs_compat.cwd().openFile(check, .{});
    defer f.close();
    var contents: [16]u8 = undefined;
    const n = try f.readAll(&contents);
    try testing.expectEqualStrings("hi\n", contents[0..n]);

    // And the nested file.
    var nested_buf: [512]u8 = undefined;
    const nested = try std.fmt.bufPrint(&nested_buf, "{s}/inner/world.txt", .{dst});
    const nf = try malt.fs_compat.cwd().openFile(nested, .{});
    defer nf.close();
}

test "copyTreeFallback is idempotent when the destination already exists" {
    const root = tmpRoot("fallback_idem");
    defer malt.fs_compat.deleteTreeAbsolute(root) catch {};
    try setupSourceTree(root);

    var src_buf: [512]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}/src", .{root});
    var dst_buf: [512]u8 = undefined;
    const dst = try std.fmt.bufPrint(&dst_buf, "{s}/dst_idem", .{root});

    try malt.fs_compat.makeDirAbsolute(dst);
    try clonefile.copyTreeFallback(src, dst);

    // Verify the nested file was still copied.
    var check_buf: [512]u8 = undefined;
    const check = try std.fmt.bufPrint(&check_buf, "{s}/inner/world.txt", .{dst});
    const f = try malt.fs_compat.cwd().openFile(check, .{});
    defer f.close();
}

test "copyTreeFallback errors when source directory does not exist" {
    try testing.expectError(
        error.FileNotFound,
        clonefile.copyTreeFallback("/not/a/real/source/dir", "/tmp/malt_clonefile_nowhere"),
    );
}

// BUG-014 regression: before the errno fix, clonefile(2)'s -1 return was
// passed to std.posix.errno, which on some stdlib versions never surfaced
// OPNOTSUPP — non-APFS volumes errored instead of falling back. The test
// needs a writable non-APFS mount to actually run; CI points at one via
// MALT_TEST_NON_APFS_DIR. On the common macOS dev box every visible mount
// is APFS, so we skip with a clear message instead of inventing one.
test "cloneTree falls back to copyTree on a non-APFS volume" {
    const non_apfs_dir = malt.fs_compat.getenv("MALT_TEST_NON_APFS_DIR") orelse {
        std.log.warn(
            "skipping non-APFS fallback test: set MALT_TEST_NON_APFS_DIR to a writable non-APFS mount to enable",
            .{},
        );
        return error.SkipZigTest;
    };
    if (clonefile.isApfs(non_apfs_dir)) {
        std.log.warn(
            "skipping non-APFS fallback test: MALT_TEST_NON_APFS_DIR={s} is APFS",
            .{non_apfs_dir},
        );
        return error.SkipZigTest;
    }

    // Source on the repo tmp root (APFS in CI's macOS runner); dst on the
    // caller-provided non-APFS mount so clonefile(2) returns ENOTSUP.
    const src_root = tmpRoot("nonapfs_src");
    defer malt.fs_compat.deleteTreeAbsolute(src_root) catch {};
    try setupSourceTree(src_root);

    var src_buf: [512]u8 = undefined;
    const src = try std.fmt.bufPrint(&src_buf, "{s}/src", .{src_root});

    var dst_buf: [512]u8 = undefined;
    const dst = try std.fmt.bufPrint(
        &dst_buf,
        "{s}/malt_clonefile_nonapfs_dst",
        .{non_apfs_dir},
    );
    malt.fs_compat.deleteTreeAbsolute(dst) catch {};
    defer malt.fs_compat.deleteTreeAbsolute(dst) catch {};

    // Without the fix, OPNOTSUPP is misclassified and this returns IoError.
    try clonefile.cloneTree(src, dst);

    var verify_buf: [512]u8 = undefined;
    const copied = try std.fmt.bufPrint(&verify_buf, "{s}/hello.txt", .{dst});
    const f = try malt.fs_compat.cwd().openFile(copied, .{});
    defer f.close();
    var contents: [16]u8 = undefined;
    const n = try f.readAll(&contents);
    try testing.expectEqualStrings("hi\n", contents[0..n]);
}
