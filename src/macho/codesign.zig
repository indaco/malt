//! malt — codesign module
//! Ad-hoc codesigning wrapper for arm64 Mach-O binaries.

const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");

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

    var child = std.process.Child.init(argv.items, allocator);
    // Redirect stdout/stderr to /dev/null to suppress codesign messages
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return CodesignError.SpawnFailed;
    const term = child.wait() catch return CodesignError.CodesignFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return CodesignError.CodesignFailed;
        },
        else => return CodesignError.CodesignFailed,
    }
}

/// Find all Mach-O binaries in a directory and codesign them in one
/// batched subprocess call. Skips non-Mach-O files silently.
pub fn signAllMachOInDir(dir_path: []const u8, allocator: std.mem.Allocator) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    // Collect the full paths of every Mach-O file under `dir_path`, then
    // hand them to `adHocSignAll` as a single batch. See that function
    // for why this is dramatically cheaper than signing one at a time.
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Read first 4 bytes to check magic
        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();

        var magic_buf: [4]u8 = undefined;
        const bytes_read = file.readAll(&magic_buf) catch continue;
        if (bytes_read < 4) continue;

        if (parser.isMachO(&magic_buf)) {
            const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.path }) catch continue;
            paths.append(allocator, full_path) catch {
                allocator.free(full_path);
                continue;
            };
        }
    }

    if (paths.items.len == 0) return;

    adHocSignAll(allocator, paths.items) catch |e| {
        // Log the batch failure; one bad binary shouldn't fail the whole
        // materialize — the old per-file loop silently skipped individual
        // failures, keep the same permissive contract.
        std.log.warn("codesign batch failed for {s}: {s}", .{ dir_path, @errorName(e) });
    };
}
