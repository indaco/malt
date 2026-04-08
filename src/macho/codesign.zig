//! malt — codesign module
//! Ad-hoc codesigning wrapper for arm64 Mach-O binaries.

const std = @import("std");
const builtin = @import("builtin");
const parser = @import("parser.zig");

pub const CodesignError = error{
    CodesignFailed,
    CodesignNotFound,
    SpawnFailed,
};

/// Returns true if the current build target is arm64 (aarch64).
pub fn isArm64() bool {
    return builtin.cpu.arch == .aarch64;
}

/// Ad-hoc codesign a single binary: `codesign --force --sign - <path>`
pub fn adHocSign(path: []const u8) CodesignError!void {
    const argv = [_][]const u8{ "codesign", "--force", "--sign", "-", path };
    var child = std.process.Child.init(&argv, std.heap.page_allocator);
    child.spawn() catch return CodesignError.SpawnFailed;
    const term = child.wait() catch return CodesignError.CodesignFailed;
    switch (term) {
        .exited => |code| {
            if (code != 0) return CodesignError.CodesignFailed;
        },
        else => return CodesignError.CodesignFailed,
    }
}

/// Ad-hoc codesign all Mach-O files in a list of paths.
pub fn adHocSignAll(paths: []const []const u8) CodesignError!void {
    for (paths) |path| {
        try adHocSign(path);
    }
}

/// Find all Mach-O binaries in a directory and codesign them.
/// Skips non-Mach-O files silently.
pub fn signAllMachOInDir(dir_path: []const u8, allocator: std.mem.Allocator) !void {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        // Read first 4 bytes to check magic
        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();

        var magic_buf: [4]u8 = undefined;
        const bytes_read = file.readAll(&magic_buf) catch continue;
        if (bytes_read < 4) continue;

        if (parser.isMachO(&magic_buf)) {
            // Build full path
            const full_path = std.fs.path.join(allocator, &.{ dir_path, entry.path }) catch continue;
            defer allocator.free(full_path);
            adHocSign(full_path) catch continue;
        }
    }
}
