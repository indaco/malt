//! malt — `--output-format=ndjson` integration tests
//!
//! Pins the event vocabulary for the 9-step install protocol and the
//! bracketing protocol events that wrap upgrade and migrate. The test
//! drives the public emit helper directly to keep the integration surface
//! small — the real install/upgrade/migrate flows funnel every transition
//! through the same `output.emitNdjsonEvent` call site, so vocabulary
//! coverage here pins the contract every command must honour.

const std = @import("std");
const malt = @import("malt");
const test_io = @import("test_io");
const testing = std.testing;
const output = malt.output;
const io_mod = malt.output;
const upgrade = malt.upgrade;

const c = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;
};

/// One stable name per step in the 9-step install protocol described in
/// the README. Locking these in a slice forces a compile-time review when
/// a new step (or rename) lands; consumers parse by event name, so churn
/// here is a breaking change for them.
///
/// Two ordering notes for consumers:
///   - For a single-package install, events arrive in this exact order.
///   - For a multi-package install (e.g. `mt install wget` with deps),
///     the pool runs download + materialise per keg, then emits the
///     four pool events (downloaded/extracted/stored/materialized) for
///     each keg in jobs order from the main thread. Link and recorded
///     events follow per keg from the serial link phase. Each event
///     carries `name` so consumers group by it instead of relying on
///     strict per-package linearity.
const install_step_events = [_]output.NdjsonEvent{
    .lock_acquired,
    .resolved,
    .downloaded,
    .extracted,
    .stored,
    .materialized,
    .linked,
    .recorded,
    .install_complete,
};

fn setNdjsonOn() bool {
    const prior = output.isNdjson();
    output.setNdjson(true);
    return prior;
}

fn restoreNdjson(prior: bool) void {
    output.setNdjson(prior);
}

test "9-step install protocol emits one ndjson line per step" {
    const prior = setNdjsonOn();
    defer restoreNdjson(prior);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    // Drive each protocol step through the same helper the real
    // commands use so the line shape is the one consumers will see.
    output.emitNdjsonEvent(.lock_acquired, "", null);
    output.emitNdjsonEvent(.resolved, "wget", null);
    output.emitNdjsonEvent(.downloaded, "wget", "ok");
    output.emitNdjsonEvent(.extracted, "wget", "ok");
    output.emitNdjsonEvent(.stored, "wget", "ok");
    output.emitNdjsonEvent(.materialized, "wget", "ok");
    output.emitNdjsonEvent(.linked, "wget", "ok");
    output.emitNdjsonEvent(.recorded, "wget", "ok");
    output.emitNdjsonEvent(.install_complete, "", null);

    // Exactly one line per step — no fan-out, no dropped events.
    try testing.expectEqual(install_step_events.len, std.mem.count(u8, buf.items, "\n"));

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf.items, "\n"), '\n');
    var idx: usize = 0;
    while (lines.next()) |line| : (idx += 1) {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, line, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(
            @tagName(install_step_events[idx]),
            parsed.value.object.get("event").?.string,
        );
    }
    try testing.expectEqual(install_step_events.len, idx);
}

test "ndjson off emits zero events for the same call sequence" {
    const prior = output.isNdjson();
    defer restoreNdjson(prior);
    output.setNdjson(false);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    for (install_step_events) |ev| {
        output.emitNdjsonEvent(ev, "wget", "ok");
    }
    try testing.expectEqualStrings("", buf.items);
}

test "every NdjsonEvent variant emits a parser-clean line" {
    // Walk the enum exhaustively so adding a variant without testing it
    // surfaces here rather than as a missed event in production.
    const prior = setNdjsonOn();
    defer restoreNdjson(prior);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    inline for (std.meta.tags(output.NdjsonEvent)) |ev| {
        output.emitNdjsonEvent(ev, "wget", null);
    }

    const total: usize = std.meta.tags(output.NdjsonEvent).len;
    try testing.expectEqual(total, std.mem.count(u8, buf.items, "\n"));
}

test "no-op skip event names are stable across mutating commands" {
    // Pin every "no transition happened" event variant. These emit on
    // idempotent / refused paths so consumers can tell "skipped by policy"
    // from "command never ran".
    const skip_events = [_]output.NdjsonEvent{
        .already_installed, // install fast-path
        .would_install, // dry-run install / upgrade / migrate
        .up_to_date, // upgrade detects no version drift
        .pinned, // upgrade refuses a pinned package
    };
    const prior = setNdjsonOn();
    defer restoreNdjson(prior);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    for (skip_events) |ev| output.emitNdjsonEvent(ev, "wget", null);

    try testing.expectEqual(skip_events.len, std.mem.count(u8, buf.items, "\n"));
    // No status field on any of them — these are no-transition events.
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"status\"") == null);
    for (skip_events) |ev| {
        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "\"event\":\"{s}\"", .{@tagName(ev)});
        try testing.expect(std.mem.indexOf(u8, buf.items, needle) != null);
    }
}

test "would_install and already_installed are stable side-channel event names" {
    // Pin the two non-protocol event names so changes here surface as
    // a compile-test diff. `would_install` is the dry-run signal,
    // `already_installed` is the idempotent fast-path signal — each
    // intentionally omits `status` because no transition outcome
    // exists.
    const prior = setNdjsonOn();
    defer restoreNdjson(prior);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    output.emitNdjsonEvent(.would_install, "wget", null);
    output.emitNdjsonEvent(.already_installed, "tree", null);

    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, buf.items, "\n"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"event\":\"would_install\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"name\":\"wget\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"event\":\"already_installed\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"name\":\"tree\"") != null);
    // No status field on either event.
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"status\"") == null);
}

test "upgrade emits bracketing lock_acquired + install_complete under ndjson" {
    // A fake MALT_PREFIX with an empty DB lets `upgrade.execute` run
    // through lock acquire → "no formulas installed" → release without
    // touching the network. The test pins the bracketing events so the
    // ndjson stream stays well-formed even when no work is done.
    const path = try std.fmt.allocPrintSentinel(
        testing.allocator,
        "/tmp/malt_ndjson_upgrade_{d}",
        .{test_io.nanoTimestamp(
            std.Options.debug_io,
        )},
        0,
    );
    defer testing.allocator.free(path);
    test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    defer test_io.deleteTreeAbsolute(std.Options.debug_io, path) catch {};
    try test_io.cwd().createDirPath(std.Options.debug_io, path);
    _ = c.setenv("MALT_PREFIX", path.ptr, 1);
    defer _ = c.unsetenv("MALT_PREFIX");

    const db_dir = try std.fmt.allocPrint(testing.allocator, "{s}/db", .{path});
    defer testing.allocator.free(db_dir);
    try test_io.cwd().createDirPath(std.Options.debug_io, db_dir);

    const prior = setNdjsonOn();
    defer restoreNdjson(prior);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    io_mod.beginStdoutCapture(testing.allocator, &buf);
    defer io_mod.endStdoutCapture();

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const ctx: malt.app_ctx.AppCtx = .{ .io = threaded.io(), .environ = .empty };
    try upgrade.execute(&ctx, testing.allocator, &.{});

    try testing.expect(std.mem.indexOf(u8, buf.items, "\"event\":\"lock_acquired\"") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "\"event\":\"install_complete\"") != null);
    // install_complete must trail lock_acquired so consumers can rely on
    // a strict open/close bracket.
    const open_pos = std.mem.indexOf(u8, buf.items, "\"event\":\"lock_acquired\"").?;
    const close_pos = std.mem.indexOf(u8, buf.items, "\"event\":\"install_complete\"").?;
    try testing.expect(close_pos > open_pos);
}
