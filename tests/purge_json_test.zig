//! malt — purge --json / --output-format=ndjson integration tests.
//!
//! Drives `purge.execute` against a throwaway MALT_PREFIX and asserts the
//! stdout payload shape (keys + value types) without pinning exact
//! stringification — keeps the wire format flexible to field-order
//! changes while pinning the v1 schema fields every consumer depends on.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const output = malt.output;
const purge = malt.purge;
const purge_json = malt.purge_json;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

const ScratchPrefix = struct {
    path: [:0]u8,

    fn init(allocator: std.mem.Allocator, tag: []const u8) !ScratchPrefix {
        const ts = test_io.nanoTimestamp(std.Options.debug_io);
        const path = try std.fmt.allocPrintSentinel(
            allocator,
            "/tmp/malt_purge_json_{s}_{d}",
            .{ tag, ts },
            0,
        );
        test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
        try test_io.cwd().createDirPath(std.Options.debug_io, path);
        const db_dir = try std.fmt.allocPrint(allocator, "{s}/db", .{path});
        defer allocator.free(db_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);
        const cache_dir = try std.fmt.allocPrint(allocator, "{s}/cache", .{path});
        defer allocator.free(cache_dir);
        try test_io.cwd().createDirPath(std.Options.debug_io, cache_dir);
        _ = c.setenv("MALT_PREFIX", path.ptr, 1);
        return .{ .path = path };
    }

    fn deinit(self: *ScratchPrefix, allocator: std.mem.Allocator) void {
        _ = c.unsetenv("MALT_PREFIX");
        test_io.deleteTreeAbsolute(std.Options.debug_io, self.path) catch {};
        allocator.free(self.path);
    }
};

const OutputState = struct {
    prior_mode: output.OutputMode,
    prior_ndjson: bool,
    prior_dry: bool,
    prior_quiet: bool,

    fn save() OutputState {
        return .{
            .prior_mode = if (output.isJson()) .json else .human,
            .prior_ndjson = output.isNdjson(),
            .prior_dry = output.isDryRun(),
            .prior_quiet = output.isQuiet(),
        };
    }

    fn restore(self: OutputState) void {
        output.setMode(self.prior_mode);
        output.setNdjson(self.prior_ndjson);
        output.setDryRun(self.prior_dry);
        output.setQuiet(self.prior_quiet);
    }
};

fn makeCtx() malt.app_ctx.AppCtx {
    return .{ .io = std.Options.debug_io, .environ = .empty };
}

// ── --json summary tests ───────────────────────────────────────────────────

test "--json --housekeeping --dry-run emits a parseable v1 summary on stdout" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "house_dry");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.json);
    output.setDryRun(true);
    output.setNdjson(false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    const ctx = makeCtx();
    try purge.execute(&ctx, allocator, &[_][]const u8{"--housekeeping"});

    // Find the JSON object on stdout — leading lines may exist if
    // intermediate ndjson is off. The summary is a single object.
    const trimmed = std.mem.trim(u8, stdout_buf.items, " \r\n\t");
    try testing.expect(trimmed.len > 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;

    try testing.expectEqual(@as(i64, purge_json.schema_version), obj.get("version").?.integer);
    try testing.expectEqual(true, obj.get("dry_run").?.bool);
    try testing.expect(obj.get("scopes").? == .array);
    try testing.expect(obj.get("totals").? == .object);
    const totals = obj.get("totals").?.object;
    try testing.expect(totals.get("removed") != null);
    try testing.expect(totals.get("bytes") != null);
    try testing.expect(obj.get("time_ms") != null);
}

test "--json --wipe --dry-run emits a parseable summary with the wipe scope" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "wipe_dry");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.json);
    output.setDryRun(true);
    output.setNdjson(false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    const ctx = makeCtx();
    try purge.execute(&ctx, allocator, &[_][]const u8{ "--wipe", "--yes" });

    const trimmed = std.mem.trim(u8, stdout_buf.items, " \r\n\t");
    try testing.expect(trimmed.len > 0);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqual(true, obj.get("dry_run").?.bool);

    const scopes = obj.get("scopes").?.array;
    try testing.expectEqual(@as(usize, 1), scopes.items.len);
    try testing.expectEqualStrings("wipe", scopes.items[0].object.get("name").?.string);
}

test "--json --quiet --housekeeping keeps stdout populated, stderr silent" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "quiet");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.json);
    output.setDryRun(true);
    output.setQuiet(true);
    output.setNdjson(false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    const ctx = makeCtx();
    try purge.execute(&ctx, allocator, &[_][]const u8{"--housekeeping"});

    try testing.expect(stdout_buf.items.len > 0);
    try testing.expectEqual(@as(usize, 0), stderr_buf.items.len);

    const trimmed = std.mem.trim(u8, stdout_buf.items, " \r\n\t");
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();
    try testing.expectEqual(true, parsed.value.object.get("dry_run").?.bool);
}

// ── --output-format=ndjson tests ───────────────────────────────────────────

test "--output-format=ndjson --housekeeping emits scope events bracketed by purge_complete" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "house_ndjson");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(true);
    output.setNdjson(true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    const ctx = makeCtx();
    try purge.execute(&ctx, allocator, &[_][]const u8{"--housekeeping"});

    // Every line must parse as JSON; vocabulary stays inside the
    // PurgeEvent enum so any rename surfaces in the parser.
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, stdout_buf.items, "\n"), '\n');
    var scope_started: usize = 0;
    var scope_completed: usize = 0;
    var purge_complete_seen: bool = false;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const event = parsed.value.object.get("event").?.string;
        if (std.mem.eql(u8, event, "scope_started")) scope_started += 1;
        if (std.mem.eql(u8, event, "scope_completed")) scope_completed += 1;
        if (std.mem.eql(u8, event, "purge_complete")) purge_complete_seen = true;
    }
    try testing.expect(scope_started > 0);
    try testing.expectEqual(scope_started, scope_completed);
    try testing.expect(purge_complete_seen);

    // purge_complete must be the closing line so consumers can rely on
    // a strict bracket — find its byte offset and check it trails
    // every scope_completed event.
    const close_pos = std.mem.indexOf(u8, stdout_buf.items, "\"event\":\"purge_complete\"").?;
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, stdout_buf.items, search_start, "\"event\":\"scope_completed\"")) |pos| {
        try testing.expect(pos < close_pos);
        search_start = pos + 1;
    }
}

test "--output-format=ndjson --wipe emits a wipe scope event" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "wipe_ndjson");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(true);
    output.setNdjson(true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    const ctx = makeCtx();
    try purge.execute(&ctx, allocator, &[_][]const u8{ "--wipe", "--yes" });

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"scope\":\"wipe\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"event\":\"purge_complete\"") != null);
}

test "ndjson stream stays bracketed when --wipe is aborted at confirm" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "wipe_abort");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(false);
    output.setNdjson(true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    // No --yes, stdin not a TTY → confirmScope returns Error.UserAborted.
    // The ndjson stream must still close out with scope_completed +
    // purge_complete so consumers can rely on strict bracketing.
    const ctx = makeCtx();
    const rc = purge.execute(&ctx, allocator, &[_][]const u8{"--wipe"});
    try testing.expectError(purge.Error.UserAborted, rc);

    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"event\":\"scope_started\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"event\":\"scope_completed\"") != null);
    try testing.expect(std.mem.indexOf(u8, stdout_buf.items, "\"event\":\"purge_complete\"") != null);
}

test "wipe dry-run removed count matches the live freed-path semantic" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "wipe_count");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.json);
    output.setDryRun(true);
    output.setNdjson(false);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    // Fresh prefix has only `db/` and `cache/` (created by ScratchPrefix);
    // every other plan target is missing on disk, so `removed` reports
    // only the targets that pre-existed — not plan.len.
    const ctx = makeCtx();
    try purge.execute(&ctx, allocator, &[_][]const u8{ "--wipe", "--yes" });

    const trimmed = std.mem.trim(u8, stdout_buf.items, " \r\n\t");
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();
    const removed = parsed.value.object.get("totals").?.object.get("removed").?.integer;
    // Two pre-existing targets: db, cache (and the prefix root itself).
    try testing.expect(removed >= 2);
    try testing.expect(removed < 14);
}

test "corrupt database surfaces a real error, not the soft no-db skip" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "corrupt_db");
    defer prefix.deinit(allocator);

    // Pre-populate {prefix}/db/malt.db with random bytes so SQLite's
    // header check rejects it. This must take the .unreadable branch
    // and log a loud err, not the soft "no database" path.
    const db_path = try std.fmt.allocPrint(allocator, "{s}/db/malt.db", .{prefix.path});
    defer allocator.free(db_path);
    {
        const f = try test_io.createFileAbsolute(std.Options.debug_io, db_path, .{ .truncate = true });
        defer f.close(std.Options.debug_io);
        try f.writeStreamingAll(std.Options.debug_io, "this is not a valid sqlite header, just garbage to trip the open path");
    }

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(true);
    output.setNdjson(false);
    output.setQuiet(false);

    var stderr_buf: std.ArrayList(u8) = .empty;
    defer stderr_buf.deinit(allocator);
    output.beginStderrCapture(allocator, &stderr_buf);
    defer output.endStderrCapture();

    const ctx = makeCtx();
    try purge.execute(&ctx, allocator, &[_][]const u8{"--store-orphans"});

    // Must NOT take the soft skip path.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "no database — nothing to inspect") == null);
    // Must surface the real error so the user can investigate.
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "cannot open database") != null);
    try testing.expect(std.mem.indexOf(u8, stderr_buf.items, "store-orphans") != null);
}

test "ndjson scope_completed carries removed/bytes counters" {
    const allocator = testing.allocator;
    var prefix = try ScratchPrefix.init(allocator, "counters");
    defer prefix.deinit(allocator);

    const prior = OutputState.save();
    defer prior.restore();
    output.setMode(.human);
    output.setDryRun(true);
    output.setNdjson(true);

    var stdout_buf: std.ArrayList(u8) = .empty;
    defer stdout_buf.deinit(allocator);
    output.beginStdoutCapture(allocator, &stdout_buf);
    defer output.endStdoutCapture();

    const ctx = makeCtx();
    try purge.execute(&ctx, allocator, &[_][]const u8{"--housekeeping"});

    // At least one scope_completed line must contain both counters,
    // even if the values are zero — the keys are part of the contract.
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, stdout_buf.items, "\n"), '\n');
    var saw_completed_with_counters = false;
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"event\":\"scope_completed\"") == null) continue;
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        try testing.expect(obj.get("removed") != null);
        try testing.expect(obj.get("bytes") != null);
        try testing.expect(obj.get("dry_run") != null);
        saw_completed_with_counters = true;
    }
    try testing.expect(saw_completed_with_counters);
}
