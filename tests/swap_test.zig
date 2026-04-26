//! malt - atomic swap tests.
//!
//! All work happens in a scratch dir under `/tmp` so target, new,
//! staged, and .old all share a volume - the same invariant the real
//! updater enforces. Tests are TDD-style: written from the caller's
//! contract, not the implementation shape.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const swap = malt.update_swap;
const fs_compat = malt.fs_compat;

fn resetScratch(allocator: std.mem.Allocator, tag: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(allocator, "/tmp/malt_swap_test_{s}", .{tag});
    fs_compat.deleteTreeAbsolute(dir) catch {};
    try fs_compat.makeDirAbsolute(dir);
    return dir;
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const f = try fs_compat.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll(content);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return fs_compat.readFileAbsoluteAlloc(allocator, path, 1 << 16);
}

/// Returns the POSIX mode bits (rwxrwxrwx = 0o777) of `path`.
fn modeBits(path: []const u8) !u32 {
    const f = try fs_compat.openFileAbsolute(path, .{});
    defer f.close();
    const st = try f.stat();
    return @intCast(st.permissions.toMode() & 0o777);
}

/// Build a scratch dir + its target/new/old/staged triple of paths.
/// All four live in the same dir so rename-based atomicity holds.
const Paths = struct {
    dir: []u8,
    target: []u8,
    new: []u8,
    old: []u8,
    staged: []u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Paths {
        const dir = try resetScratch(allocator, tag);
        return .{
            .dir = dir,
            .target = try std.fmt.allocPrint(allocator, "{s}/malt", .{dir}),
            .new = try std.fmt.allocPrint(allocator, "{s}/malt.new", .{dir}),
            .old = try std.fmt.allocPrint(allocator, "{s}/malt.old", .{dir}),
            .staged = try std.fmt.allocPrint(allocator, "{s}/.malt-update-{d}", .{ dir, std.c.getpid() }),
        };
    }

    fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        fs_compat.deleteTreeAbsolute(self.dir) catch {};
        allocator.free(self.dir);
        allocator.free(self.target);
        allocator.free(self.new);
        allocator.free(self.old);
        allocator.free(self.staged);
    }
};

// --- happy path ----------------------------------------------------------

test "atomicReplace swaps target and preserves original at .old" {
    var p = try Paths.init(testing.allocator, "happy");
    defer p.deinit(testing.allocator);

    try writeFile(p.target, "version-1-bytes");
    try writeFile(p.new, "version-2-bytes");

    try swap.atomicReplace(p.target, p.new);

    const target_contents = try readFile(testing.allocator, p.target);
    defer testing.allocator.free(target_contents);
    try testing.expectEqualStrings("version-2-bytes", target_contents);

    const old_contents = try readFile(testing.allocator, p.old);
    defer testing.allocator.free(old_contents);
    try testing.expectEqualStrings("version-1-bytes", old_contents);
}

test "atomicReplace leaves the swapped-in target executable (owner + group + other +x)" {
    var p = try Paths.init(testing.allocator, "exec");
    defer p.deinit(testing.allocator);

    try writeFile(p.target, "old");
    try writeFile(p.new, "new"); // createFile defaults to non-executable

    try swap.atomicReplace(p.target, p.new);

    // All three execute bits must be set (0o755 = rwxr-xr-x).
    const mode = try modeBits(p.target);
    try testing.expectEqual(@as(u32, 0o755), mode);
}

test "atomicReplace leaves new_path untouched - it is copied, not moved" {
    var p = try Paths.init(testing.allocator, "source_preserved");
    defer p.deinit(testing.allocator);

    try writeFile(p.target, "old");
    try writeFile(p.new, "fresh");

    try swap.atomicReplace(p.target, p.new);

    // Caller still owns new_path and can inspect / re-use it.
    const new_contents = try readFile(testing.allocator, p.new);
    defer testing.allocator.free(new_contents);
    try testing.expectEqualStrings("fresh", new_contents);
}

test "atomicReplace removes the staging file on success" {
    var p = try Paths.init(testing.allocator, "stage_gone");
    defer p.deinit(testing.allocator);

    try writeFile(p.target, "old");
    try writeFile(p.new, "new");

    try swap.atomicReplace(p.target, p.new);

    // Staged temp must not leak into the target directory.
    try testing.expectError(error.FileNotFound, fs_compat.accessAbsolute(p.staged, .{}));
}

// --- prior-run cleanup ---------------------------------------------------

test "atomicReplace overwrites a stale .old from a prior run" {
    var p = try Paths.init(testing.allocator, "stale_old");
    defer p.deinit(testing.allocator);

    try writeFile(p.old, "pre-existing-old-from-crash");
    try writeFile(p.target, "version-2");
    try writeFile(p.new, "version-3");

    try swap.atomicReplace(p.target, p.new);

    // The stale .old must have been replaced with the just-swapped-out
    // target, not preserved.
    const old_contents = try readFile(testing.allocator, p.old);
    defer testing.allocator.free(old_contents);
    try testing.expectEqualStrings("version-2", old_contents);
}

test "atomicReplace overwrites a stale staged file from a killed prior run" {
    var p = try Paths.init(testing.allocator, "stale_stage");
    defer p.deinit(testing.allocator);

    try writeFile(p.staged, "from-killed-run");
    try writeFile(p.target, "version-1");
    try writeFile(p.new, "version-2");

    try swap.atomicReplace(p.target, p.new);

    const target_contents = try readFile(testing.allocator, p.target);
    defer testing.allocator.free(target_contents);
    try testing.expectEqualStrings("version-2", target_contents);
}

// --- failure paths -------------------------------------------------------

test "atomicReplace returns StagingFailed when target directory is missing" {
    var p = try Paths.init(testing.allocator, "source_only");
    defer p.deinit(testing.allocator);
    try writeFile(p.new, "doesnt-matter");

    // Target dir literally does not exist - staging must not hit rename.
    const target = "/tmp/malt_swap_test_missing_dir_xyz_99/malt";
    fs_compat.deleteTreeAbsolute("/tmp/malt_swap_test_missing_dir_xyz_99") catch {};

    try testing.expectError(error.StagingFailed, swap.atomicReplace(target, p.new));
}

test "atomicReplace returns StagingFailed when new_path does not exist" {
    var p = try Paths.init(testing.allocator, "missing_source");
    defer p.deinit(testing.allocator);
    try writeFile(p.target, "old");
    // Deliberately do not create p.new.

    try testing.expectError(error.StagingFailed, swap.atomicReplace(p.target, p.new));

    // Target must be untouched when staging fails.
    const target_contents = try readFile(testing.allocator, p.target);
    defer testing.allocator.free(target_contents);
    try testing.expectEqualStrings("old", target_contents);
}

test "atomicReplace returns SwapFailed when target does not exist" {
    var p = try Paths.init(testing.allocator, "missing_target");
    defer p.deinit(testing.allocator);
    try writeFile(p.new, "new");
    // Deliberately do not create p.target.

    try testing.expectError(error.SwapFailed, swap.atomicReplace(p.target, p.new));
}

test "atomicReplace returns PermissionDenied when target dir is read-only" {
    // root bypasses POSIX mode bits, so the EACCES path under test cannot
    // fire — skip rather than mis-pass.
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var p = try Paths.init(testing.allocator, "readonly_dir");
    defer p.deinit(testing.allocator);
    try writeFile(p.target, "old");
    try writeFile(p.new, "new");

    // Drop write access on the parent directory; staging the new binary
    // next to the target must fail with EACCES, which the swap surfaces
    // as PermissionDenied for the updater's sudo-fallback path.
    const dir_z = try testing.allocator.dupeZ(u8, p.dir);
    defer testing.allocator.free(dir_z);
    if (std.c.chmod(dir_z.ptr, 0o555) != 0) return error.SkipZigTest;
    defer _ = std.c.chmod(dir_z.ptr, 0o755);

    try testing.expectError(error.PermissionDenied, swap.atomicReplace(p.target, p.new));

    // Target must still be intact after a permission-denied staging.
    _ = std.c.chmod(dir_z.ptr, 0o755);
    const target_contents = try readFile(testing.allocator, p.target);
    defer testing.allocator.free(target_contents);
    try testing.expectEqualStrings("old", target_contents);
}
