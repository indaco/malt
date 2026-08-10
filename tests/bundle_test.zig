//! malt — bundle runner / CLI smoke tests
//!
//! `dry_run = true` lets us exercise the orchestration logic without forking
//! `malt install` for every member.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const test_io = @import("test_io");
const sqlite = malt.sqlite;
const schema = malt.schema;
const manifest_mod = malt.bundle_manifest;
const runner = malt.bundle_runner;
const install = malt.install;
const install_sink = malt.install_sink;
const output = malt.output;

/// Scratch DB under a process-unique dir, so overlapping test runs cannot
/// wipe each other's fixtures.
const TempDb = struct {
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    db: sqlite.Database,

    fn init(tag: []const u8) !TempDb {
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        errdefer arena.deinit();
        const dir = try test_io.uniqueTempPath(arena.allocator(), "bundle", tag);
        test_io.deleteTreeAbsolute(std.Options.debug_io, dir) catch {};
        try test_io.makeDirAbsolute(std.Options.debug_io, dir);
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/test.db", .{dir}, 0);
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .arena = arena, .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.dir) catch {};
        self.arena.deinit();
    }
};

fn buildManifest(parent: std.mem.Allocator) !manifest_mod.Manifest {
    var m = manifest_mod.Manifest.init(parent);
    const a = m.allocator();
    m.name = try a.dupe(u8, "devtools");
    m.version = manifest_mod.schema_version;

    const taps = try a.alloc([]const u8, 1);
    taps[0] = try a.dupe(u8, "homebrew/cask-fonts");
    m.taps = taps;

    const formulas = try a.alloc(manifest_mod.FormulaEntry, 2);
    formulas[0] = .{ .name = try a.dupe(u8, "wget") };
    formulas[1] = .{ .name = try a.dupe(u8, "jq"), .version = try a.dupe(u8, "1.7") };
    m.formulas = formulas;

    const casks = try a.alloc(manifest_mod.CaskEntry, 1);
    casks[0] = .{ .name = try a.dupe(u8, "ghostty") };
    m.casks = casks;

    return m;
}

test "dry-run runner does not fork and skips DB write" {
    var t = try TempDb.init("dry_run");
    defer t.deinit();

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    var report = try runner.run(std.Options.debug_io, testing.allocator, &t.db, m, .{ .dry_run = true, .prefix = t.dir });
    defer report.deinit();

    var stmt = try t.db.prepare("SELECT COUNT(*) FROM bundles;");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

test "non-dry runner with mocked malt_bin records bundle even on member failure" {
    var t = try TempDb.init("record");
    defer t.deinit();

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    // Use /usr/bin/false: spawns succeed but each call exits non-zero.
    // The runner should still record the bundle row despite every member
    // landing in the failures list.
    var report = try runner.run(std.Options.debug_io, testing.allocator, &t.db, m, .{
        .dry_run = false,
        .malt_bin = "/usr/bin/false",
        .prefix = t.dir,
    });
    defer report.deinit();
    try testing.expect(report.hasFailure());
    try testing.expectEqual(@as(usize, 4), report.failures.len);
    // Subprocess exit-code propagation lands as the typed MemberFailed tag.
    for (report.failures) |f| {
        const expected: runner.DispatchError = runner.DispatchError.MemberFailed;
        try testing.expectEqual(expected, f.err);
    }

    var stmt = try t.db.prepare("SELECT COUNT(*) FROM bundles WHERE name='devtools';");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));

    var ms = try t.db.prepare("SELECT COUNT(*) FROM bundle_members WHERE bundle_name='devtools';");
    defer ms.finalize();
    _ = try ms.step();
    // 1 tap + 2 formulas + 1 cask = 4 members
    try testing.expectEqual(@as(i64, 4), ms.columnInt(0));
}

test "runner routes members through the provided dispatcher" {
    var t = try TempDb.init("dispatcher");
    defer t.deinit();

    // Capture which primitive each member hit so we can prove runner.zig
    // no longer reaches into cli/* via argv.
    var calls = Calls.init(testing.allocator);
    defer calls.deinit();

    const dispatcher = runner.Dispatcher{
        .ctx = &calls,
        .installFormula = Calls.installFormulaFn,
        .installCask = Calls.installCaskFn,
        .tapAdd = Calls.tapAddFn,
        .serviceStart = Calls.serviceStartFn,
    };

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    var report = try runner.run(std.Options.debug_io, testing.allocator, &t.db, m, .{
        .dry_run = false,
        .prefix = t.dir,
        .dispatcher = &dispatcher,
    });
    defer report.deinit();
    try testing.expect(!report.hasFailure());

    try testing.expectEqual(@as(usize, 1), calls.taps.items.len);
    try testing.expectEqualStrings("homebrew/cask-fonts", calls.taps.items[0]);
    try testing.expectEqual(@as(usize, 2), calls.formulas.items.len);
    try testing.expectEqualStrings("wget", calls.formulas.items[0]);
    try testing.expectEqualStrings("jq", calls.formulas.items[1]);
    try testing.expectEqual(@as(usize, 1), calls.casks.items.len);
    try testing.expectEqualStrings("ghostty", calls.casks.items[0]);
    try testing.expectEqual(@as(usize, 0), calls.services.items.len);
}

// Every bundle member is a whole install, so Ctrl-C has to be answered
// between members. The run above pins the full dispatch set, so a short one
// here is the manifest being abandoned.
test "runner stops dispatching members and records no bundle when interrupted" {
    var t = try TempDb.init("interrupted");
    defer t.deinit();

    var calls = Calls.init(testing.allocator);
    defer calls.deinit();

    const dispatcher = runner.Dispatcher{
        .ctx = &calls,
        .installFormula = Calls.installFormulaFn,
        .installCask = Calls.installCaskFn,
        .tapAdd = Calls.tapAddFn,
        .serviceStart = Calls.serviceStartFn,
    };

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    const prior = malt.signals.isInterrupted();
    defer malt.signals.setInterruptedForTest(prior);
    defer malt.signals.armInterruptAfterForTest(0);
    malt.signals.setInterruptedForTest(false);
    malt.signals.armInterruptAfterForTest(2); // fires on the member after the tap

    var report = try runner.run(std.Options.debug_io, testing.allocator, &t.db, m, .{
        .dry_run = false,
        .prefix = t.dir,
        .dispatcher = &dispatcher,
    });
    defer report.deinit();

    try testing.expectEqual(@as(usize, 1), calls.taps.items.len);
    try testing.expectEqual(@as(usize, 0), calls.formulas.items.len);
    try testing.expectEqual(@as(usize, 0), calls.casks.items.len);

    // A partial run must not leave a bundle row claiming members that never
    // landed — `bundle cleanup` would later act on them.
    var stmt = try t.db.prepare("SELECT COUNT(*) FROM bundles;");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

const Calls = struct {
    allocator: std.mem.Allocator,
    taps: std.ArrayList([]const u8),
    formulas: std.ArrayList([]const u8),
    casks: std.ArrayList([]const u8),
    services: std.ArrayList([]const u8),

    fn init(allocator: std.mem.Allocator) Calls {
        return .{
            .allocator = allocator,
            .taps = .empty,
            .formulas = .empty,
            .casks = .empty,
            .services = .empty,
        };
    }

    fn deinit(self: *Calls) void {
        self.taps.deinit(self.allocator);
        self.formulas.deinit(self.allocator);
        self.casks.deinit(self.allocator);
        self.services.deinit(self.allocator);
    }

    fn record(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, name: []const u8) !void {
        try list.append(allocator, name);
    }

    // ctx round-trips through the Dispatcher vtable as *anyopaque; these
    // casts restore the concrete type the test injected.
    fn unwrap(ctx: ?*anyopaque) *Calls {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn tapAddFn(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) runner.DispatchError!void {
        const self = unwrap(ctx);
        record(&self.taps, allocator, name) catch return runner.DispatchError.OutOfMemory;
    }
    fn installFormulaFn(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) runner.DispatchError!void {
        const self = unwrap(ctx);
        record(&self.formulas, allocator, name) catch return runner.DispatchError.OutOfMemory;
    }
    fn installCaskFn(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) runner.DispatchError!void {
        const self = unwrap(ctx);
        record(&self.casks, allocator, name) catch return runner.DispatchError.OutOfMemory;
    }
    fn serviceStartFn(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) runner.DispatchError!void {
        const self = unwrap(ctx);
        record(&self.services, allocator, name) catch return runner.DispatchError.OutOfMemory;
    }
};

test "runner returns Report with per-member failures, not a bool" {
    // Pins the contract: the runner collects structured failures so the
    // CLI layer can render; core/* itself emits no UI.
    var t = try TempDb.init("report_failures");
    defer t.deinit();

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    var report = try runner.run(std.Options.debug_io, testing.allocator, &t.db, m, .{
        .dry_run = false,
        .malt_bin = "/usr/bin/false",
        .prefix = t.dir,
    });
    defer report.deinit();

    try testing.expect(report.hasFailure());
    // 1 tap + 2 formulas + 1 cask all exit non-zero under /usr/bin/false.
    try testing.expectEqual(@as(usize, 4), report.failures.len);
    try testing.expectEqual(runner.MemberKind.tap, report.failures[0].kind);
    try testing.expectEqualStrings("homebrew/cask-fonts", report.failures[0].name);
    try testing.expectEqual(runner.MemberKind.formula, report.failures[1].kind);
    try testing.expectEqualStrings("wget", report.failures[1].name);
    try testing.expectEqual(runner.MemberKind.formula, report.failures[2].kind);
    try testing.expectEqualStrings("jq", report.failures[2].name);
    try testing.expectEqual(runner.MemberKind.cask, report.failures[3].kind);
    try testing.expectEqualStrings("ghostty", report.failures[3].name);
    try testing.expectEqual(@as(usize, 0), report.previews.len);
}

test "dry-run report captures previews, no failures, no DB write" {
    var t = try TempDb.init("report_previews");
    defer t.deinit();

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    var report = try runner.run(std.Options.debug_io, testing.allocator, &t.db, m, .{
        .dry_run = true,
        .prefix = t.dir,
    });
    defer report.deinit();

    try testing.expect(!report.hasFailure());
    try testing.expectEqual(@as(usize, 0), report.failures.len);
    // 1 tap + 2 formulas + 1 cask = 4 previews.
    try testing.expectEqual(@as(usize, 4), report.previews.len);
    try testing.expectEqual(runner.MemberKind.tap, report.previews[0].kind);
    try testing.expectEqualStrings("homebrew/cask-fonts", report.previews[0].name);
}

test "runner refuses in-process bundle install with no dispatcher and no malt_bin" {
    var t = try TempDb.init("no_dispatcher");
    defer t.deinit();

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    var report = try runner.run(std.Options.debug_io, testing.allocator, &t.db, m, .{
        .dry_run = false,
        .prefix = t.dir,
    });
    defer report.deinit();
    try testing.expect(report.hasFailure());
    try testing.expectEqual(@as(usize, 4), report.failures.len);
    // Each member's err is DispatchError.NoDispatcher. The explicit type
    // coercion on the literal pins that MemberError.err is the closed
    // DispatchError set, not anyerror — a regression here surfaces at
    // comptime before the runtime assertion ever fires.
    for (report.failures) |f| {
        const expected: runner.DispatchError = runner.DispatchError.NoDispatcher;
        try testing.expectEqual(expected, f.err);
        try testing.expectEqualStrings("NoDispatcher", @errorName(f.err));
    }

    var stmt = try t.db.prepare("SELECT COUNT(*) FROM bundles WHERE name='devtools';");
    defer stmt.finalize();
    _ = try stmt.step();
    // recordBundle still runs even on partial failure, matching the
    // existing `/usr/bin/false` test — this pins that invariant.
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
}

test "dispatcher returning DispatchFailed lands as a typed MemberError" {
    // Pins the boundary contract: cli/bundle.zig narrows underlying CLI
    // errors to DispatchFailed before the runner sees them. A regression
    // that re-widens to anyerror would fail the comptime coercion below.
    var t = try TempDb.init("typed_dispatch_failed");
    defer t.deinit();

    const Failing = struct {
        fn fail(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) runner.DispatchError!void {
            return runner.DispatchError.DispatchFailed;
        }
    };
    const dispatcher = runner.Dispatcher{
        .installFormula = Failing.fail,
        .installCask = Failing.fail,
        .tapAdd = Failing.fail,
        .serviceStart = Failing.fail,
    };

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    var report = try runner.run(std.Options.debug_io, testing.allocator, &t.db, m, .{
        .dry_run = false,
        .prefix = t.dir,
        .dispatcher = &dispatcher,
    });
    defer report.deinit();
    try testing.expect(report.hasFailure());
    try testing.expectEqual(@as(usize, 4), report.failures.len);
    for (report.failures) |f| {
        const expected: runner.DispatchError = runner.DispatchError.DispatchFailed;
        try testing.expectEqual(expected, f.err);
        try testing.expectEqualStrings("DispatchFailed", @errorName(f.err));
    }
}

test "round-trip: parse Brewfile fixture, run dry, no panic" {
    var t = try TempDb.init("smoke");
    defer t.deinit();

    const fixture =
        \\tap "homebrew/cask-fonts"
        \\brew "wget"
        \\brew "jq", version: "1.7"
        \\cask "ghostty"
        \\# real-world dotfiles often have these:
        \\whalebrew "foo/bar"
    ;
    var m = try malt.bundle_brewfile.parse(testing.allocator, fixture, null);
    defer m.deinit();

    var report = try runner.run(std.Options.debug_io, testing.allocator, &t.db, m, .{ .dry_run = true, .prefix = t.dir });
    defer report.deinit();
}

test "bundle install honors the global --dry-run flag set by main.zig" {
    // Repro for T-034a: main.zig consumes `--dry-run` before it reaches
    // `cmdInstall`, so the local arm never fires and the runner ran with
    // `dry_run = false`. Pin the contract: when `output.isDryRun()` is true,
    // the runner must skip `recordBundle`, leaving the `bundles` table empty.
    const dir = try test_io.uniqueTempPath(testing.allocator, "bundle", "dry_run_cli_wire");
    defer testing.allocator.free(dir);
    const dir_z = try testing.allocator.dupeZ(u8, dir);
    defer testing.allocator.free(dir_z);
    test_io.deleteTreeAbsolute(std.Options.debug_io, dir_z) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, dir_z);
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, dir_z) catch {};

    _ = c.setenv("MALT_PREFIX", dir_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Empty-but-valid Brewfile: parser yields an empty manifest, so the
    // dispatcher is never called and the only observable side-effect is
    // the `recordBundle` insert — which dry-run must suppress.
    const bf_path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{dir_z});
    defer testing.allocator.free(bf_path);
    {
        const f = try test_io.cwd().createFile(std.Options.debug_io, bf_path, .{});
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "# empty\n");
    }

    malt.output.setDryRun(true);
    defer malt.output.setDryRun(false);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try malt.cli_bundle.execute(&ctx, testing.allocator, &.{ "install", bf_path });

    const db_path = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/db/malt.db", .{dir_z}, 0);
    defer testing.allocator.free(db_path);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    var stmt = try db.prepare("SELECT COUNT(*) FROM bundles;");
    defer stmt.finalize();
    _ = try stmt.step();
    try testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
}

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

test "real-world Brewfile shapes parse without error" {
    // Regression canary: shapes pulled from popular public dotfiles repos.
    // We assert parse + dry-run succeed; we do not assert specific counts so
    // the fixture can grow without churn.
    const fixture =
        \\tap "homebrew/cask"
        \\tap "homebrew/cask-fonts"
        \\tap "homebrew/services"
        \\
        \\# Core CLI tools
        \\brew "git"
        \\brew "wget"
        \\brew "curl"
        \\brew "jq"
        \\brew "ripgrep"
        \\brew "fzf"
        \\brew "tmux"
        \\brew "neovim"
        \\
        \\# Versioned + service flags
        \\brew "postgresql@16", restart_service: true
        \\brew "redis", restart_service: :changed
        \\brew "node@20", link: true
        \\
        \\# App Store apps
        \\mas "Xcode", id: 497799835
        \\mas "Things 3", id: 904280696
        \\
        \\# VS Code extensions
        \\vscode "ms-python.python"
        \\vscode "rust-lang.rust-analyzer"
        \\
        \\# Casks
        \\cask "ghostty"
        \\cask "visual-studio-code"
        \\cask "font-fira-code"
    ;

    var t = try TempDb.init("realworld");
    defer t.deinit();

    var m = try malt.bundle_brewfile.parse(testing.allocator, fixture, null);
    defer m.deinit();

    try testing.expect(m.taps.len >= 3);
    try testing.expect(m.formulas.len >= 8);
    try testing.expect(m.casks.len >= 3);

    var report = try runner.run(std.Options.debug_io, testing.allocator, &t.db, m, .{ .dry_run = true, .prefix = t.dir });
    defer report.deinit();
}

/// Mirrors `cli/bundle.zig`'s real dispatcher: route a member install
/// through `installAll` with the silent sink, mapping any failure to a
/// structured `MemberFailed` so the runner's `Report` carries it.
const SilentInstallCtx = struct {
    app: *const malt.app_ctx.AppCtx,

    fn installFormulaFn(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) runner.DispatchError!void {
        const self: *SilentInstallCtx = @ptrCast(@alignCast(ctx.?));
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        install.installAll(self.app, arena.allocator(), &.{name}, .{ .sink = install_sink.silent }) catch
            return runner.DispatchError.MemberFailed;
    }
    fn unusedFn(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8) runner.DispatchError!void {
        unreachable;
    }
};

test "silent-sink dispatcher: member failure surfaces via Report with no stderr spam" {
    var t = try TempDb.init("silent_sink");
    defer t.deinit();

    // installAll resolves its prefix from MALT_PREFIX; pin it to the temp dir.
    const prefix_z = try std.fmt.allocPrintSentinel(testing.allocator, "{s}", .{t.dir}, 0);
    defer testing.allocator.free(prefix_z);
    _ = c.setenv("MALT_PREFIX", prefix_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Single unresolvable formula isolates the install path: only
    // installFormula fires, and it fails fast offline.
    var m = manifest_mod.Manifest.init(testing.allocator);
    defer m.deinit();
    const a = m.allocator();
    m.name = try a.dupe(u8, "solo");
    m.version = manifest_mod.schema_version;
    const formulas = try a.alloc(manifest_mod.FormulaEntry, 1);
    formulas[0] = .{ .name = try a.dupe(u8, "zz_nonexistent_formula_xyz") };
    m.formulas = formulas;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    // offline keeps the unresolvable formula failing fast (no network), so the
    // test never races on connectivity and the HTTP/TLS layer never writes to the
    // global stderr we assert is empty — the source of the parallel-batch flake.
    const app: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty, .offline = true };
    var ictx: SilentInstallCtx = .{ .app = &app };
    const dispatcher = runner.Dispatcher{
        .ctx = &ictx,
        .installFormula = SilentInstallCtx.installFormulaFn,
        .installCask = SilentInstallCtx.unusedFn,
        .tapAdd = SilentInstallCtx.unusedFn,
        .serviceStart = SilentInstallCtx.unusedFn,
    };

    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(testing.allocator);
    output.beginStderrCapture(testing.allocator, &out_buf);
    defer output.endStderrCapture();

    var report = try runner.run(threaded.io(), testing.allocator, &t.db, m, .{
        .dry_run = false,
        .prefix = t.dir,
        .dispatcher = &dispatcher,
    });
    defer report.deinit();

    // Structured per-member outcome survives the silent sink...
    try testing.expect(report.hasFailure());
    try testing.expectEqual(@as(usize, 1), report.failures.len);
    try testing.expectEqual(runner.DispatchError.MemberFailed, report.failures[0].err);
    try testing.expectEqualStrings("zz_nonexistent_formula_xyz", report.failures[0].name);
    // ...while the per-keg lines never reach the global stderr channel.
    try testing.expectEqual(@as(usize, 0), out_buf.items.len);
}
