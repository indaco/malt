//! malt — `mt vulns` integration tests.
//!
//! Drives `execute` against a scratch prefix and a loopback fixture mirror:
//! `abcde` (copied from the live API, eight open advisories) and a clean
//! `curl`. Pins the human rows, the `--json` shape, the exit code, and that
//! a second run inside the cache TTL performs no request at all.

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
        var req = srv.receiveHead() catch return;
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
        if (std.mem.eql(u8, target, "/formula/abcde.json")) {
            req.respond(abcde_json, .{}) catch return;
        } else if (std.mem.eql(u8, target, "/formula/curl.json")) {
            req.respond(curl_json, .{}) catch return;
        } else if (std.mem.startsWith(u8, target, "/formula/f")) {
            // Synthetic clean formulae f0..fN for fan-out tests; the body's
            // own name is never read, so the clean fixture serves them all.
            req.respond(curl_json, .{}) catch return;
        } else {
            req.respond("", .{ .status = .not_found }) catch return;
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
    /// attributed to `tap` (empty reads as homebrew/core).
    fn seedTap(h: *Harness, tap: []const u8, kegs: []const []const u8) !void {
        var db_path_buf: [512]u8 = undefined;
        const db_path = try std.fmt.bufPrintSentinel(&db_path_buf, "{s}/db/malt.db", .{h.prefix}, 0);
        var db = try sqlite.Database.open(db_path);
        defer db.close();
        try schema.initSchema(&db);
        for (kegs) |spec| {
            const at = std.mem.indexOfScalar(u8, spec, '@').?;
            const pkg = malt.formula.parsePkgVersion(spec[at + 1 ..]);
            var stmt = try db.prepare(
                \\INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, tap)
                \\VALUES (?1, ?1, ?2, ?3, '', '/c/x', ?4);
            );
            defer stmt.finalize();
            try stmt.bindText(1, spec[0..at]);
            try stmt.bindText(2, pkg.version);
            try stmt.bindInt(3, pkg.revision);
            try stmt.bindText(4, tap);
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
        const err: ?anyerror = if (vulns.execute(&ctx, h.allocator, args)) null else |e| e;
        const bytes = try test_io.cwd().readFileAlloc(io, cap_path, h.allocator, .unlimited);
        return .{ .stdout = bytes, .err = err };
    }

    fn requests(h: *Harness) u32 {
        return h.server.count.load(.monotonic);
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

test "the installed walk skips tap and local kegs the formula API cannot know" {
    const h = try Harness.init(testing.allocator, "non_core");
    defer h.deinit();
    try h.seed(&.{"curl@8.16.0"});
    try h.seedTap("someone/tap", &.{"cliamp@1.0"});
    try h.seedTap("local", &.{"mine@0.1"});

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expect(r.err == null);
    try testing.expectEqual(@as(u32, 1), h.requests());
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.stdout, "\"name\":"));
    try testing.expect(std.mem.indexOf(u8, r.stdout, "cliamp") == null);
    // Machine readers get the same coverage figure the human summary shows.
    try testing.expect(std.mem.indexOf(u8, r.stdout, "\"not_covered\":2") != null);

    // Naming formulae explicitly skips nothing, so nothing is reported as uncovered.
    const named = try h.run(&.{"curl"}, true);
    defer testing.allocator.free(named.stdout);
    try testing.expect(std.mem.indexOf(u8, named.stdout, "\"not_covered\":0") != null);
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
    try h.seedTap("someone/tap", &.{"cliamp@1.0"});

    const r = try h.run(&.{}, true);
    defer testing.allocator.free(r.stdout);
    try testing.expect(r.err == null);
    try testing.expectEqual(@as(u32, 0), h.requests());
    try testing.expectEqualStrings("{\"schema_version\":1,\"not_covered\":1,\"unchecked\":[],\"formulae\":[]}\n", r.stdout);
}
