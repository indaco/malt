//! malt — purge JSON / NDJSON output sink.
//!
//! Two complementary modes that scripts can drive without parsing the
//! human stderr surface. Both are gated by global flags applied before
//! dispatch — `--json` for the single-summary mode, `--output-format=
//! ndjson` for the streaming mode. Stderr remains the human path in
//! either mode so interactive runs keep their existing TTY layout.
//!
//! ## Wire format (v1)
//!
//! ### `--json` summary (one object on stdout, trailing `\n`)
//!
//! ```json
//! {
//!   "version": 1,
//!   "dry_run": false,
//!   "scopes": [
//!     {"name": "store-orphans", "removed": 5, "bytes": 4096},
//!     {"name": "unused-deps",   "removed": 1, "bytes": 0}
//!   ],
//!   "totals": {"removed": 6, "bytes": 4096},
//!   "time_ms": 12
//! }
//! ```
//!
//! ### `--output-format=ndjson` event stream (one object per line)
//!
//! ```ndjson
//! {"event":"scope_started","scope":"store-orphans","dry_run":false}
//! {"event":"scope_completed","scope":"store-orphans","removed":5,"bytes":4096,"dry_run":false}
//! {"event":"purge_complete","removed":5,"bytes":4096,"dry_run":false}
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

const std = @import("std");
const output = @import("../../ui/output.zig");
const report = @import("report.zig");

pub const schema_version: u32 = 1;

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
    for (rows, 0..) |row, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, row.name);
        try w.print(",\"removed\":{d},\"bytes\":{d}}}", .{ row.removed, row.bytes });
    }
    try w.print(
        "],\"totals\":{{\"removed\":{d},\"bytes\":{d}}},\"time_ms\":{d}}}\n",
        .{ total_removed, total_bytes, time_ms },
    );
}

/// Shared ndjson event emitter for purge events. Mirrors the silent-drop
/// semantics of `output.emitNdjsonEvent`: an event that would overflow
/// the fixed buffer (adversarial scope name, pathological counts) is
/// dropped rather than failing the command — the human stderr path is
/// still authoritative.
fn emitEvent(event: PurgeEvent, scope: ?[]const u8, removed: ?u64, bytes: ?u64, dry_run: bool) void {
    if (!output.isNdjson()) return;
    var buf: [512]u8 = undefined;
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
    w.writeAll("}\n") catch return;
    output.writeStdoutAll(w.buffered());
}

/// Emit `{"event":"scope_started","scope":"<name>","dry_run":<bool>}\n`
/// when ndjson mode is on; no-op otherwise. Per-scope ndjson is one
/// summary line, not one line per item — call sites stay unchanged.
pub fn emitScopeStarted(scope: []const u8, dry_run: bool) void {
    emitEvent(.scope_started, scope, null, null, dry_run);
}

/// Emit `{"event":"scope_completed","scope":...,"removed":N,"bytes":B,"dry_run":<bool>}\n`.
pub fn emitScopeCompleted(scope: []const u8, removed: u64, bytes: u64, dry_run: bool) void {
    emitEvent(.scope_completed, scope, removed, bytes, dry_run);
}

/// Emit `{"event":"purge_complete","removed":N,"bytes":B,"dry_run":<bool>}\n`.
pub fn emitPurgeComplete(removed: u64, bytes: u64, dry_run: bool) void {
    emitEvent(.purge_complete, null, removed, bytes, dry_run);
}

/// Build + flush the `--json` summary to stdout. Allocates a transient
/// buffer because the document is unbounded in `rows.len`.
pub fn emitSummary(
    allocator: std.mem.Allocator,
    dry_run: bool,
    rows: []const report.SummaryRow,
    total_removed: u64,
    total_bytes: u64,
    time_ms: i64,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try buildSummary(&aw.writer, dry_run, rows, total_removed, total_bytes, time_ms);
    output.writeStdoutAll(aw.written());
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
    emitScopeCompleted("cache", 1, 2, false);
    emitPurgeComplete(1, 2, false);

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

    emitScopeCompleted("cache", 7, 8192, false);

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

    emitPurgeComplete(42, 1_048_576, false);

    const line = std.mem.trimEnd(u8, buf.items, "\n");
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("purge_complete", obj.get("event").?.string);
    try testing.expectEqual(@as(i64, 42), obj.get("removed").?.integer);
    try testing.expectEqual(@as(i64, 1_048_576), obj.get("bytes").?.integer);
}
