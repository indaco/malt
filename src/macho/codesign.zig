//! malt — codesign module
//! Ad-hoc codesigning wrapper for arm64 Mach-O binaries.

const std = @import("std");
const system_tools = @import("../system_tools.zig");
const builtin = @import("builtin");

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
pub fn adHocSign(io: std.Io, allocator: std.mem.Allocator, path: []const u8) CodesignError!void {
    const one = [_][]const u8{path};
    return adHocSignAll(io, allocator, &one);
}

/// Ad-hoc codesign every path in `paths` with a **single** `codesign`
/// subprocess invocation:
///     codesign --force --sign - path1 path2 ...
///
/// macOS `codesign(1)` accepts multiple path arguments, so this collapses
/// N spawn + wait cycles (~15 ms each on arm64) into one. For packages
/// with many Mach-O files (ffmpeg ships ~20+ dylibs and binaries) this
/// is the difference between ~300 ms and ~15 ms of codesign cost.
pub fn adHocSignAll(io: std.Io, allocator: std.mem.Allocator, paths: []const []const u8) CodesignError!void {
    if (paths.len == 0) return;

    // argv = ["/usr/bin/codesign", "--force", "--sign", "-", path1, path2, ...]
    var argv = std.ArrayList([]const u8).initCapacity(allocator, paths.len + 4) catch
        return CodesignError.OutOfMemory;
    defer argv.deinit(allocator);
    argv.appendAssumeCapacity(system_tools.codesign);
    argv.appendAssumeCapacity("--force");
    argv.appendAssumeCapacity("--sign");
    argv.appendAssumeCapacity("-");
    for (paths) |p| argv.appendAssumeCapacity(p);

    // Redirect stdout/stderr to /dev/null to suppress codesign messages.
    var spawned = std.process.spawn(io, .{
        .argv = argv.items,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return CodesignError.SpawnFailed;
    const term = spawned.wait(io) catch return CodesignError.CodesignFailed;
    switch (term) {
        .exited => |code| {
            if (code != 0) return CodesignError.CodesignFailed;
        },
        else => return CodesignError.CodesignFailed,
    }
}

test "adHocSignAll does not execute a prefix-resident codesign shim" {
    const testing = std.testing;
    const io = std.Options.debug_io;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try std.fmt.allocPrintSentinel(a, "/tmp/malt_codesign_shim_{d}", .{std.c.getpid()}, 0);
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const bin = try std.fmt.allocPrint(a, "{s}/bin", .{root});
    const shim = try std.fmt.allocPrint(a, "{s}/codesign", .{bin});
    try std.Io.Dir.cwd().createDirPath(io, bin);
    try std.Io.Dir.symLinkAbsolute(io, "/usr/bin/true", shim, .{});

    const path_entry = try std.fmt.allocPrintSentinel(a, "PATH={s}:/usr/bin:/bin", .{bin}, 0);
    const entries = [_:null]?[*:0]const u8{path_entry.ptr};
    const environ: std.process.Environ = .{ .block = .{ .slice = &entries } };
    var threaded: std.Io.Threaded = .init(testing.allocator, .{ .environ = environ });
    defer threaded.deinit();

    try testing.expectError(
        CodesignError.CodesignFailed,
        adHocSignAll(threaded.io(), a, &.{"/no/such/macho"}),
    );
}
