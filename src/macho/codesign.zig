//! malt — codesign module
//! Ad-hoc codesigning wrapper for arm64 Mach-O binaries.

const std = @import("std");
const builtin = @import("builtin");
const fs_compat = @import("../fs/compat.zig");

pub const CodesignError = error{
    CodesignFailed,
    CodesignNotFound,
    SpawnFailed,
    OutOfMemory,
};

/// Returns true if the current build target is arm64 (aarch64).
pub fn isArm64() bool {
    return builtin.cpu.arch == .aarch64;
}

/// Ad-hoc codesign a single binary. Thin wrapper around `adHocSignAll`
/// kept for callers that have exactly one path on hand.
pub fn adHocSign(allocator: std.mem.Allocator, path: []const u8) CodesignError!void {
    const one = [_][]const u8{path};
    return adHocSignAll(allocator, &one);
}

/// Ad-hoc codesign every path in `paths` with a **single** `codesign`
/// subprocess invocation:
///     codesign --force --sign - path1 path2 ...
///
/// macOS `codesign(1)` accepts multiple path arguments, so this collapses
/// N spawn + wait cycles (~15 ms each on arm64) into one. For packages
/// with many Mach-O files (ffmpeg ships ~20+ dylibs and binaries) this
/// is the difference between ~300 ms and ~15 ms of codesign cost.
pub fn adHocSignAll(allocator: std.mem.Allocator, paths: []const []const u8) CodesignError!void {
    if (paths.len == 0) return;

    // argv = ["codesign", "--force", "--sign", "-", path1, path2, ...]
    var argv = std.ArrayList([]const u8).initCapacity(allocator, paths.len + 4) catch
        return CodesignError.OutOfMemory;
    defer argv.deinit(allocator);
    argv.appendAssumeCapacity("codesign");
    argv.appendAssumeCapacity("--force");
    argv.appendAssumeCapacity("--sign");
    argv.appendAssumeCapacity("-");
    for (paths) |p| argv.appendAssumeCapacity(p);

    var child = fs_compat.Child.init(argv.items, allocator);
    // Redirect stdout/stderr to /dev/null to suppress codesign messages
    child.stdout_behavior = .ignore;
    child.stderr_behavior = .ignore;
    child.spawn() catch return CodesignError.SpawnFailed;
    const term = child.wait() catch return CodesignError.CodesignFailed;
    switch (term) {
        .exited => |code| {
            if (code != 0) return CodesignError.CodesignFailed;
        },
        else => return CodesignError.CodesignFailed,
    }
}
