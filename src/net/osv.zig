//! malt — OSV.dev client (https://google.github.io/osv.dev/api/).
//! One `querybatch` POST per scan, one `vulns/<id>` GET per hit the caller
//! wants detail for. Leaf: imports only `net/client` and std, and hands back
//! a closed error set (Rule U1).

const std = @import("std");
const client_mod = @import("client.zig");

pub const default_base_url: []const u8 = "https://api.osv.dev/v1";

pub const OsvError = error{
    OfflineRequired,
    RequestFailed,
    /// OSV throttled us past the retry budget; the scan should say so.
    RateLimited,
    /// The body was not the shape the API documents; the answer is unusable.
    MalformedResponse,
    Canceled,
    OutOfMemory,
};

/// One GIT-ecosystem query: the repository OSV indexes and the release tag.
pub const Target = struct {
    repo_url: []const u8,
    tag: []const u8,
};

/// What a scan reports per hit. `severity` is already one of the four
/// labels the formula API uses, or null when OSV carries none we can read.
pub const Advisory = struct {
    id: []const u8,
    summary: ?[]const u8,
    severity: ?[]const u8,
};

/// A querybatch answer is a list of ids; a whole page is far below this.
const max_response_bytes: usize = 4 * 1024 * 1024;
/// Brew's ceiling for `next_page_token` continuations.
const max_pages: usize = 100;

fn mapGetError(e: client_mod.GetError) OsvError {
    return switch (e) {
        error.OfflineRequired => error.OfflineRequired,
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.Canceled,
        else => error.RequestFailed,
    };
}

fn statusError(status: u16) OsvError {
    return if (status == 429) error.RateLimited else error.RequestFailed;
}

/// Wire shape of one querybatch entry; field order is the emitted order.
const Query = struct {
    package: struct { ecosystem: []const u8 = "GIT", name: []const u8 },
    version: []const u8,
    page_token: ?[]const u8 = null,
};

const Pending = struct { slot: usize, page_token: ?[]const u8 };

/// Advisory ids per target, same order as `targets`. Allocated on `arena`.
pub fn queryBatch(
    http: *client_mod.HttpClient,
    arena: std.mem.Allocator,
    base_url: []const u8,
    targets: []const Target,
) OsvError![]const []const []const u8 {
    const out = try arena.alloc([]const []const u8, targets.len);
    if (targets.len == 0) return out;

    var url_buf: [512]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "{s}/querybatch", .{base_url}) catch return error.RequestFailed;

    const lists = try arena.alloc(std.ArrayList([]const u8), targets.len);
    @memset(lists, .empty);
    const pending = try arena.alloc(Pending, targets.len);
    for (pending, 0..) |*p, i| p.* = .{ .slot = i, .page_token = null };
    var n_pending = targets.len;
    var pages: usize = 0;
    while (n_pending > 0) {
        pages += 1;
        if (pages > max_pages) return error.MalformedResponse;

        const queries = try arena.alloc(Query, n_pending);
        for (queries, pending[0..n_pending]) |*q, p| q.* = .{
            .package = .{ .name = targets[p.slot].repo_url },
            .version = targets[p.slot].tag,
            .page_token = p.page_token,
        };
        const body = try std.json.Stringify.valueAlloc(arena, .{ .queries = queries }, .{ .emit_null_optional_fields = false });

        var resp = http.postJson(url, body, max_response_bytes) catch |e| return mapGetError(e);
        defer resp.deinit();
        if (resp.status != 200) return statusError(resp.status);
        const page = try parseBatchPage(arena, resp.body, n_pending);

        // Compact the continuations in place; `next` never overtakes `i`.
        var next: usize = 0;
        for (page, 0..) |res, i| {
            const slot = pending[i].slot;
            try lists[slot].appendSlice(arena, res.ids);
            if (res.next_page_token) |tok| {
                pending[next] = .{ .slot = slot, .page_token = tok };
                next += 1;
            }
        }
        n_pending = next;
    }
    for (out, lists) |*o, l| o.* = l.items;
    return out;
}

/// `GET /vulns/<id>`, reduced to what the report shows. Allocated on `arena`.
pub fn vulnerability(
    http: *client_mod.HttpClient,
    arena: std.mem.Allocator,
    base_url: []const u8,
    id: []const u8,
) OsvError!Advisory {
    var url_buf: [1024]u8 = undefined;
    const url = vulnUrl(&url_buf, base_url, id) catch return error.RequestFailed;
    var resp = http.get(url) catch |e| return mapGetError(e);
    defer resp.deinit();
    if (resp.status != 200) return statusError(resp.status);
    return parseAdvisory(arena, resp.body);
}

const PageResult = struct {
    ids: []const []const u8,
    next_page_token: ?[]const u8,
};

/// One `querybatch` page: exactly `expected` results, each with its ids and
/// an optional continuation token.
fn parseBatchPage(arena: std.mem.Allocator, body: []const u8, expected: usize) OsvError![]const PageResult {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.MalformedResponse;
    const results = objectField(root, "results") orelse return error.MalformedResponse;
    if (results != .array or results.array.items.len != expected) return error.MalformedResponse;

    const page = try arena.alloc(PageResult, expected);
    for (page, results.array.items) |*out, result| {
        if (result != .object) return error.MalformedResponse;
        var ids: std.ArrayList([]const u8) = .empty;
        if (objectField(result, "vulns")) |vulns| if (vulns == .array) {
            for (vulns.array.items) |v| {
                const id = objectField(v, "id") orelse continue;
                if (id == .string) try ids.append(arena, id.string);
            }
        };
        const token: ?[]const u8 = if (objectField(result, "next_page_token")) |t|
            (if (t == .string and t.string.len > 0) t.string else null)
        else
            null;
        out.* = .{ .ids = ids.items, .next_page_token = token };
    }
    return page;
}

fn parseAdvisory(arena: std.mem.Allocator, body: []const u8) OsvError!Advisory {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.MalformedResponse;
    const id = objectField(root, "id") orelse return error.MalformedResponse;
    if (id != .string) return error.MalformedResponse;
    const summary: ?[]const u8 = if (objectField(root, "summary")) |s| (if (s == .string) s.string else null) else null;
    return .{ .id = id.string, .summary = summary, .severity = severityLabel(root) };
}

fn objectField(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// Port of Homebrew's `Vulnerability#extract_severity`: a CVSS v3 vector
/// in `severity[]` wins, then the database label, then the per-package
/// labels under `affected[]`.
pub fn severityLabel(v: std.json.Value) ?[]const u8 {
    if (objectField(v, "severity")) |entries| if (entries == .array) {
        // Newest CVSS first; only v3 vectors score, so a v4-only record
        // falls through to the labels below.
        inline for (.{ "CVSS_V4", "CVSS_V3", "CVSS_V2" }) |kind| {
            for (entries.array.items) |entry| {
                const t = objectField(entry, "type") orelse continue;
                if (t != .string or !std.mem.eql(u8, t.string, kind)) continue;
                const score = objectField(entry, "score") orelse continue;
                if (score != .string) continue;
                if (cvssSeverity(score.string)) |label| return label;
            }
        }
    };
    if (nestedLabel(v, "database_specific")) |label| return label;
    if (objectField(v, "affected")) |affected| if (affected == .array) {
        for (affected.array.items) |aff| {
            if (nestedLabel(aff, "ecosystem_specific")) |label| return label;
            if (nestedLabel(aff, "database_specific")) |label| return label;
        }
    };
    return null;
}

const labels = std.StaticStringMap([]const u8).initComptime(.{
    .{ "critical", "critical" },
    .{ "high", "high" },
    .{ "medium", "medium" },
    // GitHub's word for the same band.
    .{ "moderate", "medium" },
    .{ "low", "low" },
});

/// `<key>.severity` as one of the four labels, case-insensitively.
fn nestedLabel(v: std.json.Value, key: []const u8) ?[]const u8 {
    const inner = objectField(v, key) orelse return null;
    const sev = objectField(inner, "severity") orelse return null;
    if (sev != .string or sev.string.len > "critical".len) return null;
    var lower: ["critical".len]u8 = undefined;
    return labels.get(std.ascii.lowerString(&lower, sev.string));
}

/// CVSS v3.0/v3.1 base score rating from its vector string; null for any
/// other version so the caller falls through to the next source.
pub fn cvssSeverity(vector: []const u8) ?[]const u8 {
    const score = cvssBaseScore(vector) orelse return null;
    if (score >= 9.0) return "critical";
    if (score >= 7.0) return "high";
    if (score >= 4.0) return "medium";
    if (score > 0.0) return "low";
    return null;
}

const Metric = enum { av, ac, pr, ui, s, c, i, a };
const metric_keys = std.StaticStringMap(Metric).initComptime(.{
    .{ "AV", .av }, .{ "AC", .ac }, .{ "PR", .pr }, .{ "UI", .ui },
    .{ "S", .s },   .{ "C", .c },   .{ "I", .i },   .{ "A", .a },
});

/// CVSS v3.1 specification, section 7.1, with its "Roundup" (appendix A).
fn cvssBaseScore(vector: []const u8) ?f64 {
    var it = std.mem.splitScalar(u8, vector, '/');
    const prefix = it.next() orelse return null;
    if (!std.mem.eql(u8, prefix, "CVSS:3.0") and !std.mem.eql(u8, prefix, "CVSS:3.1")) return null;
    var letters: [8]?u8 = @splat(null);
    while (it.next()) |part| {
        const colon = std.mem.indexOfScalar(u8, part, ':') orelse return null;
        const m = metric_keys.get(part[0..colon]) orelse continue;
        if (part.len != colon + 2) return null;
        letters[@intFromEnum(m)] = part[colon + 1];
    }
    for (letters) |l| if (l == null) return null;
    const get = struct {
        fn at(l: [8]?u8, m: Metric) u8 {
            return l[@intFromEnum(m)].?;
        }
    }.at;

    const scope_changed = switch (get(letters, .s)) {
        'U' => false,
        'C' => true,
        else => return null,
    };
    const av: f64 = switch (get(letters, .av)) {
        'N' => 0.85,
        'A' => 0.62,
        'L' => 0.55,
        'P' => 0.2,
        else => return null,
    };
    const ac: f64 = switch (get(letters, .ac)) {
        'L' => 0.77,
        'H' => 0.44,
        else => return null,
    };
    const pr: f64 = switch (get(letters, .pr)) {
        'N' => 0.85,
        'L' => if (scope_changed) 0.68 else 0.62,
        'H' => if (scope_changed) 0.5 else 0.27,
        else => return null,
    };
    const ui: f64 = switch (get(letters, .ui)) {
        'N' => 0.85,
        'R' => 0.62,
        else => return null,
    };
    const c = ciaWeight(get(letters, .c)) orelse return null;
    const i = ciaWeight(get(letters, .i)) orelse return null;
    const a = ciaWeight(get(letters, .a)) orelse return null;

    const iss = 1.0 - ((1.0 - c) * (1.0 - i) * (1.0 - a));
    const impact = if (scope_changed)
        (7.52 * (iss - 0.029)) - (3.25 * std.math.pow(f64, iss - 0.02, 15))
    else
        6.42 * iss;
    if (impact <= 0) return 0.0;
    const exploitability = 8.22 * av * ac * pr * ui;
    var raw = impact + exploitability;
    if (scope_changed) raw *= 1.08;
    return roundUp(@min(raw, 10.0));
}

fn ciaWeight(letter: u8) ?f64 {
    return switch (letter) {
        'N' => 0.0,
        'L' => 0.22,
        'H' => 0.56,
        else => null,
    };
}

fn roundUp(value: f64) f64 {
    const int: i64 = @intFromFloat(@round(value * 100_000.0));
    if (@rem(int, 10_000) == 0) return @as(f64, @floatFromInt(int)) / 100_000.0;
    return @as(f64, @floatFromInt(@divTrunc(int, 10_000) + 1)) / 10.0;
}

/// `<base>/vulns/<id>` with the id percent-encoded: ids come from a response
/// body, and one carrying `/` or `?` must not rewrite the path.
fn vulnUrl(buf: []u8, base_url: []const u8, id: []const u8) error{NoSpaceLeft}![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s}/vulns/", .{base_url}) catch return error.NoSpaceLeft;
    std.Uri.Component.percentEncode(&w, id, isUnreserved) catch return error.NoSpaceLeft;
    return w.buffered();
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

// --- inline unit tests --------------------------------------------------

const testing = std.testing;

test "cvssSeverity rates a v3 vector by its base score and ignores other versions" {
    try testing.expectEqualStrings("critical", cvssSeverity("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H").?);
    // Scope change lifts a 9.8-shaped vector to 9.9.
    try testing.expectEqualStrings("critical", cvssSeverity("CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:C/C:H/I:H/A:H").?);
    try testing.expectEqualStrings("high", cvssSeverity("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H").?);
    try testing.expectEqualStrings("medium", cvssSeverity("CVSS:3.1/AV:N/AC:L/PR:L/UI:N/S:U/C:L/I:L/A:N").?);
    try testing.expectEqualStrings("low", cvssSeverity("CVSS:3.0/AV:N/AC:H/PR:L/UI:R/S:U/C:L/I:N/A:N").?);
    // No impact at all scores 0.0, which is not a rating.
    try testing.expect(cvssSeverity("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:N") == null);
    try testing.expect(cvssSeverity("CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N") == null);
    try testing.expect(cvssSeverity("AV:N/AC:L/Au:N/C:P/I:P/A:P") == null);
    // A metric outside the spec's values is not scored by guesswork.
    try testing.expect(cvssSeverity("CVSS:3.1/AV:X/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H") == null);
    try testing.expect(cvssSeverity("CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H") == null);
}

fn severityOfJson(json: []const u8) !?[]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    return severityLabel(parsed.value);
}

test "severityLabel prefers the CVSS vector, then the database label, then the affected entries" {
    // The vector says critical while the label says HIGH: the vector wins.
    try testing.expectEqualStrings("critical", (try severityOfJson(
        \\{"severity":[{"type":"CVSS_V3","score":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}],
        \\ "database_specific":{"severity":"HIGH"}}
    )).?);
    // A v4-only vector cannot be scored, so the label carries.
    try testing.expectEqualStrings("high", (try severityOfJson(
        \\{"severity":[{"type":"CVSS_V4","score":"CVSS:4.0/AV:N/AC:L/AT:N/PR:N/UI:N/VC:H/VI:H/VA:H/SC:N/SI:N/SA:N"}],
        \\ "database_specific":{"severity":"HIGH"}}
    )).?);
    // GitHub's MODERATE is the API's medium.
    try testing.expectEqualStrings("medium", (try severityOfJson(
        \\{"database_specific":{"severity":"Moderate"}}
    )).?);
    try testing.expectEqualStrings("low", (try severityOfJson(
        \\{"affected":[{"ecosystem_specific":{"severity":"LOW"}}]}
    )).?);
    try testing.expectEqualStrings("critical", (try severityOfJson(
        \\{"affected":[{"package":{"name":"x"}},{"database_specific":{"severity":"critical"}}]}
    )).?);
    // Anything outside the four words is not a rating; the row still surfaces.
    try testing.expect((try severityOfJson(
        \\{"database_specific":{"severity":"unknown"}}
    )) == null);
    try testing.expect((try severityOfJson("{}")) == null);
    try testing.expect((try severityOfJson("[]")) == null);
}

test "parseBatchPage keeps ids per slot and refuses a result count that does not match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const page = try parseBatchPage(arena,
        \\{"results":[{"vulns":[{"id":"GHSA-1","modified":"x"},{"id":"CVE-2"}]},
        \\            {"vulns":[],"next_page_token":"tok"}]}
    , 2);
    try testing.expectEqual(@as(usize, 2), page.len);
    try testing.expectEqual(@as(usize, 2), page[0].ids.len);
    try testing.expectEqualStrings("GHSA-1", page[0].ids[0]);
    try testing.expectEqualStrings("CVE-2", page[0].ids[1]);
    try testing.expect(page[0].next_page_token == null);
    try testing.expectEqual(@as(usize, 0), page[1].ids.len);
    try testing.expectEqualStrings("tok", page[1].next_page_token.?);

    // A clean answer omits `vulns` entirely.
    const clean = try parseBatchPage(arena, "{\"results\":[{}]}", 1);
    try testing.expectEqual(@as(usize, 0), clean[0].ids.len);

    // One result for two queries: silently zipping would report the wrong
    // keg clean, so the whole page is refused.
    try testing.expectError(error.MalformedResponse, parseBatchPage(arena, "{\"results\":[{}]}", 2));
    try testing.expectError(error.MalformedResponse, parseBatchPage(arena, "{\"results\":{}}", 1));
    try testing.expectError(error.MalformedResponse, parseBatchPage(arena, "{}", 1));
    try testing.expectError(error.MalformedResponse, parseBatchPage(arena, "not json", 1));
    // An entry without a string id is dropped, not reported as an empty id.
    const odd = try parseBatchPage(arena, "{\"results\":[{\"vulns\":[{\"id\":7},{\"id\":\"OK\"}]}]}", 1);
    try testing.expectEqual(@as(usize, 1), odd[0].ids.len);
    try testing.expectEqualStrings("OK", odd[0].ids[0]);
}

test "parseAdvisory reduces a record to id, summary and normalised severity" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const a = try parseAdvisory(arena,
        \\{"id":"GHSA-1","summary":"Bad thing","database_specific":{"severity":"MODERATE"}}
    );
    try testing.expectEqualStrings("GHSA-1", a.id);
    try testing.expectEqualStrings("Bad thing", a.summary.?);
    try testing.expectEqualStrings("medium", a.severity.?);

    const bare = try parseAdvisory(arena, "{\"id\":\"CVE-1\"}");
    try testing.expect(bare.summary == null);
    try testing.expect(bare.severity == null);

    try testing.expectError(error.MalformedResponse, parseAdvisory(arena, "{\"summary\":\"no id\"}"));
    try testing.expectError(error.MalformedResponse, parseAdvisory(arena, "[]"));
}

/// Answers `/querybatch` from a script of bodies, recording every request
/// body, so the continuation loop can be driven end to end.
const BatchTestServer = struct {
    io: std.Io,
    listener: *std.Io.net.Server,
    pages: []const []const u8,
    seen: std.atomic.Value(usize) = .init(0),
    bodies: [4][512]u8 = undefined,
    body_lens: [4]usize = .{ 0, 0, 0, 0 },

    fn serve(self: *BatchTestServer) void {
        while (true) {
            const stream = self.listener.accept(self.io) catch return;
            defer stream.close(self.io);
            var rbuf: [16 * 1024]u8 = undefined;
            var wbuf: [16 * 1024]u8 = undefined;
            var reader = stream.reader(self.io, &rbuf);
            var writer = stream.writer(self.io, &wbuf);
            var srv = std.http.Server.init(&reader.interface, &writer.interface);
            // Keep-alive like a real peer: the continuation rides the same connection.
            while (true) {
                var req = srv.receiveHead() catch return;
                const n = self.seen.fetchAdd(1, .monotonic);
                if (n >= self.pages.len) return;
                var body_buf: [2048]u8 = undefined;
                const body = req.readerExpectNone(&body_buf);
                self.body_lens[n] = body.readSliceShort(&self.bodies[n]) catch 0;
                req.respond(self.pages[n], .{}) catch return;
                // The script is spent; do not sit on the idle connection.
                if (n + 1 == self.pages.len) return;
            }
        }
    }
};

test "queryBatch follows a continuation for the one target that has more and keeps slots aligned" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    const port = listener.socket.address.getPort();

    // Page 1: slot 0 is done, slot 1 continues. Page 2 answers only slot 1.
    var srv = BatchTestServer{ .io = io, .listener = &listener, .pages = &.{
        \\{"results":[{"vulns":[{"id":"A-1"}]},{"vulns":[{"id":"B-1"}],"next_page_token":"tok"}]}
        ,
        \\{"results":[{"vulns":[{"id":"B-2"}]}]}
        ,
    } };
    const thread = try std.Thread.spawn(.{}, BatchTestServer.serve, .{&srv});

    var inner: std.http.Client = .{ .allocator = testing.allocator, .io = io };
    var http = client_mod.HttpClient.initWith(&inner, io, std.process.Environ.empty, testing.allocator);
    defer http.deinit();
    http.retry_backoff_ms = &.{};
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var base_buf: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buf, "http://127.0.0.1:{d}", .{port});
    const ids = try queryBatch(&http, arena_state.allocator(), base, &.{
        .{ .repo_url = "https://github.com/o/a", .tag = "1" },
        .{ .repo_url = "https://github.com/o/b", .tag = "2" },
    });
    listener.deinit(io);
    thread.join();

    try testing.expectEqual(@as(usize, 2), ids.len);
    try testing.expectEqualStrings("A-1", ids[0][0]);
    try testing.expectEqual(@as(usize, 2), ids[1].len);
    try testing.expectEqualStrings("B-1", ids[1][0]);
    try testing.expectEqualStrings("B-2", ids[1][1]);
    // The second request carries only the continuing query, with its token.
    try testing.expectEqualStrings(
        "{\"queries\":[{\"package\":{\"ecosystem\":\"GIT\",\"name\":\"https://github.com/o/b\"},\"version\":\"2\",\"page_token\":\"tok\"}]}",
        srv.bodies[1][0..srv.body_lens[1]],
    );
}

test "vulnUrl percent-encodes an id so it cannot reshape the path" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("https://api.osv.dev/v1/vulns/GHSA-aaaa-bbbb-cccc", try vulnUrl(&buf, "https://api.osv.dev/v1", "GHSA-aaaa-bbbb-cccc"));
    try testing.expectEqualStrings("https://api.osv.dev/v1/vulns/..%2F..%2Fx%3Fy", try vulnUrl(&buf, "https://api.osv.dev/v1", "../../x?y"));
    var tiny: [16]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, vulnUrl(&tiny, "https://api.osv.dev/v1", "GHSA-1"));
}
