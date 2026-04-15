//! malt — DSL interpreter extra coverage
//! Exercises interpolation and a few additional branches.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
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

fn setupCellar(prefix_dir: []const u8) !void {
    const cellar_path = try std.fs.path.join(testing.allocator, &.{ prefix_dir, "Cellar", "testpkg", "1.0" });
    defer testing.allocator.free(cellar_path);
    try malt.fs_compat.cwd().makePath(cellar_path);
}

fn run(ruby_src: []const u8) !void {
    var arena = testArena();
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = blk: {
        const n = try std.Io.Dir.realPath(tmp.dir, malt.io_mod.ctx(), &path_buf);
        break :blk path_buf[0..n];
    };
    try setupCellar(prefix);

    const json = try minimalJson(alloc);
    var f = try formula_mod.parseFormula(alloc, json);
    defer f.deinit();

    var flog = dsl.FallbackLog.init(alloc);
    defer flog.deinit();

    try dsl.executePostInstall(alloc, &f, ruby_src, prefix, &flog);
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
