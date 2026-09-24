//! malt — `mt vulns` integration tests.
//!
//! Drives `execute` against a scratch prefix and a loopback fixture mirror:
//! `abcde` (copied from the live API, eight open advisories) and a clean
//! `curl`. Pins the human rows, the `--json` shape, the exit code, and that
//! a second run inside the cache TTL performs no request at all. The same
//! fixture answers as a tap's raw host and as OSV, so a tap keg's recipe ->
//! source url -> advisory walk runs without leaving the loopback.

const std = @import("std");
const testing = std.testing;
const net = std.Io.net;

const malt = @import("malt");
const test_io = @import("test_io");
const vulns = malt.cli_vulns;
const sqlite = malt.sqlite;
const schema = malt.schema;
const output = malt.output;

const c = test_io.c;

const abcde_json = @embedFile("fixtures/vulns/abcde.json");
const curl_json = @embedFile("fixtures/vulns/curl.json");

/// The commit every seeded tap keg claims to be installed from; the raw
/// route below only answers at this sha.
const tap_sha = "0123456789abcdef0123456789abcdef01234567";

/// A goreleaser-shaped tap recipe: mixed-case owner in the asset url, so
/// the identifier must lowercase the repo and take the tag from the url.
const cliamp_rb =
    \\class Cliamp < Formula
    \\  desc "Terminal audio player"
    \\  homepage "https://github.com/bjarneo/cliamp"
    \\  version "2.2.0"
    \\  url "https://github.com/Bjarneo/cliamp/releases/download/v2.2.0/cliamp_Darwin_arm64.tar.gz"
    \\  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    \\end
;

/// A tap recipe that opts out of checksum verification. Scanning needs only
/// its url and version, so the missing digest does not matter here.
const nocheck_rb =
    \\class Nocheck < Formula
    \\  version "1.0"
    \\  url "https://github.com/someone/nocheck/releases/download/v1.0/nocheck.tar.gz"
    \\  sha256 :no_check
    \\end
;

/// The usual companion of `:no_check`; no release to ask OSV about.
const nocheck_latest_rb =
    \\class Nolatest < Formula
    \\  version :latest
    \\  url "https://github.com/someone/nolatest/releases/latest/download/nolatest.tar.gz"
    \\  sha256 :no_check
    \\end
;

/// A tap shipping a formula and a cask under one name, each built from a
/// different repo, so the OSV query shows which recipe was read.
const dual_formula_rb =
    \\class Dual < Formula
    \\  version "1.0.0"
    \\  url "https://github.com/formula-side/dual/releases/download/v1.0.0/dual.tar.gz"
    \\  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    \\end
;
const dual_cask_rb =
    \\cask "dual" do
    \\  version "1.0.0"
    \\  url "https://github.com/cask-side/dual/releases/download/v1.0.0/dual.tar.gz"
    \\  sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    \\end
;

/// One OSV hit for the recipe above. The CVSS vector scores 9.8 while the
/// database label says HIGH, so the row proves the vector wins.
const osv_batch_json =
    \\{"results":[{"vulns":[{"id":"GHSA-aaaa-bbbb-cccc","modified":"2026-01-01T00:00:00Z"}]}]}
;
const osv_vuln_json =
    \\{"id":"GHSA-aaaa-bbbb-cccc","summary":"Path traversal in playlist loader",
    \\ "severity":[{"type":"CVSS_V3","score":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}],
    \\ "database_specific":{"severity":"HIGH"}}
;

/// Serves `/formula/<name>.json` from the two fixtures, 404 otherwise, and
/// counts every request so a test can prove the cache absorbed a run.
const FixtureServer = struct {
    io: std.Io,
    listener: *net.Server,
    count: std.atomic.Value(u32) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    /// Hold every request until this many are open at once (or a 2 s cap
    /// elapses), so overlap is observed by rendezvous rather than by timing.
    rendezvous: u32 = 0,
    in_flight: std.atomic.Value(u32) = .init(0),
    peak_in_flight: std.atomic.Value(u32) = .init(0),
    /// The last `/querybatch` body, so a test can pin what was asked of OSV.
    post_body: [4096]u8 = undefined,
    post_len: std.atomic.Value(usize) = .init(0),
    /// What `/querybatch` answers; tests swap in outages and wider batches.
    batch_body: []const u8 = osv_batch_json,

    fn serve(self: *FixtureServer) void {
        var handlers: std.ArrayList(std.Thread) = .empty;
        defer {
            for (handlers.items) |t| t.join();
            handlers.deinit(std.heap.smp_allocator);
        }
        while (true) {
            const stream = self.listener.accept(self.io) catch return;
            if (self.stop.load(.acquire)) {
                stream.close(self.io);
                return;
            }
            // One thread per connection so concurrent clients really overlap.
            const t = std.Thread.spawn(.{}, handle, .{ self, stream }) catch {
                stream.close(self.io);
                return;
            };
            handlers.append(std.heap.smp_allocator, t) catch {
                t.join();
                return;
            };
        }
    }

    fn handle(self: *FixtureServer, stream: net.Stream) void {
        defer stream.close(self.io);
        var rbuf: [16 * 1024]u8 = undefined;
        var wbuf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &rbuf);
        var writer = stream.writer(self.io, &wbuf);
        var srv = std.http.Server.init(&reader.interface, &writer.interface);
        // Keep-alive like a real peer, so a pooled client's second request
        // is not a dead-connection retry.
        while (true) self.handleOne(&srv) catch return;
    }

    fn handleOne(self: *FixtureServer, srv: *std.http.Server) !void {
        var req = try srv.receiveHead();
        _ = self.count.fetchAdd(1, .monotonic);
        const now = self.in_flight.fetchAdd(1, .acq_rel) + 1;
        defer _ = self.in_flight.fetchSub(1, .acq_rel);
        _ = self.peak_in_flight.fetchMax(now, .acq_rel);
        if (self.rendezvous > 0) {
            const started = test_io.milliTimestamp(self.io);
            while (self.in_flight.load(.acquire) < self.rendezvous and
                test_io.milliTimestamp(self.io) - started < 2000)
            {
                test_io.sleepNanos(self.io, 5 * std.time.ns_per_ms);
            }
        }
        const target = req.head.target;
        if (std.mem.eql(u8, target, "/querybatch")) {
            var body_buf: [4096]u8 = undefined;
            const body = req.readerExpectNone(&body_buf);
            const n = body.readSliceShort(&self.post_body) catch 0;
            self.post_len.store(n, .release);
            try req.respond(self.batch_body, .{});
        } else if (std.mem.eql(u8, target, "/vulns/GHSA-aaaa-bbbb-cccc")) {
            try req.respond(osv_vuln_json, .{});
        } else if (std.mem.startsWith(u8, target, "/vulns/")) {
            // Every other id is a real but low advisory, so filters and the
            // detail cap can be told apart from "OSV knows nothing".
            var body: [256]u8 = undefined;
            const json = try std.fmt.bufPrint(&body, "{{\"id\":\"{s}\",\"database_specific\":{{\"severity\":\"LOW\"}}}}", .{target["/vulns/".len..]});
            try req.respond(json, .{});
        } else if (std.mem.eql(u8, target, "/" ++ tap_sha ++ "/Formula/cliamp.rb") or
            std.mem.eql(u8, target, "/" ++ tap_sha ++ "/Formula/cliamp2.rb"))
        {
            try req.respond(cliamp_rb, .{});
        } else if (std.mem.eql(u8, target, "/" ++ tap_sha ++ "/Formula/dual.rb")) {
            try req.respond(dual_formula_rb, .{});
        } else if (std.mem.eql(u8, target, "/" ++ tap_sha ++ "/Casks/dual.rb")) {
            try req.respond(dual_cask_rb, .{});
        } else if (std.mem.eql(u8, target, "/" ++ tap_sha ++ "/Formula/nocheck.rb")) {
            try req.respond(nocheck_rb, .{});
        } else if (std.mem.eql(u8, target, "/" ++ tap_sha ++ "/Formula/nolatest.rb")) {
            try req.respond(nocheck_latest_rb, .{});
        } else if (std.mem.eql(u8, target, "/commits/HEAD")) {
            // What a forge answers for the tap's HEAD; kegs recorded before
            // the installed commit was tracked resolve through here.
            try req.respond("{\"sha\":\"" ++ tap_sha ++ "\"}", .{});
        } else if (std.mem.eql(u8, target, "/formula/abcde.json")) {
            try req.respond(abcde_json, .{});
        } else if (std.mem.eql(u8, target, "/formula/curl.json")) {
            try req.respond(curl_json, .{});
        } else if (std.mem.startsWith(u8, target, "/formula/f")) {
            // Synthetic clean formulae f0..fN for fan-out tests; the body's
            // own name is never read, so the clean fixture serves them all.
            try req.respond(curl_json, .{});
        } else {
            try req.respond("", .{ .status = .not_found });
        }
    }

    fn shutdown(self: *FixtureServer, thread: std.Thread) void {
        self.stop.store(true, .release);
        if (self.listener.socket.address.connect(self.io, .{ .mode = .stream })) |waker| {
            waker.close(self.io);
        } else |_| {}
        thread.join();
        self.listener.deinit(self.io);
    }
};

const Harness = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    prefix: [:0]u8,
    listener: net.Server,
    server: FixtureServer,
    thread: std.Thread,
    base_url: [64]u8,
    base_len: usize,
    run_seq: u32 = 0,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !*Harness {
        const h = try allocator.create(Harness);
        errdefer allocator.destroy(h);
        h.* = .{
            .allocator = allocator,
            .threaded = .init(allocator, .{}),
            .prefix = undefined,
            .listener = undefined,
            .server = undefined,
            .thread = undefined,
            .base_url = undefined,
            .base_len = 0,
        };
        const io = h.threaded.io();

        const base = try test_io.uniqueTempPath(allocator, "vulns_cli", tag);
        defer allocator.free(base);
        h.prefix = try allocator.dupeZ(u8, base);
        test_io.deleteTreeAbsolute(io, h.prefix) catch {};
        for ([_][]const u8{ "db", "cache" }) |sub| {
            const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ h.prefix, sub });
            defer allocator.free(dir);
            try test_io.cwd().createDirPath(io, dir);
        }
        _ = c.setenv("MALT_PREFIX", h.prefix.ptr, 1);

        var addr = try net.IpAddress.parseIp4("127.0.0.1", 0);
        h.listener = try addr.listen(io, .{ .reuse_address = true });
        const port = h.listener.socket.address.getPort();
        h.base_len = (try std.fmt.bufPrint(&h.base_url, "http://127.0.0.1:{d}", .{port})).len;
        h.server = .{ .io = io, .listener = &h.listener };
        h.thread = try std.Thread.spawn(.{}, FixtureServer.serve, .{&h.server});
        return h;
    }

    fn deinit(h: *Harness) void {
        const io = h.threaded.io();
        h.server.shutdown(h.thread);
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(io, h.prefix) catch {};
        h.allocator.free(h.prefix);
        h.threaded.deinit();
        h.allocator.destroy(h);
    }

    /// Seed installed kegs as `name@version` or `name@version_rev`,
    /// attributed to `tap` (empty reads as homebrew/core) at `tap_sha`, so
    /// no HEAD resolve is ever needed to find their recipe.
    fn seedTap(h: *Harness, tap: []const u8, kegs: []const []const u8) !void {
        return h.seedTapAt(tap, tap_sha, kegs);
    }

    /// `sha` null seeds the row the way a pre-tracking install left it.
    fn seedTapAt(h: *Harness, tap: []const u8, sha: ?[]const u8, kegs: []const []const u8) !void {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{h.prefix}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        for (kegs) |spec| {
            const at = std.mem.indexOfScalar(u8, spec, '@').?;
            const pkg = malt.formula.parsePkgVersion(spec[at + 1 ..]);
            var stmt = try db.prepare(
                \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, tap, tap_commit_sha)
                \\VALUES (?1, ?1, ?2, ?3, '', '/c/x', ?4, ?5);
            );
            defer stmt.finalize();
            try stmt.bindText(1, spec[0..at]);
            try stmt.bindText(2, pkg.version);
            try stmt.bindInt(3, pkg.revision);
            try stmt.bindText(4, tap);
            if (sha) |commit| try stmt.bindText(5, commit) else try stmt.bindNull(5);
            _ = try stmt.step();
        }
    }

    fn seed(h: *Harness, kegs: []const []const u8) !void {
        return h.seedTap("homebrew/core", kegs);
    }

    const Run = struct {
        stdout: []u8,
        err: ?anyerror,
    };

    /// Run `execute` with stdout captured; returns the bytes and the error.
    fn run(h: *Harness, args: []const []const u8, json: bool) !Run {
        return h.runWith(args, json, false);
    }

    fn runWith(h: *Harness, args: []const []const u8, json: bool, offline: bool) !Run {
        const io = h.threaded.io();
        h.run_seq += 1;
        var cap_buf: [512]u8 = undefined;
        const cap_path = try std.fmt.bufPrint(&cap_buf, "{s}/stdout.{d}", .{ h.prefix, h.run_seq });
        const cap = try test_io.cwd().createFile(io, cap_path, .{});
        defer cap.close(io);

        const ctx: malt.app_ctx.AppCtx = .{
            .io = io,
            .environ = .empty,
            .stdout = cap,
            .stderr = test_io.testSink(),
            .mirrors = .{ .api_base = h.base_url[0..h.base_len] },
            .offline = offline,
        };
        const prior_mode: output.OutputMode = if (output.isJson()) .json else .human;
        output.setMode(if (json) .json else .human);
        output.setQuiet(true);
        defer {
            output.setMode(prior_mode);
            output.setQuiet(false);
        }
        // The one fixture plays the API mirror, every tap's raw host, and OSV.
        const base = h.base_url[0..h.base_len];
        const sources: vulns.Sources = .{ .osv_base = base, .forge_base = base };
        const err: ?anyerror = if (vulns.executeWith(&ctx, h.allocator, args, sources)) null else |e| e;
        const bytes = try test_io.cwd().readFileAlloc(io, cap_path, h.allocator, .unlimited);
        return .{ .stdout = bytes, .err = err };
    }

    fn requests(h: *Harness) u32 {
        return h.server.count.load(.monotonic);
    }

    fn postBody(h: *Harness) []const u8 {
        return h.server.post_body[0..h.server.post_len.load(.acquire)];
    }
};

fn countLines(s: []const u8) usize {
    return std.mem.count(u8, s, "\n");
}

test "vulns lists every open advisory for installed formulae, most severe first, and exits 1" {
    const h = try Harness.init(testing.allocator, "human");
    defer h.deinit();
    try h.seed(&.{ "abcde@2.9.2", "curl@8.16.0" });

    const r = try h.run(&.{}, false);
    defer testing.allocator.free(r.stdout);

    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);
    try testing.expectEqual(@as(usize, 8), countLines(r.stdout));
    // The single critical advisory leads; the two unlabelled ones close.
    // Columns: name, severity (`-` when unlabelled), id, optional summary.
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    try testing.expectEqualStrings(
        "abcde  critical  BREW-abcde-CVE-2026-15747              Mojolicious versions from 4.59 before 9.48 for Perl expose a stable representation of the session CSRF token to a BREACH compression oracle",
        lines.next().?,
    );
    try testing.expectEqualStrings("abcde  high      BREW-abcde-CVE-2020-36829", lines.next().?);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "curl") == null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "abcde  -         BREW-abcde-CPANSA-Mojolicious-2021-02  Small sessions") != null);
    const last_two = "BREW-abcde-CPANSA-Mojolicious-2021-02";
    const last_pos = std.mem.indexOf(u8, r.stdout, last_two).?;
    const critical_pos = std.mem.indexOf(u8, r.stdout, "BREW-abcde-CVE-2026-15747").?;
    try testing.expect(critical_pos < last_pos);
}

test "vulns on a clean formula prints nothing and exits 0" {
    const h = try Harness.init(testing.allocator, "clean");
    defer h.deinit();
    try h.seed(&.{ "abcde@2.9.2", "curl@8.16.0" });

    const r = try h.run(&.{"curl"}, false);
    defer testing.allocator.free(r.stdout);

    try testing.expect(r.err == null);
    try testing.expectEqualStrings("", r.stdout);
}

test "vulns --severity=high drops medium and unlabelled advisories" {
    const h = try Harness.init(testing.allocator, "severity");
    defer h.deinit();
    try h.seed(&.{"abcde@2.9.2"});

    const r = try h.run(&.{"--severity=high"}, false);
    defer testing.allocator.free(r.stdout);

    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);
    try testing.expectEqual(@as(usize, 3), countLines(r.stdout));
    try testing.expect(std.mem.indexOf(u8, r.stdout, "medium") == null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "CPANSA") == null);
}

test "vulns --json carries the schema, the installed version, and every open advisory" {
    const h = try Harness.init(testing.allocator, "json");
    defer h.deinit();
    try h.seed(&.{ "abcde@2.9.2", "curl@8.16.0" });

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 1), root.get("schema_version").?.integer);
    try testing.expectEqual(@as(i64, 0), root.get("not_covered").?.integer);
    const formulae = root.get("formulae").?.array.items;
    try testing.expectEqual(@as(usize, 2), formulae.len);

    const abcde = formulae[0].object;
    try testing.expectEqualStrings("abcde", abcde.get("name").?.string);
    try testing.expectEqualStrings("2.9.2", abcde.get("installed_version").?.string);
    const open = abcde.get("open").?.array.items;
    try testing.expectEqual(@as(usize, 8), open.len);
    const top = open[0].object;
    try testing.expectEqualStrings("BREW-abcde-CVE-2026-15747", top.get("id").?.string);
    try testing.expectEqualStrings("critical", top.get("severity").?.string);
    try testing.expectEqualStrings("CVE-2026-15747", top.get("upstream").?.array.items[0].string);
    // Optional fields serialise as null rather than vanishing.
    const unlabelled = open[7].object;
    try testing.expect(unlabelled.get("severity").? == .null);
    try testing.expect(unlabelled.get("summary").? == .string);

    const curl = formulae[1].object;
    try testing.expectEqualStrings("curl", curl.get("name").?.string);
    try testing.expectEqual(@as(usize, 0), curl.get("open").?.array.items.len);
}

test "a second run inside the cache TTL performs zero requests" {
    const h = try Harness.init(testing.allocator, "cached");
    defer h.deinit();
    try h.seed(&.{ "abcde@2.9.2", "curl@8.16.0" });

    const first = try h.run(&.{}, false);
    defer testing.allocator.free(first.stdout);
    try testing.expectEqual(@as(u32, 2), h.requests());

    const second = try h.run(&.{}, false);
    defer testing.allocator.free(second.stdout);
    try testing.expectEqual(@as(u32, 2), h.requests());
    try testing.expectEqualStrings(first.stdout, second.stdout);
}

test "an unknown formula is reported as unchecked, never as clean" {
    const h = try Harness.init(testing.allocator, "unknown");
    defer h.deinit();
    try h.seed(&.{"curl@8.16.0"});

    const r = try h.run(&.{"ghost"}, false);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.ScanIncomplete), r.err);
    try testing.expectEqualStrings("", r.stdout);
}

test "one failed fetch leaves the rest of the report intact and marks the scan incomplete" {
    const h = try Harness.init(testing.allocator, "partial");
    defer h.deinit();
    try h.seed(&.{ "abcde@2.9.2", "ghost@1.0", "curl@8.16.0" });

    const r = try h.run(&.{}, false);
    defer testing.allocator.free(r.stdout);
    // The rows the walk did get are printed; the exit code says it is not the whole story.
    try testing.expectEqual(@as(?anyerror, error.ScanIncomplete), r.err);
    try testing.expectEqual(@as(usize, 8), countLines(r.stdout));
    try testing.expectEqual(@as(u32, 3), h.requests());

    const j = try h.run(&.{}, true);
    defer testing.allocator.free(j.stdout);
    try testing.expectEqual(@as(?anyerror, error.ScanIncomplete), j.err);
    try testing.expect(std.mem.indexOf(u8, j.stdout, "\"unchecked\":[\"ghost\"]") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, j.stdout, "\"name\":"));
}

test "an unreadable database is an error, not an all-clear" {
    const h = try Harness.init(testing.allocator, "bad_db");
    defer h.deinit();
    // A directory where the DB file should be cannot be opened as SQLite.
    var db_buf: [512]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&db_buf, "{s}/db/malt.db", .{h.prefix});
    try test_io.cwd().createDirPath(h.threaded.io(), db_path);

    const r = try h.run(&.{}, false);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);
    try testing.expectEqualStrings("", r.stdout);
    try testing.expectEqual(@as(u32, 0), h.requests());
}

test "an interrupt surfaces instead of a report built from cancelled fetches" {
    const h = try Harness.init(testing.allocator, "interrupted");
    defer h.deinit();
    try h.seed(&.{"curl@8.16.0"});

    const prior = malt.signals.isInterrupted();
    defer malt.signals.setInterruptedForTest(prior);
    malt.signals.setInterruptedForTest(true);

    const r = try h.run(&.{}, false);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.UserInterrupted), r.err);
    try testing.expectEqualStrings("", r.stdout);
}

test "a revisioned keg reports its full installed version" {
    const h = try Harness.init(testing.allocator, "revision");
    defer h.deinit();
    try h.seed(&.{"abcde@2.9.3_1"});

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"installed_version\":\"2.9.3_1\"") != null);
}

test "vulns rejects a severity outside the four labels" {
    const h = try Harness.init(testing.allocator, "bad_severity");
    defer h.deinit();
    try h.seed(&.{"curl@8.16.0"});

    const r = try h.run(&.{"--severity=urgent"}, false);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);
    try testing.expectEqual(@as(u32, 0), h.requests());
}

test "offline mode serves a warm cache and refuses a cold one without dialing out" {
    const h = try Harness.init(testing.allocator, "offline");
    defer h.deinit();
    try h.seed(&.{"abcde@2.9.2"});

    // Cold cache: nothing to serve, so the run must stop before any request.
    const cold = try h.runWith(&.{}, false, true);
    defer testing.allocator.free(cold.stdout);
    try testing.expectEqual(@as(?anyerror, error.ScanIncomplete), cold.err);
    try testing.expectEqualStrings("", cold.stdout);
    try testing.expectEqual(@as(u32, 0), h.requests());

    const warm = try h.run(&.{}, false);
    defer testing.allocator.free(warm.stdout);
    try testing.expectEqual(@as(u32, 1), h.requests());

    const offline = try h.runWith(&.{}, false, true);
    defer testing.allocator.free(offline.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), offline.err);
    try testing.expectEqualStrings(warm.stdout, offline.stdout);
    try testing.expectEqual(@as(u32, 1), h.requests());
}

test "a name that is not a formula name never reaches the API" {
    const h = try Harness.init(testing.allocator, "bad_name");
    defer h.deinit();
    try h.seed(&.{"curl@8.16.0"});

    const r = try h.run(&.{"../etc"}, false);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.ScanIncomplete), r.err);
    try testing.expectEqual(@as(u32, 0), h.requests());
}

test "a name repeated on the command line is reported once" {
    const h = try Harness.init(testing.allocator, "dedupe");
    defer h.deinit();
    try h.seed(&.{"curl@8.16.0"});

    const r = try h.run(&.{ "curl", "curl" }, true);
    defer testing.allocator.free(r.stdout);
    try testing.expect(r.err == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.stdout, "\"name\":\"curl\""));
    try testing.expectEqual(@as(u32, 1), h.requests());
}

test "a tap keg whose recipe cannot be fetched is unchecked, never quietly uncovered" {
    const h = try Harness.init(testing.allocator, "non_core");
    defer h.deinit();
    try h.seed(&.{"curl@8.16.0"});
    // No route serves `ghost.rb`, so the recipe fetch 404s on every layout.
    try h.seedTap("someone/tap", &.{"ghost@1.0"});
    try h.seedTap("local", &.{"mine@0.1"});

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.ScanIncomplete), r.err);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.stdout, "\"name\":"));
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"unchecked\":[\"ghost\"]") != null);
    // Only the --local keg has no recipe to resolve; machine readers get the
    // same coverage figure the human summary shows.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"not_covered\":1") != null);

    // Naming formulae explicitly skips nothing, so nothing is reported as uncovered.
    const named = try h.run(&.{"curl"}, true);
    defer testing.allocator.free(named.stdout);
    try testing.expect(std.mem.indexOf(u8, named.stdout, "\"not_covered\":0") != null);
}

test "a tap keg whose recipe declares sha256 :no_check is still scanned from its url" {
    const h = try Harness.init(testing.allocator, "tap_nocheck");
    defer h.deinit();
    try h.seedTap("someone/tap", &.{"nocheck@1.0"});

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expect(std.mem.indexOf(u8, h.postBody(), "https://github.com/someone/nocheck") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"unchecked\":[]") != null);
}

test "a :latest tap keg is not covered, never reported clean nor a failed scan" {
    const h = try Harness.init(testing.allocator, "tap_nolatest");
    defer h.deinit();
    try h.seedTap("someone/tap", &.{"nolatest@1.0"});

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    // An exit that never clears would keep a CI gate red for good.
    try testing.expect(r.err == null);
    try testing.expectEqualStrings("{\"schema_version\":1,\"not_covered\":1,\"unchecked\":[],\"formulae\":[]}\n", r.stdout);
    // A forge url, so the skipped query is the :latest rule, not an unknown host.
    try testing.expectEqualStrings("", h.postBody());
}

test "a tap keg installed from Casks/ is scanned from the cask, not a same-named formula" {
    const h = try Harness.init(testing.allocator, "tap_dual");
    defer h.deinit();
    try h.seedTap("someone/tap", &.{"dual@1.0.0"});
    {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{h.prefix}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try db.exec("UPDATE kegs SET tap_rb_subtree = 'cask' WHERE name = 'dual';");
    }

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expect(std.mem.indexOf(u8, h.postBody(), "cask-side/dual") != null);
    try testing.expect(std.mem.indexOf(u8, h.postBody(), "formula-side") == null);
}

test "a tap keg is scanned against OSV from its recipe url" {
    const h = try Harness.init(testing.allocator, "tap_osv");
    defer h.deinit();
    try h.seed(&.{"curl@8.16.0"});
    try h.seedTap("someone/tap", &.{"cliamp@2.2.0"});

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);

    // OSV was asked about the lowercased repo at the tag the asset url carries.
    try testing.expectEqualStrings(
        "{\"queries\":[{\"package\":{\"ecosystem\":\"GIT\",\"name\":\"https://github.com/bjarneo/cliamp\"},\"version\":\"v2.2.0\"}]}",
        h.postBody(),
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, r.stdout, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqual(@as(i64, 0), root.get("not_covered").?.integer);
    try testing.expectEqual(@as(usize, 0), root.get("unchecked").?.array.items.len);
    const formulae = root.get("formulae").?.array.items;
    try testing.expectEqual(@as(usize, 2), formulae.len);
    const cliamp = formulae[1].object;
    try testing.expectEqualStrings("cliamp", cliamp.get("name").?.string);
    try testing.expectEqualStrings("2.2.0", cliamp.get("installed_version").?.string);
    const open = cliamp.get("open").?.array.items;
    try testing.expectEqual(@as(usize, 1), open.len);
    const hit = open[0].object;
    try testing.expectEqualStrings("GHSA-aaaa-bbbb-cccc", hit.get("id").?.string);
    try testing.expectEqualStrings("critical", hit.get("severity").?.string);
    try testing.expectEqualStrings("Path traversal in playlist loader", hit.get("summary").?.string);
    try testing.expectEqual(@as(usize, 0), hit.get("upstream").?.array.items.len);

    // The human row reads like a core one; the id column carries the OSV id.
    const human = try h.run(&.{}, false);
    defer testing.allocator.free(human.stdout);
    try testing.expectEqualStrings(
        "cliamp  critical  GHSA-aaaa-bbbb-cccc  Path traversal in playlist loader\n",
        human.stdout,
    );
}

test "a tap keg named on the command line is scanned via OSV, not asked of the API" {
    const h = try Harness.init(testing.allocator, "tap_named");
    defer h.deinit();
    try h.seed(&.{"curl@8.16.0"});
    try h.seedTap("someone/tap", &.{"cliamp@2.2.0"});

    const r = try h.run(&.{"cliamp"}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);
    // Recipe, batch query, one detail: no `/formula/cliamp.json` 404 in between.
    try testing.expectEqual(@as(u32, 3), h.requests());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"unchecked\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"not_covered\":0") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.stdout, "\"name\":"));
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"id\":\"GHSA-aaaa-bbbb-cccc\"") != null);
}

test "a tap keg recorded without its installed commit resolves the tap HEAD first" {
    const h = try Harness.init(testing.allocator, "tap_head");
    defer h.deinit();
    try h.seedTapAt("someone/tap", null, &.{"cliamp@2.2.0"});

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);
    // HEAD lookup, recipe, batch query, one detail.
    try testing.expectEqual(@as(u32, 4), h.requests());
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"id\":\"GHSA-aaaa-bbbb-cccc\"") != null);
}

test "a named tap keg is still counted as uncovered offline rather than vanishing" {
    const h = try Harness.init(testing.allocator, "tap_named_offline");
    defer h.deinit();
    try h.seedTap("someone/tap", &.{"cliamp@2.2.0"});

    const r = try h.runWith(&.{"cliamp"}, true, true);
    defer testing.allocator.free(r.stdout);
    try testing.expect(r.err == null);
    try testing.expectEqual(@as(u32, 0), h.requests());
    try testing.expectEqualStrings("{\"schema_version\":1,\"not_covered\":1,\"unchecked\":[],\"formulae\":[]}\n", r.stdout);
}

test "an OSV outage marks every identified tap keg unchecked and leaves core rows intact" {
    const h = try Harness.init(testing.allocator, "osv_down");
    defer h.deinit();
    h.server.batch_body = "<html>502 Bad Gateway</html>";
    try h.seed(&.{"abcde@2.9.2"});
    try h.seedTap("someone/tap", &.{"cliamp@2.2.0"});

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.ScanIncomplete), r.err);
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"unchecked\":[\"cliamp\"]") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.stdout, "\"name\":"));
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, r.stdout, "\"id\":"));
}

/// A batch answer listing `n` distinct low advisories for one keg.
fn wideBatch(buf: []u8, n: usize) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("{\"results\":[{\"vulns\":[");
    for (0..n) |i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"id\":\"X-{d}\"}}", .{i});
    }
    try w.writeAll("]}]}");
    return w.buffered();
}

test "detail is fetched for the first twenty hits only, unless a severity filter needs every rank" {
    const h = try Harness.init(testing.allocator, "detail_cap");
    defer h.deinit();
    var batch_buf: [2048]u8 = undefined;
    h.server.batch_body = try wideBatch(&batch_buf, 25);
    try h.seedTap("someone/tap", &.{"cliamp@2.2.0"});

    // Recipe + batch + 20 details; the other five rows still list, id-only.
    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);
    try testing.expectEqual(@as(u32, 22), h.requests());
    try testing.expectEqual(@as(usize, 25), std.mem.count(u8, r.stdout, "\"id\":"));
    try testing.expectEqual(@as(usize, 20), std.mem.count(u8, r.stdout, "\"severity\":\"low\""));
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, r.stdout, "\"severity\":null"));

    // A filter ranks every row, so an unranked row can no longer hide behind the cap.
    const filtered = try h.run(&.{"--severity=low"}, true);
    defer testing.allocator.free(filtered.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), filtered.err);
    try testing.expectEqual(@as(u32, 22 + 2 + 25), h.requests());
    try testing.expectEqual(@as(usize, 25), std.mem.count(u8, filtered.stdout, "\"severity\":\"low\""));
}

test "one advisory shared by two tap kegs is detailed once and reported for both" {
    const h = try Harness.init(testing.allocator, "shared_id");
    defer h.deinit();
    h.server.batch_body =
        \\{"results":[{"vulns":[{"id":"GHSA-aaaa-bbbb-cccc"}]},{"vulns":[{"id":"GHSA-aaaa-bbbb-cccc"}]}]}
    ;
    try h.seedTap("someone/tap", &.{ "cliamp@2.2.0", "cliamp2@2.2.0" });

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);
    // Two recipes, one batch, one detail.
    try testing.expectEqual(@as(u32, 4), h.requests());
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, r.stdout, "\"id\":\"GHSA-aaaa-bbbb-cccc\""));
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, r.stdout, "Path traversal in playlist loader"));
}

test "--severity filters OSV rows the same way it filters API rows" {
    const h = try Harness.init(testing.allocator, "osv_severity");
    defer h.deinit();
    h.server.batch_body =
        \\{"results":[{"vulns":[{"id":"GHSA-aaaa-bbbb-cccc"},{"id":"X-low"}]}]}
    ;
    try h.seedTap("someone/tap", &.{"cliamp@2.2.0"});

    const r = try h.run(&.{"--severity=high"}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.Aborted), r.err);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.stdout, "\"id\":"));
    try testing.expect(std.mem.indexOf(u8, r.stdout, "X-low") == null);
}

test "an interrupt during the OSV phase surfaces instead of a report that looks finished" {
    const h = try Harness.init(testing.allocator, "osv_interrupted");
    defer h.deinit();
    try h.seedTap("someone/tap", &.{"cliamp@2.2.0"});

    const prior = malt.signals.isInterrupted();
    defer malt.signals.setInterruptedForTest(prior);
    defer malt.signals.armInterruptAfterForTest(0);
    malt.signals.setInterruptedForTest(false);
    // Polls: after the API fetches, after the recipe fetches, after OSV.
    malt.signals.armInterruptAfterForTest(3);

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expectEqual(@as(?anyerror, error.UserInterrupted), r.err);
    try testing.expectEqualStrings("", r.stdout);
}

test "offline mode leaves tap kegs uncovered without dialling out" {
    const h = try Harness.init(testing.allocator, "tap_offline");
    defer h.deinit();
    try h.seedTap("someone/tap", &.{"cliamp@2.2.0"});

    const r = try h.runWith(&.{}, true, true);
    defer testing.allocator.free(r.stdout);
    try testing.expect(r.err == null);
    try testing.expectEqual(@as(u32, 0), h.requests());
    try testing.expectEqualStrings("{\"schema_version\":1,\"not_covered\":1,\"unchecked\":[],\"formulae\":[]}\n", r.stdout);
}

test "a cold walk over many formulae fetches concurrently" {
    const h = try Harness.init(testing.allocator, "fanout");
    defer h.deinit();
    h.server.rendezvous = 2;
    try h.seed(&.{ "f0@1.0", "f1@1.0", "f2@1.0", "f3@1.0", "f4@1.0", "f5@1.0", "f6@1.0", "f7@1.0" });

    const r = try h.run(&.{}, false);
    defer testing.allocator.free(r.stdout);
    try testing.expect(r.err == null);
    try testing.expectEqual(@as(u32, 8), h.requests());
    // Serial fetching would sit out every hold alone and never reach two.
    try testing.expect(h.server.peak_in_flight.load(.acquire) >= 2);
}

test "an empty walk still emits the JSON envelope with its coverage count" {
    const h = try Harness.init(testing.allocator, "json_empty");
    defer h.deinit();
    try h.seedTap("local", &.{"mine@0.1"});

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expect(r.err == null);
    try testing.expectEqual(@as(u32, 0), h.requests());
    try testing.expectEqualStrings("{\"schema_version\":1,\"not_covered\":1,\"unchecked\":[],\"formulae\":[]}\n", r.stdout);
}
