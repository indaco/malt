//! malt — purge JSON / NDJSON output sink.
//!
//! Two complementary modes that scripts can drive without parsing the
//! human stderr surface. Both are gated by global flags applied before
//! dispatch — `--json` for the single-summary mode, `--output-format=
//! ndjson` for the streaming mode. Stderr remains the human path in
//! either mode so interactive runs keep their existing TTY layout.
//!
//! ## Wire format (v2)
//!
//! ### `--json` summary (one object on stdout, trailing `\n`)
//!
//! ```json
//! {
//!   "version": 2,
//!   "dry_run": false,
//!   "scopes": [
//!     {"name": "store-orphans", "removed": 5, "bytes": 4096, "status": "ok"},
//!     {"name": "unused-deps",   "removed": 0, "bytes": 0,    "status": "error", "error_kind": "db_unreadable"}
//!   ],
//!   "totals": {"removed": 5, "bytes": 4096},
//!   "status": "error",
//!   "time_ms": 12
//! }
//! ```
//!
//! ### `--output-format=ndjson` event stream (one object per line)
//!
//! ```ndjson
//! {"event":"scope_started","scope":"store-orphans","dry_run":false}
//! {"event":"scope_completed","scope":"store-orphans","removed":5,"bytes":4096,"dry_run":false,"status":"ok"}
//! {"event":"purge_complete","removed":5,"bytes":4096,"dry_run":false,"status":"ok"}
//! ```
//!
//! Field guarantees:
//! - `version` is the schema version. Bumped only on a breaking change;
//!   a `version` field is always present so consumers can branch.
//! - `dry_run` is a boolean on every event and on the summary. Purge
//!   uses a field rather than a `would_*` verb (the install/upgrade
//!   convention) because dry-run still walks every scope; events are
//!   semantically the same, only the side-effect is suppressed.
//! - Scope names match the long-form CLI flags minus the `--` prefix
//!   (`store-orphans`, `unused-deps`, `cache`, `downloads`,
//!   `stale-casks`, `old-versions`, `wipe`).
//! - `scope_started` always pairs with a `scope_completed`, even on
//!   error paths (UserAborted, OOM). `purge_complete` always closes
//!   the stream. Consumers can rely on strict open/close brackets.
//! - `status` is `"ok"` or `"error"` on every `scope_completed` and
//!   `purge_complete` event (and on every summary scope row + the
//!   summary itself). Distinguishes a clean no-op from a swallowed
//!   internal failure that the human stderr path already surfaced.
//! - `error_kind` is a stable lowercase token included only when
//!   `status == "error"` so scripts can branch without parsing
//!   free-form errno strings.
//!
//! ## Emit atomicity
//!
//! Both modes share one shape: build into a fixed stack buffer, then
//! write the buffered bytes to stdout in a single call. An overflow
//! is dropped silently rather than streamed half-formed, so consumers
//! always see a complete JSON object (or no bytes) - never a torn
//! document. The buffer is sized for the closed schema (7 scopes, a
//! closed `error_kind` vocabulary, u64 counters), so overflow is a
//! schema-growth bug, not a runtime condition. The regression tests
//! in this file pin both the at-budget success path and the overflow
//! drop, so a future schema bump that breaks the budget trips a unit
//! test instead of silently truncating output.

const std = @import("std");
const output = @import("../../ui/output.zig");
const report = @import("report.zig");
const util = @import("util.zig");

pub const ScopeStatus = util.ScopeStatus;

/// v2 added `status` (and optional `error_kind`) so consumers can tell
/// a clean no-op apart from a swallowed scope failure.
pub const schema_version: u32 = 2;

/// Wire-format event names. Mirrors the closed-vocabulary pattern in
/// `output.NdjsonEvent`: a typo at a call site fails to compile rather
/// than emitting a malformed line.
pub const PurgeEvent = enum {
    scope_started,
    scope_completed,
    purge_complete,
};

/// Build the `--json` summary document. Pure: writes only to `w`, takes
/// no allocator, no IO. The orchestrator pre-aggregates `rows` and
/// `totals` so this stays a serialiser.
pub fn buildSummary(
    w: *std.Io.Writer,
    dry_run: bool,
    rows: []const report.SummaryRow,
    total_removed: u64,
    total_bytes: u64,
    time_ms: i64,
) !void {
    try w.print(
        "{{\"version\":{d},\"dry_run\":{s},\"scopes\":[",
        .{ schema_version, if (dry_run) "true" else "false" },
    );
    var any_error = false;
    for (rows, 0..) |row, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, row.name);
        try w.print(",\"removed\":{d},\"bytes\":{d},\"status\":\"{s}\"", .{
            row.removed,
            row.bytes,
            statusTag(row.status),
        });
        if (row.status == .err) {
            any_error = true;
            if (row.error_kind) |kind| {
                try w.writeAll(",\"error_kind\":");
                try output.jsonStr(w, kind);
            }
        }
        try w.writeAll("}");
    }
    try w.print(
        "],\"totals\":{{\"removed\":{d},\"bytes\":{d}}},\"status\":\"{s}\",\"time_ms\":{d}}}\n",
        .{ total_removed, total_bytes, statusTag(if (any_error) .err else .ok), time_ms },
    );
}

fn statusTag(s: ScopeStatus) []const u8 {
    return switch (s) {
        .ok => "ok",
        .err => "error",
    };
}

/// Shared ndjson event emitter for purge events. Mirrors the silent-drop
/// semantics of `output.emitNdjsonEvent`: an event that would overflow
/// the fixed buffer (adversarial scope name, pathological counts) is
/// dropped rather than failing the command — the human stderr path is
/// still authoritative.
fn emitEvent(
    event: PurgeEvent,
    scope: ?[]const u8,
    removed: ?u64,
    bytes: ?u64,
    dry_run: bool,
    status: ?ScopeStatus,
    error_kind: ?[]const u8,
) void {
    if (!output.isNdjson()) return;
    // Matches output.emitNdjsonEvent: 1 KiB swallows worst-case
    // adversarial-escape names so silent-drop is reachable only on
    // genuinely pathological input, never on the closed scope set.
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(buf[0..]);
    w.writeAll("{\"event\":") catch return;
    output.jsonStr(&w, @tagName(event)) catch return;
    if (scope) |s| {
        w.writeAll(",\"scope\":") catch return;
        output.jsonStr(&w, s) catch return;
    }
    if (removed) |r| w.print(",\"removed\":{d}", .{r}) catch return;
    if (bytes) |b| w.print(",\"bytes\":{d}", .{b}) catch return;
    w.writeAll(",\"dry_run\":") catch return;
    w.writeAll(if (dry_run) "true" else "false") catch return;
    if (status) |s| {
        w.print(",\"status\":\"{s}\"", .{statusTag(s)}) catch return;
        if (s == .err) {
            if (error_kind) |kind| {
                w.writeAll(",\"error_kind\":") catch return;
                output.jsonStr(&w, kind) catch return;
            }
        }
    }
    w.writeAll("}\n") catch return;
    output.writeStdoutAll(w.buffered());
}

/// Emit `{"event":"scope_started","scope":"<name>","dry_run":<bool>}\n`
/// when ndjson mode is on; no-op otherwise. Per-scope ndjson is one
/// summary line, not one line per item — call sites stay unchanged.
pub fn emitScopeStarted(scope: []const u8, dry_run: bool) void {
    emitEvent(.scope_started, scope, null, null, dry_run, null, null);
}

/// Emit `{"event":"scope_completed","scope":...,"removed":N,"bytes":B,"dry_run":<bool>,"status":...}\n`.
/// `error_kind` is only included on `.err` so consumers don't branch on
/// `null` vs missing.
pub fn emitScopeCompleted(
    scope: []const u8,
    removed: u64,
    bytes: u64,
    dry_run: bool,
    status: ScopeStatus,
    error_kind: ?[]const u8,
) void {
    emitEvent(.scope_completed, scope, removed, bytes, dry_run, status, error_kind);
}

/// Emit `{"event":"purge_complete","removed":N,"bytes":B,"dry_run":<bool>,"status":...}\n`.
pub fn emitPurgeComplete(
    removed: u64,
    bytes: u64,
    dry_run: bool,
    status: ScopeStatus,
    error_kind: ?[]const u8,
) void {
    emitEvent(.purge_complete, null, removed, bytes, dry_run, status, error_kind);
}

/// Stack buffer for the `--json` summary. Sized for the closed schema
/// (7 scopes max, longest scope name 13 chars, longest `error_kind`
/// token 17 chars, u64 counters): worst-case payload is ~1.1KB; 2KB
/// gives headroom for schema growth before the overflow-drop tests
/// flip red.
const summary_buffer_size: usize = 2048;

/// Build + flush the `--json` summary to stdout in a single write.
/// Builds into a fixed stack buffer so the emit is structurally
/// all-or-nothing: an oversized document is dropped silently rather
/// than written half-formed, mirroring the ndjson silent-drop policy.
pub fn emitSummary(
    dry_run: bool,
    rows: []const report.SummaryRow,
    total_removed: u64,
    total_bytes: u64,
    time_ms: i64,
) void {
    var buf: [summary_buffer_size]u8 = undefined;
    var w = std.Io.Writer.fixed(buf[0..]);
    buildSummary(&w, dry_run, rows, total_removed, total_bytes, time_ms) catch return;
    output.writeStdoutAll(w.buffered());
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "buildSummary emits a parseable object with required top-level keys" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const rows = [_]report.SummaryRow{
        .{ .name = "store-orphans", .removed = 5, .bytes = 4096 },
        .{ .name = "unused-deps", .removed = 1, .bytes = 0 },
    };
    try buildSummary(&aw.writer, false, &rows, 6, 4096, 12);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(@as(i64, schema_version), obj.get("version").?.integer);
    try testing.expectEqual(false, obj.get("dry_run").?.bool);
    try testing.expectEqual(@as(usize, 2), obj.get("scopes").?.array.items.len);
    const totals = obj.get("totals").?.object;
    try testing.expectEqual(@as(i64, 6), totals.get("removed").?.integer);
    try testing.expectEqual(@as(i64, 4096), totals.get("bytes").?.integer);
    try testing.expectEqual(@as(i64, 12), obj.get("time_ms").?.integer);
}

test "buildSummary marks dry-run runs with dry_run:true" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try buildSummary(&aw.writer, true, &.{}, 0, 0, 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expectEqual(true, parsed.value.object.get("dry_run").?.bool);
}

test "buildSummary scope rows pin name/removed/bytes shape" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    const rows = [_]report.SummaryRow{
        .{ .name = "cache", .removed = 3, .bytes = 1024 },
    };
    try buildSummary(&aw.writer, false, &rows, 3, 1024, 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const scope = parsed.value.object.get("scopes").?.array.items[0].object;
    try testing.expectEqualStrings("cache", scope.get("name").?.string);
    try testing.expectEqual(@as(i64, 3), scope.get("removed").?.integer);
    try testing.expectEqual(@as(i64, 1024), scope.get("bytes").?.integer);
}

test "buildSummary escapes special characters in scope names" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const rows = [_]report.SummaryRow{
        .{ .name = "weird\"name", .removed = 0, .bytes = 0 },
    };
    try buildSummary(&aw.writer, false, &rows, 0, 0, 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    const scope = parsed.value.object.get("scopes").?.array.items[0].object;
    try testing.expectEqualStrings("weird\"name", scope.get("name").?.string);
}

test "emit helpers no-op when ndjson mode is off" {
    const prior = output.isNdjson();
    defer output.setNdjson(prior);
    output.setNdjson(false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &buf);
    defer output.endStdoutCapture();

    emitScopeStarted("cache", false);
    emitScopeCompleted("cache", 1, 2, false, .ok, null);
    emitPurgeComplete(1, 2, false, .ok, null);

    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "emitScopeStarted writes one parseable line" {
    const prior = output.isNdjson();
    defer output.setNdjson(prior);
    output.setNdjson(true);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &buf);
    defer output.endStdoutCapture();

    emitScopeStarted("store-orphans", true);

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, buf.items, "\n"));
    const line = std.mem.trimEnd(u8, buf.items, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("scope_started", parsed.value.object.get("event").?.string);
    try testing.expectEqualStrings("store-orphans", parsed.value.object.get("scope").?.string);
    try testing.expectEqual(true, parsed.value.object.get("dry_run").?.bool);
}

test "emitScopeCompleted carries removed/bytes counters" {
    const prior = output.isNdjson();
    defer output.setNdjson(prior);
    output.setNdjson(true);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &buf);
    defer output.endStdoutCapture();

    emitScopeCompleted("cache", 7, 8192, false, .ok, null);

    const line = std.mem.trimEnd(u8, buf.items, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("scope_completed", obj.get("event").?.string);
    try testing.expectEqualStrings("cache", obj.get("scope").?.string);
    try testing.expectEqual(@as(i64, 7), obj.get("removed").?.integer);
    try testing.expectEqual(@as(i64, 8192), obj.get("bytes").?.integer);
    try testing.expectEqual(false, obj.get("dry_run").?.bool);
}

test "emitPurgeComplete brackets the stream" {
    const prior = output.isNdjson();
    defer output.setNdjson(prior);
    output.setNdjson(true);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &buf);
    defer output.endStdoutCapture();

    emitPurgeComplete(42, 1_048_576, false, .ok, null);

    const line = std.mem.trimEnd(u8, buf.items, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("purge_complete", obj.get("event").?.string);
    try testing.expectEqual(@as(i64, 42), obj.get("removed").?.integer);
    try testing.expectEqual(@as(i64, 1_048_576), obj.get("bytes").?.integer);
}

test "emitScopeCompleted carries status and optional error_kind on errors" {
    const prior = output.isNdjson();
    defer output.setNdjson(prior);
    output.setNdjson(true);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &buf);
    defer output.endStdoutCapture();

    emitScopeCompleted("store-orphans", 0, 0, false, .err, "open_failed");

    const line = std.mem.trimEnd(u8, buf.items, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("error", obj.get("status").?.string);
    try testing.expectEqualStrings("open_failed", obj.get("error_kind").?.string);
}

test "emitScopeCompleted reports status:ok and omits error_kind on success" {
    const prior = output.isNdjson();
    defer output.setNdjson(prior);
    output.setNdjson(true);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &buf);
    defer output.endStdoutCapture();

    emitScopeCompleted("cache", 5, 1024, false, .ok, null);

    const line = std.mem.trimEnd(u8, buf.items, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("ok", obj.get("status").?.string);
    try testing.expect(obj.get("error_kind") == null);
}

test "ndjson emit drops cleanly when a scope name overflows the line buffer" {
    // Pins the silent-drop fallback for the per-event line buffer:
    // an adversarial scope name that doesn't fit must drop without
    // crashing or emitting a torn line. Mirrors the same guarantee
    // output.emitNdjsonEvent makes for install-side events.
    const prior = output.isNdjson();
    defer output.setNdjson(prior);
    output.setNdjson(true);

    var huge_name: [2048]u8 = undefined;
    @memset(huge_name[0..], 'x');

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &buf);
    defer output.endStdoutCapture();

    emitScopeStarted(huge_name[0..], false);

    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "emitSummary writes the full closed-schema worst case in one go" {
    // Pins the buffer budget: the worst-case payload for the closed
    // schema (7 scopes, longest names + error_kind tokens, max u64
    // counters) must fit in the fixed stack buffer. A schema bump
    // that breaks the budget flips this test red before users see
    // truncated output.
    const longest_scope_name = "store-orphans";
    const longest_error_kind = "enumerate_orphans";
    const rows = [_]report.SummaryRow{
        .{ .name = longest_scope_name, .removed = std.math.maxInt(u32), .bytes = std.math.maxInt(u64), .status = .err, .error_kind = longest_error_kind },
        .{ .name = "unused-deps", .removed = std.math.maxInt(u32), .bytes = std.math.maxInt(u64), .status = .err, .error_kind = longest_error_kind },
        .{ .name = "cache", .removed = std.math.maxInt(u32), .bytes = std.math.maxInt(u64), .status = .err, .error_kind = longest_error_kind },
        .{ .name = "downloads", .removed = std.math.maxInt(u32), .bytes = std.math.maxInt(u64), .status = .err, .error_kind = longest_error_kind },
        .{ .name = "stale-casks", .removed = std.math.maxInt(u32), .bytes = std.math.maxInt(u64), .status = .err, .error_kind = longest_error_kind },
        .{ .name = "old-versions", .removed = std.math.maxInt(u32), .bytes = std.math.maxInt(u64), .status = .err, .error_kind = longest_error_kind },
        .{ .name = "wipe", .removed = std.math.maxInt(u32), .bytes = std.math.maxInt(u64), .status = .err, .error_kind = longest_error_kind },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &buf);
    defer output.endStdoutCapture();

    emitSummary(false, &rows, std.math.maxInt(u64), std.math.maxInt(u64), std.math.maxInt(i64));

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, buf.items, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 7), parsed.value.object.get("scopes").?.array.items.len);
}

test "emitSummary drops cleanly when the document overflows the stack buffer" {
    // Pins the silent-drop fallback so an oversized document - only
    // reachable today via a synthesised over-long scope name - never
    // surfaces a half-written object on stdout.
    var huge_name: [summary_buffer_size]u8 = undefined;
    @memset(huge_name[0..], 'x');
    const rows = [_]report.SummaryRow{
        .{ .name = huge_name[0..], .removed = 0, .bytes = 0 },
    };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    output.beginStdoutCapture(testing.allocator, &buf);
    defer output.endStdoutCapture();

    emitSummary(false, &rows, 0, 0, 0);

    try testing.expectEqual(@as(usize, 0), buf.items.len);
}
