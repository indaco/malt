//! malt — install.execute dispatch tests
//! Covers the early-return branches of `install.execute` (help, no-packages,
//! too-long prefix) and the happy path up to the lock/download stage by
//! using a non-resolvable package name against a scratch MALT_PREFIX.

const std = @import("std");
const malt = @import("malt");
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
        .{ malt.fs_compat.nanoTimestamp(), suffix },
        0,
    );
    malt.fs_compat.deleteTreeAbsolute(path) catch {};
    try malt.fs_compat.cwd().makePath(path);
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
    try malt.fs_compat.cwd().makePath(cache_api);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/formula_{s}.json", .{ cache_api, name });
    defer testing.allocator.free(path);
    const f = try malt.fs_compat.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(json);
}

test "execute --dry-run prints a plan for a cached formula" {
    const prefix_z: [:0]const u8 = "/tmp/mm";
    malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    try malt.fs_compat.cwd().makePath(prefix_z);
    const prefix: []const u8 = prefix_z;
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
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
    malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    try malt.fs_compat.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
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
    malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    try malt.fs_compat.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
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
    malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    try malt.fs_compat.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{prefix_z});
    defer testing.allocator.free(db_dir);
    try malt.fs_compat.cwd().makePath(db_dir);
    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/malt.db", .{db_dir}, 0);
    defer testing.allocator.free(db_path);

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

test "execute refuses to run when MALT_PREFIX is absurdly long (> 256 bytes)" {
    // The former 12-byte Mach-O ceiling is gone — install_name_tool
    // grows overflowing slots into __LINKEDIT padding. What remains is
    // a cheap upper bound on pathological values.
    const too_long = "/tmp/malt_install_exec_absurdly_long_" ++ "x" ** 400;
    defer _ = c.unsetenv("MALT_PREFIX");
    _ = c.setenv("MALT_PREFIX", too_long, 1);
    try testing.expectError(
        install.InstallError.PrefixAbsurd,
        install.execute(testing.allocator, &.{"wget"}),
    );
}

// ─── Revisioned formula handling (issue #77) ─────────────────────────
//
// Revisioned formulas (Homebrew `revision: 1` onwards) must land in
// `Cellar/<name>/<version>_<revision>`, because bottles are built
// against that path and bake it into LC_LOAD_DYLIB entries. A plain
// `Cellar/<name>/<version>` install produces "dyld: Library not
// loaded" at runtime (see issue #77 with pcre2 10.47_1).

test "execute --only-dependencies on a leaf formula plans nothing" {
    // Leaf formula → after dropping top-level the queue is empty, so the
    // "Dry run: would install ..." line never fires. Pins the early-return
    // branch so a future refactor cannot accidentally print a 0-package plan.
    const prefix_z: [:0]const u8 = "/tmp/mol";
    malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    try malt.fs_compat.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const json =
        \\{"name":"leaf","full_name":"leaf","tap":"homebrew/core","desc":"","homepage":"",
        \\ "versions":{"stable":"1.0"},"revision":0,"dependencies":[],"oldnames":[],
        \\ "keg_only":false,"post_install_defined":false,
        \\ "bottle":{"stable":{"root_url":"https://ghcr.io/v2/homebrew/core/leaf/blobs",
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
    try seedFormulaCache(prefix_z, "leaf", json);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.io_mod.beginStderrCapture(testing.allocator, &captured);
    defer malt.io_mod.endStderrCapture();

    try install.execute(arena.allocator(), &.{ "--dry-run", "--only-dependencies", "leaf" });

    try testing.expect(std.mem.indexOf(u8, captured.items, "Dry run: would install") == null);
}

test "execute --only-dependencies --dry-run plans deps but skips the requested formula" {
    // Brew parity: --only-dependencies installs the transitive deps but
    // never materialises or links the requested package. Captured stderr
    // is the cheapest way to assert the plan's contents from the outside.
    const prefix_z: [:0]const u8 = "/tmp/mod";
    malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    try malt.fs_compat.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    const dep_json =
        \\{"name":"beta","full_name":"beta","tap":"homebrew/core","desc":"","homepage":"",
        \\ "versions":{"stable":"1.0"},"revision":0,"dependencies":[],"oldnames":[],
        \\ "keg_only":false,"post_install_defined":false,
        \\ "bottle":{"stable":{"root_url":"https://ghcr.io/v2/homebrew/core/beta/blobs",
        \\   "files":{
        \\     "arm64_sequoia":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"bb"},
        \\     "arm64_sonoma":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"bb"},
        \\     "arm64_ventura":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"bb"},
        \\     "arm64_monterey":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"bb"},
        \\     "sequoia":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"bx"},
        \\     "sonoma":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"bx"},
        \\     "ventura":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"bx"},
        \\     "monterey":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"bx"}
        \\   }}}}
    ;
    try seedFormulaCache(prefix_z, "beta", dep_json);

    const root_json =
        \\{"name":"alpha","full_name":"alpha","tap":"homebrew/core","desc":"","homepage":"",
        \\ "versions":{"stable":"1.0"},"revision":0,"dependencies":["beta"],"oldnames":[],
        \\ "keg_only":false,"post_install_defined":false,
        \\ "bottle":{"stable":{"root_url":"https://ghcr.io/v2/homebrew/core/alpha/blobs",
        \\   "files":{
        \\     "arm64_sequoia":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
        \\     "arm64_sonoma":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
        \\     "arm64_ventura":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
        \\     "arm64_monterey":{"cellar":":any","url":"https://ghcr.io/v2/arm","sha256":"aa"},
        \\     "sequoia":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"ax"},
        \\     "sonoma":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"ax"},
        \\     "ventura":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"ax"},
        \\     "monterey":{"cellar":":any","url":"https://ghcr.io/v2/x86","sha256":"ax"}
        \\   }}}}
    ;
    try seedFormulaCache(prefix_z, "alpha", root_json);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // `output.quiet` is process-global; earlier tests in this file pass
    // `--quiet` and leave it set. Reset so the dry-run plan reaches our capture.
    const prior_quiet = malt.output.isQuiet();
    malt.output.setQuiet(false);
    defer malt.output.setQuiet(prior_quiet);

    var captured: std.ArrayList(u8) = .empty;
    defer captured.deinit(testing.allocator);
    malt.io_mod.beginStderrCapture(testing.allocator, &captured);
    defer malt.io_mod.endStderrCapture();

    try install.execute(arena.allocator(), &.{ "--dry-run", "--only-dependencies", "alpha" });

    // The dry-run plan header is the load-bearing observation: with the
    // top-level filtered, only the single dep should land in the plan.
    // (`alpha` still appears upstream in the "Resolved alpha …" log line
    // emitted before the filter, so we anchor on the plan header instead.)
    try testing.expect(std.mem.indexOf(u8, captured.items, "would install 1 package") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "beta 1.0 (dependency)") != null);
    try testing.expect(std.mem.indexOf(u8, captured.items, "would install 2 packages") == null);
}

test "execute --dry-run routes a revisioned formula through the install pipeline" {
    // The dry-run path flows: ensureDirs → DB open → lock → cache hit
    // → collectFormulaJobs → print plan → return. A revisioned formula
    // exercises every call site that reads `formula.pkg_version` in
    // place of the plain `version`.
    const prefix_z: [:0]const u8 = "/tmp/mr";
    malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    try malt.fs_compat.cwd().makePath(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer malt.fs_compat.deleteTreeAbsolute(prefix_z) catch {};
    defer _ = c.unsetenv("MALT_PREFIX");

    // revision=1 → the keg dir under Cellar must be "10.47_1", not "10.47".
    const json =
        \\{"name":"rev1","full_name":"rev1","tap":"homebrew/core","desc":"","homepage":"",
        \\ "versions":{"stable":"10.47"},"revision":1,"dependencies":[],"oldnames":[],
        \\ "keg_only":false,"post_install_defined":false,
        \\ "bottle":{"stable":{"root_url":"https://ghcr.io/v2/homebrew/core/rev1/blobs",
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
    try seedFormulaCache(prefix_z, "rev1", json);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try install.execute(arena.allocator(), &.{ "--dry-run", "--quiet", "rev1" });
}
