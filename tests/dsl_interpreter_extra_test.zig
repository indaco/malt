//! malt — DSL interpreter extra coverage
//! Exercises interpolation and a few additional branches.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const dsl = malt.dsl;
const formula_mod = malt.formula;

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

fn minimalJson(alloc: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{
        \\  "name": "testpkg",
        \\  "full_name": "testpkg",
        \\  "tap": "homebrew/core",
        \\  "desc": "",
        \\  "homepage": "",
        \\  "license": null,
        \\  "revision": 0,
        \\  "keg_only": false,
        \\  "post_install_defined": true,
        \\  "versions": {{ "stable": "1.0", "head": null }},
        \\  "dependencies": [],
        \\  "oldnames": [],
        \\  "bottle": {{ "stable": {{ "root_url": "", "files": {{}} }} }}
        \\}}
    , .{});
}

/// Stands in for `std.testing.tmpDir`, which roots its scratch under
/// `.zig-cache` — a tree the build system rewrites underneath a running test.
const Scratch = struct {
    path: []u8,

    fn init(tag: []const u8) !Scratch {
        const io = std.Options.debug_io;
        const raw = try test_io.uniqueTempPath(testing.allocator, "dsl_interp_extra", tag);
        defer testing.allocator.free(raw);
        test_io.deleteTreeAbsolute(io, raw) catch {};
        try test_io.cwd().createDirPath(io, raw);
        errdefer test_io.deleteTreeAbsolute(io, raw) catch {};

        // /tmp is a symlink to /private/tmp on macOS; resolve once so the
        // paths the interpreter reports back compare equal to `path`.
        var dir = try test_io.openDirAbsolute(io, raw, .{});
        defer dir.close(io);
        var buf: [test_io.max_path_bytes]u8 = undefined;
        const n = try std.Io.Dir.realPath(dir, io, &buf);
        return .{ .path = try testing.allocator.dupe(u8, buf[0..n]) };
    }

    fn deinit(self: *Scratch) void {
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        testing.allocator.free(self.path);
    }
};

fn setupCellar(prefix_dir: []const u8) !void {
    const cellar_path = try std.fs.path.join(testing.allocator, &.{ prefix_dir, "Cellar", "testpkg", "1.0" });
    defer testing.allocator.free(cellar_path);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar_path);
}

fn run(ruby_src: []const u8) !void {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var scratch = try Scratch.init("run");
    defer scratch.deinit();
    const prefix = scratch.path;
    try setupCellar(prefix);

    const json = try minimalJson(alloc);
    var f = try formula_mod.parseFormula(alloc, json);
    defer f.deinit();

    var flog = dsl.FallbackLog.init(alloc);
    defer flog.deinit();

    try dsl.executePostInstall(std.Options.debug_io, malt.app_ctx.processEnviron(), alloc, .{
        .name = f.name,
        .version = f.version,
        .pkg_version = f.pkg_version,
    }, ruby_src, prefix, &flog);
}

test "string interpolation inside post_install" {
    try run(
        \\name = "world"
        \\ohai "hello #{name}"
        \\
    );
}

test "calling an unknown method on a bare receiver falls through to the log" {
    // The interpreter catches UnknownMethod, logs to the fallback log, and
    // returns nil so the script continues.
    try run(
        \\ohai "before"
        \\x = some_totally_unknown_method_that_does_not_exist
        \\ohai "after"
        \\
    );
}
