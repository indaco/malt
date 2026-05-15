//! malt — info command end-to-end tests.
//!
//! Drives `info.execute` against a scratch MALT_PREFIX with seeded
//! kegs/casks rows so the installed-formula and installed-cask emit
//! paths land on the coverage map. The pure encoder helpers are
//! already covered by `tests/info_test.zig`; this file fills the
//! `execute` dispatch branches.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const info = malt.cli_info;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const Scratch = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !Scratch {
        const ts = test_io.nanoTimestamp(std.Options.debug_io);
        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "/tmp/malt_info_exec_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const subs = [_][]const u8{ "db", "Cellar", "Caskroom", "cache/api" };
        for (subs) |s| {
            const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, s });
            defer allocator.free(dir);
            try test_io.cwd().createDirPath(std.Options.debug_io, dir);
        }
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }
};

fn quiet() void {
    output.setQuiet(true);
}
fn unquiet() void {
    output.setQuiet(false);
}

fn seedFormulaKeg(allocator: std.mem.Allocator, prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    const cellar = try std.fmt.allocPrint(allocator, "{s}/Cellar/wget/1.21", .{prefix});
    defer allocator.free(cellar);
    try test_io.cwd().createDirPath(std.Options.debug_io, cellar);

    var stmt = try db.prepare(
        \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, tap)
        \\VALUES ('wget', 'wget', '1.21', 0, '', ?1, 'homebrew/core');
    );
    defer stmt.finalize();
    try stmt.bindText(1, cellar);
    _ = try stmt.step();
}

fn seedCaskRow(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    var stmt = try db.prepare(
        \\INSERT INTO casks (token, name, version, url, sha256, app_path)
        \\VALUES ('firefox', 'Firefox', '120.0', 'https://example/firefox.dmg', 'aa', '/Applications/Firefox.app');
    );
    defer stmt.finalize();
    _ = try stmt.step();
}

fn seedTapCaskRow(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    var stmt = try db.prepare(
        \\INSERT INTO casks (token, name, version, url, sha256, app_path, tap)
        \\VALUES ('deckclip', 'deckclip', '1.4.5', 'https://example/deckclip.dmg', 'bb', '/Applications/Deck.app', 'yuzeguitarist/deck');
    );
    defer stmt.finalize();
    _ = try stmt.step();
}

/// End-to-end stdout capture. Backs `ctx.stdout` with a real fd to a
/// scratch file so the encoder's writes survive past `execute` and can
/// be re-read for assertions. Caller owns the returned slice.
fn captureExecute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    tag: []const u8,
) ![]u8 {
    const ts = test_io.nanoTimestamp(std.Options.debug_io);
    const cap_path = try std.fmt.allocPrintSentinel(
        allocator,
        "/tmp/malt_info_cap_{s}_{d}",
        .{ tag, ts },
        0,
    );
    defer allocator.free(cap_path);
    defer test_io.deleteFileAbsolute(std.Options.debug_io, cap_path) catch {};

    var file = try test_io.createFileAbsolute(std.Options.debug_io, cap_path, .{ .truncate = true });
    errdefer file.close(std.Options.debug_io);

    const ctx: malt.app_ctx.AppCtx = .{
        .io = std.Options.debug_io,
        .environ = .empty,
        .stdout = file,
        .stderr = test_io.testSink(),
    };

    try info.execute(&ctx, allocator, args);
    file.close(std.Options.debug_io);

    return try test_io.readFileAbsoluteAlloc(std.Options.debug_io, allocator, cap_path, 64 * 1024);
}

// --- early-return + arg parsing ---------------------------------------

test "execute --help short-circuits without touching the database" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try info.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute with no positional package returns Aborted" {
    var s = try Scratch.init(testing.allocator, "noargs");
    defer s.deinit(testing.allocator);
    quiet();
    defer unquiet();
    try testing.expectError(
        error.Aborted,
        info.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

// --- installed formula path -------------------------------------------

test "execute prints info for a locally-installed formula" {
    var s = try Scratch.init(testing.allocator, "wget");
    defer s.deinit(testing.allocator);
    try seedFormulaKeg(testing.allocator, s.path);

    quiet();
    defer unquiet();

    try info.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"wget"});
}

test "execute prints JSON info for a locally-installed formula" {
    var s = try Scratch.init(testing.allocator, "wget_json");
    defer s.deinit(testing.allocator);
    try seedFormulaKeg(testing.allocator, s.path);

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    quiet();
    defer {
        unquiet();
        output.setMode(prior_mode);
    }

    try info.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"wget"});
}

// --- installed cask path ----------------------------------------------

test "execute prints info for a locally-installed cask" {
    var s = try Scratch.init(testing.allocator, "ff");
    defer s.deinit(testing.allocator);
    try seedCaskRow(s.path);

    quiet();
    defer unquiet();

    try info.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"firefox"});
}

test "execute --cask only inspects the casks table" {
    // With a formula keg also present, --cask must skip it and find
    // the cask row (or fall through to API metadata, also fine).
    var s = try Scratch.init(testing.allocator, "force_cask");
    defer s.deinit(testing.allocator);
    try seedFormulaKeg(testing.allocator, s.path);
    try seedCaskRow(s.path);

    quiet();
    defer unquiet();

    try info.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--cask", "firefox" });
}

test "execute --formula only inspects the kegs table" {
    var s = try Scratch.init(testing.allocator, "force_formula");
    defer s.deinit(testing.allocator);
    try seedFormulaKeg(testing.allocator, s.path);
    try seedCaskRow(s.path);

    quiet();
    defer unquiet();

    try info.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--formula", "wget" });
}

// --- not-installed path -----------------------------------------------

test "execute on a missing package without API cache prints not-installed" {
    // No kegs, no cache → emitApiMetadata fails for both kinds, then
    // emitNotFound runs.
    var s = try Scratch.init(testing.allocator, "missing");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    quiet();
    defer unquiet();

    try info.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"definitely-not-a-real-package"});
}

test "execute on a missing package with --json emits a not-installed JSON object" {
    var s = try Scratch.init(testing.allocator, "missing_json");
    defer s.deinit(testing.allocator);

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    quiet();
    defer {
        unquiet();
        output.setMode(prior_mode);
    }

    try info.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"ghost-pkg"});
}

// --- API-cache fallback path -------------------------------------------

test "execute falls back to cached API formula metadata for a not-locally-installed name" {
    // No DB row for the package, but a fresh `formula_<name>.json` in
    // cache/ — emitApiFormula reads it from disk.
    var s = try Scratch.init(testing.allocator, "api_cached");
    defer s.deinit(testing.allocator);
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{s.path}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
    }

    const cache_path = try std.fmt.allocPrint(testing.allocator, "{s}/cache/api/formula_jq.json", .{s.path});
    defer testing.allocator.free(cache_path);
    const f = try test_io.createFileAbsolute(std.Options.debug_io, cache_path, .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io,
        \\{"name":"jq","full_name":"jq","tap":"homebrew/core","desc":"JSON CLI","homepage":"https://example",
        \\ "versions":{"stable":"1.7"},"revision":0,"dependencies":[],"oldnames":[],
        \\ "keg_only":false,"post_install_defined":false,
        \\ "bottle":{"stable":{"root_url":"https://example","files":{}}}
        \\}
    );

    quiet();
    defer unquiet();

    try info.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"jq"});
}

// --- end-to-end stdout capture: tap surfacing -------------------------
//
// WHY a separate block: the tests above prove `execute` doesn't crash on
// the cask path, but `debug_ctx.stdout = -1` means they assert nothing
// about the bytes. These tests back stdout with a real file so the full
// DB → SELECT → readInstalledCaskRow → encoder → writer chain is
// observable — catching column-index regressions, SELECT shape drift,
// and tap-surfacing bugs that the pure encoder tests cannot see.

test "execute on a tap-cask emits a Tap: line at the bottom of the human dump" {
    var s = try Scratch.init(testing.allocator, "tap_cask_human");
    defer s.deinit(testing.allocator);
    try seedTapCaskRow(s.path);

    const out = try captureExecute(testing.allocator, &.{"deckclip"}, "tap_cask_human");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "deckclip: 1.4.5 (cask)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Tap:          yuzeguitarist/deck") != null);
    const installed_idx = std.mem.indexOf(u8, out, "Installed:") orelse return error.NoInstalledLine;
    const tap_idx = std.mem.indexOf(u8, out, "Tap:") orelse return error.NoTapLine;
    try testing.expect(installed_idx < tap_idx);
}

test "execute on a NULL-tap cask omits the Tap: line entirely" {
    var s = try Scratch.init(testing.allocator, "null_tap_human");
    defer s.deinit(testing.allocator);
    try seedCaskRow(s.path);

    const out = try captureExecute(testing.allocator, &.{"firefox"}, "null_tap_human");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "firefox: 120.0 (cask)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Tap:") == null);
}

test "execute --json on a tap-cask exposes the tap field" {
    var s = try Scratch.init(testing.allocator, "tap_cask_json");
    defer s.deinit(testing.allocator);
    try seedTapCaskRow(s.path);

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    defer output.setMode(prior_mode);

    const out = try captureExecute(testing.allocator, &.{"deckclip"}, "tap_cask_json");
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const tap_val = parsed.value.object.get("tap") orelse return error.MissingTapKey;
    try testing.expectEqualStrings("yuzeguitarist/deck", tap_val.string);
}

test "execute --json on a NULL-tap cask still emits tap as an empty string" {
    var s = try Scratch.init(testing.allocator, "null_tap_json");
    defer s.deinit(testing.allocator);
    try seedCaskRow(s.path);

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    defer output.setMode(prior_mode);

    const out = try captureExecute(testing.allocator, &.{"firefox"}, "null_tap_json");
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const tap_val = parsed.value.object.get("tap") orelse return error.MissingTapKey;
    try testing.expectEqualStrings("", tap_val.string);
}

// --- retained rollback history under `mt info` -------------------------
//
// WHY end-to-end: the pure encoder tests cover the bytes, but only an
// `execute` capture exercises the SQL SELECTs, the store walker, and
// the skip_pkg_version wiring. Regressing those silently is the failure
// mode that bit T-037 — pinning here keeps both halves honest.

/// Seed `<prefix>/store/<sha>/<name>/<pkg_version>/INSTALL_RECEIPT.json`
/// so `rollback.collectEntries` sees a real retained version for `name`.
fn seedStoreVersion(prefix: []const u8, sha: []const u8, name: []const u8, pkg_version: []const u8) !void {
    var buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "{s}/store/{s}/{s}/{s}", .{ prefix, sha, name, pkg_version });
    try test_io.cwd().createDirPath(std.Options.debug_io, dir);

    var f_buf: [600]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&f_buf, "{s}/INSTALL_RECEIPT.json", .{dir});
    const f = try test_io.createFileAbsolute(std.Options.debug_io, file_path, .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, "{}");
}

fn seedCaskVersionsHistory(prefix: []const u8) !void {
    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{prefix}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO cask_versions (token, version, url, sha256, installed_at)
        \\VALUES ('flux-markdown', '1.30.0', 'https://x/a.dmg', 'aa', '2026-01-01T00:00:00'),
        \\       ('flux-markdown', '1.31.0', 'https://x/b.dmg', 'bb', '2026-02-01T00:00:00');
    );
    try db.exec(
        \\INSERT INTO casks (token, name, version, url, sha256, app_path)
        \\VALUES ('flux-markdown', 'flux-markdown', '1.32.0', 'https://x/c.dmg', 'cc', '/Applications/Flux.app');
    );
}

test "execute on a formula with retained store versions appends the rollback section" {
    var s = try Scratch.init(testing.allocator, "fmla_hist_human");
    defer s.deinit(testing.allocator);
    try seedFormulaKeg(testing.allocator, s.path);
    // Two prior versions in the store; current (1.21) excluded by the
    // skip_pkg_version handoff so it doesn't appear in its own listing.
    try seedStoreVersion(s.path, "sha_old", "wget", "1.19");
    try seedStoreVersion(s.path, "sha_mid", "wget", "1.20");

    const out = try captureExecute(testing.allocator, &.{"wget"}, "fmla_hist_human");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Available rollback versions for wget") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.19") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.20") != null);
    // Current version must be filtered out of its own listing.
    const section_idx = std.mem.indexOf(u8, out, "Available rollback versions").?;
    try testing.expect(std.mem.indexOf(u8, out[section_idx..], "1.21") == null);
}

test "execute --json on a formula with retained store versions populates available_rollback_versions" {
    var s = try Scratch.init(testing.allocator, "fmla_hist_json");
    defer s.deinit(testing.allocator);
    try seedFormulaKeg(testing.allocator, s.path);
    try seedStoreVersion(s.path, "sha_old", "wget", "1.19");

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    defer output.setMode(prior_mode);

    const out = try captureExecute(testing.allocator, &.{"wget"}, "fmla_hist_json");
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const arr = parsed.value.object.get("available_rollback_versions") orelse return error.MissingKey;
    try testing.expectEqual(@as(usize, 1), arr.array.items.len);
    try testing.expectEqualStrings("1.19", arr.array.items[0].object.get("version").?.string);
}

test "execute --json on a formula with no retained versions emits available_rollback_versions:[]" {
    var s = try Scratch.init(testing.allocator, "fmla_empty_json");
    defer s.deinit(testing.allocator);
    try seedFormulaKeg(testing.allocator, s.path);

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    defer output.setMode(prior_mode);

    const out = try captureExecute(testing.allocator, &.{"wget"}, "fmla_empty_json");
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const arr = parsed.value.object.get("available_rollback_versions") orelse return error.MissingKey;
    try testing.expectEqual(@as(usize, 0), arr.array.items.len);
}

test "execute on a formula with no retained versions omits the section in human output" {
    var s = try Scratch.init(testing.allocator, "fmla_empty_human");
    defer s.deinit(testing.allocator);
    try seedFormulaKeg(testing.allocator, s.path);

    const out = try captureExecute(testing.allocator, &.{"wget"}, "fmla_empty_human");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Available rollback versions") == null);
    // Existing field block stays byte-identical for the empty-history case.
    try testing.expect(std.mem.indexOf(u8, out, "wget: stable 1.21\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "From:      homebrew/core\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Installed:") != null);
}

test "execute on a cask with retained cask_versions rows appends the rollback section" {
    var s = try Scratch.init(testing.allocator, "cask_hist_human");
    defer s.deinit(testing.allocator);
    try seedCaskVersionsHistory(s.path);

    const out = try captureExecute(testing.allocator, &.{"flux-markdown"}, "cask_hist_human");
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "Available rollback versions for flux-markdown") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.31.0") != null);
    try testing.expect(std.mem.indexOf(u8, out, "1.30.0") != null);
    // Current cask version must not appear in its own rollback listing.
    const section_idx = std.mem.indexOf(u8, out, "Available rollback versions").?;
    try testing.expect(std.mem.indexOf(u8, out[section_idx..], "1.32.0") == null);
}

test "execute --json on a cask with history populates available_rollback_versions" {
    var s = try Scratch.init(testing.allocator, "cask_hist_json");
    defer s.deinit(testing.allocator);
    try seedCaskVersionsHistory(s.path);

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    defer output.setMode(prior_mode);

    const out = try captureExecute(testing.allocator, &.{"flux-markdown"}, "cask_hist_json");
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const arr = parsed.value.object.get("available_rollback_versions") orelse return error.MissingKey;
    try testing.expectEqual(@as(usize, 2), arr.array.items.len);
    // Newest-first ordering matches `mt rollback --list` exactly.
    try testing.expectEqualStrings("1.31.0", arr.array.items[0].object.get("version").?.string);
    try testing.expectEqualStrings("1.30.0", arr.array.items[1].object.get("version").?.string);
}

test "execute --json on a cask with no history emits available_rollback_versions:[]" {
    var s = try Scratch.init(testing.allocator, "cask_empty_json");
    defer s.deinit(testing.allocator);
    try seedCaskRow(s.path);

    const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
    output.setMode(.json);
    defer output.setMode(prior_mode);

    const out = try captureExecute(testing.allocator, &.{"firefox"}, "cask_empty_json");
    defer testing.allocator.free(out);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out, .{});
    defer parsed.deinit();

    const arr = parsed.value.object.get("available_rollback_versions") orelse return error.MissingKey;
    try testing.expectEqual(@as(usize, 0), arr.array.items.len);
}
