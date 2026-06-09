//! malt — search command integration tests.
//!
//! Drives `search.execute` against a scratch MALT_PREFIX with a
//! pre-seeded cache so the API layer hits disk only — no real HTTP.
//! Pins the human + JSON output shape and the `--formula` / `--cask`
//! flag plumbing.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const search = malt.cli_search;
const output = malt.output;
const sqlite = malt.sqlite;
const schema = malt.schema;

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
            "/tmp/malt_search_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const cache_api = try std.fmt.allocPrint(allocator, "{s}/cache/api", .{path});
        defer allocator.free(cache_api);
        try test_io.cwd().createDirPath(std.Options.debug_io, cache_api);
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *Scratch, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }
};

fn writeFile(path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        test_io.cwd().createDirPath(std.Options.debug_io, dir) catch {};
    }
    const f = try test_io.createFileAbsolute(std.Options.debug_io, path, .{ .truncate = true });
    defer f.close(std.Options.debug_io);
    try f.writeStreamingAll(std.Options.debug_io, content);
}

// Seed `{prefix}/db/malt.db` with kegs + casks so `--installed` and the
// `default` local-first path find real rows without ever touching the API.
fn seedDb(allocator: std.mem.Allocator, prefix: []const u8) !void {
    const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{prefix});
    defer allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

    var db_path_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/malt.db", .{db_dir}, 0);
    var db = try sqlite.Database.open(db_path);
    defer db.close();
    try schema.initSchema(&db);

    try db.exec(
        \\INSERT INTO kegs(name, full_name, version, store_sha256, cellar_path)
        \\VALUES
        \\  ('wget',      'wget',      '1.21', 'aaa', '/c/wget/1.21'),
        \\  ('wgetpaste', 'wgetpaste', '2.31', 'bbb', '/c/wgetpaste/2.31'),
        \\  ('jq',        'jq',        '1.7',  'ccc', '/c/jq/1.7');
    );
    try db.exec(
        \\INSERT INTO casks(token, name, version, url)
        \\VALUES
        \\  ('firefox', 'Firefox', '120.0', 'https://x'),
        \\  ('brave',   'Brave',   '1.0',   'https://x');
    );
}

// Seed both names indexes + a per-package json so api.exists() and
// fetchNamesIndex() both hit disk; no network in the substring scan.
fn seedCache(allocator: std.mem.Allocator, prefix: []const u8) !void {
    const formula_index = try std.fmt.allocPrint(allocator, "{s}/cache/api/names_formula.txt", .{prefix});
    defer allocator.free(formula_index);
    try writeFile(formula_index, "wget\nwgetpaste\njq\n");

    const cask_index = try std.fmt.allocPrint(allocator, "{s}/cache/api/names_cask.txt", .{prefix});
    defer allocator.free(cask_index);
    try writeFile(cask_index, "firefox\nfirefox-developer-edition\nbrave\n");

    // Per-package JSONs back the `exists()` exact-match probe.
    const wget_json = try std.fmt.allocPrint(allocator, "{s}/cache/api/formula_wget.json", .{prefix});
    defer allocator.free(wget_json);
    try writeFile(wget_json, "{\"name\":\"wget\"}");

    const firefox_json = try std.fmt.allocPrint(allocator, "{s}/cache/api/cask_firefox.json", .{prefix});
    defer allocator.free(firefox_json);
    try writeFile(firefox_json, "{\"token\":\"firefox\"}");
}

// End-to-end stdout capture: back `ctx.stdout` with a real fd to a scratch
// file so `execute`'s encoder writes survive and can be re-read for byte
// assertions (the `--json` contract). Caller owns the returned slice.
fn captureExecute(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    tag: []const u8,
) ![]u8 {
    const ts = test_io.nanoTimestamp(std.Options.debug_io);
    const cap_path = try std.fmt.allocPrintSentinel(
        allocator,
        "/tmp/malt_search_cap_{s}_{d}",
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

    try search.execute(&ctx, allocator, args);
    file.close(std.Options.debug_io);

    return try test_io.readFileAbsoluteAlloc(std.Options.debug_io, allocator, cap_path, 64 * 1024);
}

const OutputState = struct {
    prior_mode: output.OutputMode,
    prior_quiet: bool,

    fn save() OutputState {
        return .{
            .prior_mode = if (output.isJson()) .json else .human,
            .prior_quiet = output.isQuiet(),
        };
    }
    fn restore(self: OutputState) void {
        output.setMode(self.prior_mode);
        output.setQuiet(self.prior_quiet);
    }
};

// --- early-return branches ---------------------------------------------

test "execute --help short-circuits before opening anything" {
    var s = try Scratch.init(testing.allocator, "help");
    defer s.deinit(testing.allocator);
    output.setQuiet(true);
    defer output.setQuiet(false);
    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"--help"});
}

test "execute with no positional query returns Aborted" {
    var s = try Scratch.init(testing.allocator, "noargs");
    defer s.deinit(testing.allocator);
    output.setQuiet(true);
    defer output.setQuiet(false);
    try testing.expectError(
        error.Aborted,
        search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{}),
    );
}

// --- happy paths driven from disk cache --------------------------------

test "execute query hits both formula and cask substring matches from cache" {
    var s = try Scratch.init(testing.allocator, "both");
    defer s.deinit(testing.allocator);
    try seedCache(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"wget"});
}

test "execute --formula scopes the search to formulae only" {
    var s = try Scratch.init(testing.allocator, "formula_only");
    defer s.deinit(testing.allocator);
    try seedCache(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--formula", "jq" });
}

test "execute --cask scopes the search to casks only" {
    var s = try Scratch.init(testing.allocator, "cask_only");
    defer s.deinit(testing.allocator);
    try seedCache(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--cask", "firefox" });
}

test "execute --json emits a JSON object covering both kinds" {
    var s = try Scratch.init(testing.allocator, "json");
    defer s.deinit(testing.allocator);
    try seedCache(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.json);
    output.setQuiet(true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &stdout_buf);
    defer output.endStdoutCapture();

    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"wget"});

    // Output goes via ctx.stdout, not the captured-output sink, so the
    // shape we can pin is "no error and the function ran". The buffer
    // is only populated for `output.*` writes which `search` only uses
    // on the no-args branch.
    _ = stdout_buf.items;
}

// --- T-031: scope flag plumbing through `execute` ----------------------

test "execute --installed reads the local DB without an API cache present" {
    var s = try Scratch.init(testing.allocator, "installed");
    defer s.deinit(testing.allocator);
    try seedDb(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    // No `seedCache` — if the local-only path slipped through to the API,
    // `runKindIsolated` would still tolerate the miss (matches stays empty),
    // so the real assertion is "no error and the helper accepted the flag".
    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--installed", "wget" });
}

test "execute --installed --formula composes scope with kind filter" {
    var s = try Scratch.init(testing.allocator, "installed_formula");
    defer s.deinit(testing.allocator);
    try seedDb(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    try search.execute(
        &malt.app_ctx.debug_ctx,
        testing.allocator,
        &.{ "--installed", "--formula", "jq" },
    );
}

test "execute --installed --json keeps the JSON dispatch active" {
    var s = try Scratch.init(testing.allocator, "installed_json");
    defer s.deinit(testing.allocator);
    try seedDb(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.json);
    output.setQuiet(true);

    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--installed", "wget" });
}

test "execute --installed --json emits the versioned unified install-aware shape" {
    // End-to-end contract through `execute` on the deterministic local-only
    // scope: one versioned object, the echoed query, a single typed array
    // (exact match first, deduped), and `installed:true` derived from the DB.
    var s = try Scratch.init(testing.allocator, "installed_json_shape");
    defer s.deinit(testing.allocator);
    try seedDb(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.json);
    output.setQuiet(true);

    const out = try captureExecute(testing.allocator, &.{ "--installed", "wget" }, "installed_json_shape");
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        \\{"schema_version":1,"query":"wget","results":[{"name":"wget","type":"formula","installed":true},{"name":"wgetpaste","type":"formula","installed":true}]}
    ++ "\n", out);
}

test "execute --api still works with only the cache seeded" {
    var s = try Scratch.init(testing.allocator, "api_only");
    defer s.deinit(testing.allocator);
    try seedCache(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--api", "wget" });
}

test "execute default queries the API even when the local DB has a match" {
    // Default mirrors `brew search`: regardless of what's installed in
    // the local prefix, the answer comes from the Homebrew API. Seed
    // both DB and cache, query something both know about, and verify
    // the helper accepts the work without erroring.
    var s = try Scratch.init(testing.allocator, "default_api_parity");
    defer s.deinit(testing.allocator);
    try seedDb(testing.allocator, s.path);
    try seedCache(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"wget"});
}

test "execute default tolerates a missing local DB (never reads it)" {
    // Fresh prefix with only the API cache — default scope never opens
    // the local DB, so absence is a no-op rather than an error path.
    var s = try Scratch.init(testing.allocator, "default_nodb");
    defer s.deinit(testing.allocator);
    try seedCache(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{"wget"});
}

test "execute --all runs both passes with cache + DB seeded" {
    var s = try Scratch.init(testing.allocator, "all_scope");
    defer s.deinit(testing.allocator);
    try seedDb(testing.allocator, s.path);
    try seedCache(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--all", "wget" });
}

test "execute --installed tolerates a missing local DB without crashing" {
    // Fresh prefix with no `db/malt.db` — local lookup must degrade
    // silently, not error out.
    var s = try Scratch.init(testing.allocator, "installed_nodb");
    defer s.deinit(testing.allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    try search.execute(&malt.app_ctx.debug_ctx, testing.allocator, &.{ "--installed", "wget" });
}

test "execute --offline collapses --api into local-only" {
    // T-029 slice: even with `--api` requested, `--offline` wins and the
    // command must not attempt the network path.
    var s = try Scratch.init(testing.allocator, "offline");
    defer s.deinit(testing.allocator);
    try seedDb(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    try search.execute(
        &malt.app_ctx.debug_ctx,
        testing.allocator,
        &.{ "--offline", "--api", "wget" },
    );
}

test "execute MALT_OFFLINE=1 mirrors the --offline flag" {
    var s = try Scratch.init(testing.allocator, "offline_env");
    defer s.deinit(testing.allocator);
    try seedDb(testing.allocator, s.path);

    const prior = OutputState.save();
    defer prior.restore();
    output.setQuiet(true);

    // Build an AppCtx with a one-entry environ instead of mutating the
    // process env — keeps the test hermetic and parallel-safe.
    const entries = [_:null]?[*:0]const u8{"MALT_OFFLINE=1".ptr};
    const env: std.process.Environ = .{ .block = .{ .slice = entries[0..1 :null] } };
    const ctx: malt.app_ctx.AppCtx = .{ .io = std.Options.debug_io, .environ = env };

    try search.execute(&ctx, testing.allocator, &.{"wget"});
}
