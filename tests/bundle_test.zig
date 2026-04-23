//! malt — bundle runner / CLI smoke tests
//!
//! `dry_run = true` lets us exercise the orchestration logic without forking
//! `malt install` for every member.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const sqlite = malt.sqlite;
const schema = malt.schema;
const manifest_mod = malt.bundle_manifest;
const runner = malt.bundle_runner;

const TempDb = struct {
    dir: []const u8,
    db: sqlite.Database,

    fn init(comptime tag: []const u8) !TempDb {
        const dir = "/tmp/malt_bundle_test_" ++ tag;
        malt.fs_compat.deleteTreeAbsolute(dir) catch {};
        try malt.fs_compat.makeDirAbsolute(dir);
        var db_path_buf: [256]u8 = undefined;
        const db_path = try std.fmt.bufPrint(&db_path_buf, "{s}/test.db", .{dir});
        var db = try sqlite.Database.open(db_path);
        errdefer db.close();
        try schema.initSchema(&db);
        return .{ .dir = dir, .db = db };
    }

    fn deinit(self: *TempDb) void {
        self.db.close();
        malt.fs_compat.deleteTreeAbsolute(self.dir) catch {};
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

    var report = try runner.run(testing.allocator, &t.db, m, .{ .dry_run = true, .prefix = t.dir });
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
    var report = try runner.run(testing.allocator, &t.db, m, .{
        .dry_run = false,
        .malt_bin = "/usr/bin/false",
        .prefix = t.dir,
    });
    defer report.deinit();
    try testing.expect(report.hasFailure());
    try testing.expectEqual(@as(usize, 4), report.failures.len);

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

    var report = try runner.run(testing.allocator, &t.db, m, .{
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

    fn tapAddFn(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
        const self = unwrap(ctx);
        try record(&self.taps, allocator, name);
    }
    fn installFormulaFn(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
        const self = unwrap(ctx);
        try record(&self.formulas, allocator, name);
    }
    fn installCaskFn(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
        const self = unwrap(ctx);
        try record(&self.casks, allocator, name);
    }
    fn serviceStartFn(ctx: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror!void {
        const self = unwrap(ctx);
        try record(&self.services, allocator, name);
    }
};

test "runner returns Report with per-member failures, not a bool" {
    // Pins the contract: the runner collects structured failures so the
    // CLI layer can render; core/* itself emits no UI.
    var t = try TempDb.init("report_failures");
    defer t.deinit();

    var m = try buildManifest(testing.allocator);
    defer m.deinit();

    var report = try runner.run(testing.allocator, &t.db, m, .{
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

    var report = try runner.run(testing.allocator, &t.db, m, .{
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

    var report = try runner.run(testing.allocator, &t.db, m, .{
        .dry_run = false,
        .prefix = t.dir,
    });
    defer report.deinit();
    try testing.expect(report.hasFailure());
    try testing.expectEqual(@as(usize, 4), report.failures.len);
    // Each member's err is RunnerError.NoDispatcher on this path.
    for (report.failures) |f| try testing.expectEqual(anyerror.NoDispatcher, f.err);

    var stmt = try t.db.prepare("SELECT COUNT(*) FROM bundles WHERE name='devtools';");
    defer stmt.finalize();
    _ = try stmt.step();
    // recordBundle still runs even on partial failure, matching the
    // existing `/usr/bin/false` test — this pins that invariant.
    try testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
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

    var report = try runner.run(testing.allocator, &t.db, m, .{ .dry_run = true, .prefix = t.dir });
    defer report.deinit();
}

test "bundle install honors the global --dry-run flag set by main.zig" {
    // Repro for T-034a: main.zig consumes `--dry-run` before it reaches
    // `cmdInstall`, so the local arm never fires and the runner ran with
    // `dry_run = false`. Pin the contract: when `output.isDryRun()` is true,
    // the runner must skip `recordBundle`, leaving the `bundles` table empty.
    const dir_z: [:0]const u8 = "/tmp/malt_bundle_dry_run_cli_wire";
    malt.fs_compat.deleteTreeAbsolute(dir_z) catch {};
    try malt.fs_compat.cwd().makePath(dir_z);
    defer malt.fs_compat.deleteTreeAbsolute(dir_z) catch {};

    _ = c.setenv("MALT_PREFIX", dir_z.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    // Empty-but-valid Brewfile: parser yields an empty manifest, so the
    // dispatcher is never called and the only observable side-effect is
    // the `recordBundle` insert — which dry-run must suppress.
    const bf_path = try std.fmt.allocPrint(testing.allocator, "{s}/Brewfile", .{dir_z});
    defer testing.allocator.free(bf_path);
    {
        const f = try malt.fs_compat.cwd().createFile(bf_path, .{});
        defer f.close();
        try f.writeAll("# empty\n");
    }

    malt.output.setDryRun(true);
    defer malt.output.setDryRun(false);

    try malt.cli_bundle.execute(testing.allocator, &.{ "install", bf_path });

    const db_path = try std.fmt.allocPrint(testing.allocator, "{s}/db/malt.db", .{dir_z});
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

    var report = try runner.run(testing.allocator, &t.db, m, .{ .dry_run = true, .prefix = t.dir });
    defer report.deinit();
}
