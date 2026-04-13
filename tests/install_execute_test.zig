//! malt — install.execute dispatch tests
//! Covers the early-return branches of `install.execute` (help, no-packages,
//! too-long prefix) and the happy path up to the lock/download stage by
//! using a non-resolvable package name against a scratch MALT_PREFIX.

const std = @import("std");
const testing = std.testing;
const install = @import("malt").install;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

fn setupPrefix(suffix: []const u8) ![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_install_exec_{d}_{s}",
        .{ std.time.nanoTimestamp(), suffix },
        0,
    );
    std.fs.deleteTreeAbsolute(path) catch {};
    try std.fs.cwd().makePath(path);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    return path;
}

test "execute with --help short-circuits before touching the filesystem" {
    defer _ = c.unsetenv("MALT_PREFIX");
    _ = c.setenv("MALT_PREFIX", "/tmp/malt_install_exec_help_skipfs", 1);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{"--help"});
    try install.execute(arena.allocator(), &.{"-h"});
}

test "execute with no positional args reports NoPackages" {
    defer _ = c.unsetenv("MALT_PREFIX");
    _ = c.setenv("MALT_PREFIX", "/tmp/malt_install_exec_nopkg", 1);
    try testing.expectError(
        install.InstallError.NoPackages,
        install.execute(testing.allocator, &.{ "--force", "--dry-run" }),
    );
}

fn seedFormulaCache(prefix: []const u8, name: []const u8, json: []const u8) !void {
    const cache_api = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api", .{prefix});
    defer testing.allocator.free(cache_api);
    try std.fs.cwd().makePath(cache_api);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/formula_{s}.json", .{ cache_api, name });
    defer testing.allocator.free(path);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(json);
}

test "execute --dry-run prints a plan for a cached formula" {
    // The Mach-O in-place patching budget is "/opt/homebrew".len (13 bytes),
    // so the test prefix must be short enough to pass checkPrefixLength.
    const prefix_z: [:0]const u8 = "/tmp/mm";
    std.fs.deleteTreeAbsolute(prefix_z) catch {};
    try std.fs.cwd().makePath(prefix_z);
    const prefix: []const u8 = prefix_z;
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer std.fs.deleteTreeAbsolute(prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const json =
        \\{"name":"alpha","full_name":"alpha","tap":"homebrew/core","desc":"","homepage":"",
        \\ "versions":{"stable":"1.0"},"revision":0,"dependencies":[],"oldnames":[],
        \\ "keg_only":false,"post_install_defined":false,
        \\ "bottle":{"stable":{"root_url":"https://ghcr.io/v2/homebrew/core/alpha/blobs",
        \\   "files":{
        \\     "arm64_sequoia":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
        \\     "arm64_sonoma":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
        \\     "arm64_ventura":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
        \\     "arm64_monterey":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
        \\     "sequoia":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"xx"},
        \\     "sonoma":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"xx"},
        \\     "ventura":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"xx"},
        \\     "monterey":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"xx"}
        \\   }}}}
    ;
    try seedFormulaCache(prefix, "alpha", json);

    // Dry-run goes: ensureDirs → open DB → acquire lock → cache hit for alpha →
    // cache miss for the optional cask probe (swallowed) → collectFormulaJobs →
    // print "Dry run: would install ..." → return without downloading.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--dry-run", "--quiet", "alpha" });
}

test "execute with --formula forces formula-only and errors on an unresolvable name" {
    const prefix_z: [:0]const u8 = "/tmp/mf";
    std.fs.deleteTreeAbsolute(prefix_z) catch {};
    try std.fs.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer std.fs.deleteTreeAbsolute(prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // `--formula` + an unknown name → fetchFormula fails → formula-only
    // early-return without touching the cask path. No PartialFailure is
    // raised for a single unknown name (the catch branch reports via
    // output.err but doesn't queue any jobs, so the later all_jobs.len==0
    // return fires first).
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--formula", "--dry-run", "--quiet", "zz_nonexistent_formula_xyz" });
}

test "execute with a tap-formula-shaped name routes through the tap path in dry-run" {
    const prefix_z: [:0]const u8 = "/tmp/mt";
    std.fs.deleteTreeAbsolute(prefix_z) catch {};
    try std.fs.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer std.fs.deleteTreeAbsolute(prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // user/repo/formula triggers installTapFormula, which early-returns
    // when the tap isn't cloned locally. No exception is raised; the error
    // surfaces via output.err.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--dry-run", "--quiet", "zzuser/zzrepo/zzformula" });
}

test "execute --dry-run with an already-installed package short-circuits" {
    const prefix_z: [:0]const u8 = "/tmp/mi";
    std.fs.deleteTreeAbsolute(prefix_z) catch {};
    try std.fs.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer std.fs.deleteTreeAbsolute(prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix_z});
    defer testing.allocator.free(db_dir);
    try std.fs.cwd().makePath(db_dir);
    const db_path = try std.fmt.allocPrint(testing.allocator, "{s}/malt.db", .{db_dir});
    defer testing.allocator.free(db_path);

    const malt = @import("malt");
    var db = try malt.sqlite.Database.open(db_path);
    try malt.schema.initSchema(&db);
    var stmt = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path)
        \\VALUES (?, ?, ?, ?, ?);
    );
    try stmt.bindText(1, "seeded");
    try stmt.bindText(2, "seeded");
    try stmt.bindText(3, "1.0");
    try stmt.bindText(4, "0" ** 64);
    try stmt.bindText(5, "/tmp/mi/Cellar/seeded/1.0");
    _ = try stmt.step();
    stmt.finalize();
    db.close();

    const json =
        \\{"name":"seeded","full_name":"seeded","tap":"homebrew/core","desc":"","homepage":"",
        \\ "versions":{"stable":"1.0"},"revision":0,"dependencies":[],"oldnames":[],
        \\ "keg_only":false,"post_install_defined":false,
        \\ "bottle":{"stable":{"root_url":"","files":{}}}}
    ;
    try seedFormulaCache(prefix_z, "seeded", json);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--dry-run", "--quiet", "seeded" });
}

test "execute refuses to run when MALT_PREFIX exceeds the Mach-O budget" {
    const too_long = "/tmp/malt_install_exec_too_long_" ++ "x" ** 64;
    defer _ = c.unsetenv("MALT_PREFIX");
    _ = c.setenv("MALT_PREFIX", too_long, 1);
    try testing.expectError(
        install.InstallError.PrefixTooLong,
        install.execute(testing.allocator, &.{"wget"}),
    );
}
