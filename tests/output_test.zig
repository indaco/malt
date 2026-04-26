//! malt — ui/output tests
//! Pinpoint coverage for `output.jsonStr`, the helper every CLI command uses
//! to emit JSON-safe string values. Verifies the RFC 8259 escape contract on
//! adversarial inputs and round-trips the result through std.json to prove
//! the bytes are accepted by a strict parser.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const output = malt.output;
const io_mod = malt.io_mod;
const color = malt.color;

/// Set up stderr capture with an explicit color/emoji state. Returns a
/// guard the caller defers to tear down both the capture and the state
/// override — keeps each byte-level assertion below a single assertion
/// in length.
const Capture = struct {
    buf: *std.ArrayList(u8),
    prior_quiet: bool,

    fn init(buf: *std.ArrayList(u8), color_on: bool, emoji_on: bool, quiet: bool) Capture {
        const prior_quiet = output.isQuiet();
        color.setForTest(color_on, emoji_on);
        // Pin the palette so escape-string assertions below stay
        // deterministic regardless of the host terminal.
        color.setBackgroundForTest(color.Background.dark);
        color.setTruecolorForTest(false);
        output.setQuiet(quiet);
        io_mod.beginStderrCapture(testing.allocator, buf);
        return .{ .buf = buf, .prior_quiet = prior_quiet };
    }

    fn deinit(self: Capture) void {
        io_mod.endStderrCapture();
        color.setForTest(null, null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
        output.setQuiet(self.prior_quiet);
    }
};

fn encode(s: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try output.jsonStr(&aw.writer, s);
    return aw.toOwnedSlice();
}

test "jsonStr leaves plain ASCII alone" {
    const got = try encode("openssl@3");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"openssl@3\"", got);
}

test "jsonStr emits empty quoted string for empty input" {
    const got = try encode("");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"\"", got);
}

test "jsonStr escapes the seven RFC 8259 short-form characters" {
    const got = try encode("a\"b\\c\nd\re\tf\x08g\x0ch");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\re\\tf\\bg\\fh\"", got);
}

test "jsonStr emits \\u00XX for control characters below 0x20" {
    const got = try encode("\x01\x1f");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"\\u0001\\u001f\"", got);
}

test "jsonStr passes UTF-8 bytes through unchanged" {
    // emoji, accented letter — outside the escape set, must round-trip.
    const got = try encode("café 🍺");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\"café 🍺\"", got);
}

// ── jsonStringArray: shared `["a","b",...]` writer ─────────────────────

fn encodeArray(items: []const []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try output.jsonStringArray(&aw.writer, items);
    return aw.toOwnedSlice();
}

test "jsonStringArray writes [] for an empty slice" {
    const got = try encodeArray(&.{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[]", got);
}

test "jsonStringArray writes a single-quoted element with no separator" {
    const got = try encodeArray(&.{"tree"});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[\"tree\"]", got);
}

test "jsonStringArray comma-separates multiple elements without trailing comma" {
    const got = try encodeArray(&.{ "tree", "wget", "jq" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[\"tree\",\"wget\",\"jq\"]", got);
}

test "jsonStringArray delegates per-element escaping to jsonStr" {
    const got = try encodeArray(&.{ "a\"b", "c\\d", "e\nf" });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[\"a\\\"b\",\"c\\\\d\",\"e\\nf\"]", got);
}

test "jsonStringArray round-trips through std.json" {
    const got = try encodeArray(&.{ "tree", "café 🍺", "weird\"name" });
    defer testing.allocator.free(got);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, got, .{});
    defer parsed.deinit();
    const arr = parsed.value.array;
    try testing.expectEqual(@as(usize, 3), arr.items.len);
    try testing.expectEqualStrings("tree", arr.items[0].string);
    try testing.expectEqualStrings("café 🍺", arr.items[1].string);
    try testing.expectEqualStrings("weird\"name", arr.items[2].string);
}

test "jsonStringArray handles an element containing every short-form escape" {
    const got = try encodeArray(&.{"a\"b\\c\nd\re\tf\x08g\x0ch"});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[\"a\\\"b\\\\c\\nd\\re\\tf\\bg\\fh\"]", got);
}

// ── jsonTimeSuffix: shared `,"time_ms":N` tail ─────────────────────────

fn encodeTimeSuffix(start_ts: i64) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer aw.deinit();
    try output.jsonTimeSuffix(&aw.writer, start_ts);
    return aw.toOwnedSlice();
}

test "jsonTimeSuffix starts with the literal key prefix" {
    const got = try encodeTimeSuffix(0);
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, ",\"time_ms\":"));
}

test "jsonTimeSuffix emits a non-negative integer for a past start_ts" {
    // A milliTimestamp() captured just above is by definition ≤ the one
    // fetched inside the helper, so the diff cannot be negative.
    const start = malt.fs_compat.milliTimestamp();
    const got = try encodeTimeSuffix(start);
    defer testing.allocator.free(got);

    const colon = std.mem.indexOfScalar(u8, got, ':').?;
    const num_str = got[colon + 1 ..];
    const n = try std.fmt.parseInt(i64, num_str, 10);
    try testing.expect(n >= 0);
}

test "jsonTimeSuffix produces a large elapsed value for a far-past start_ts" {
    const now = malt.fs_compat.milliTimestamp();
    const got = try encodeTimeSuffix(now - 1_000_000);
    defer testing.allocator.free(got);

    const colon = std.mem.indexOfScalar(u8, got, ':').?;
    const n = try std.fmt.parseInt(i64, got[colon + 1 ..], 10);
    try testing.expect(n >= 1_000_000);
}

test "jsonTimeSuffix composes onto an open object to yield valid JSON" {
    // Real callers concatenate the suffix onto a partial `{...` payload;
    // exercise that assembly here to prove a consumer can parse the join.
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"ok\":true");
    try output.jsonTimeSuffix(&aw.writer, 0);
    try aw.writer.writeAll("}");

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("ok").?.bool);
    try testing.expect(parsed.value.object.get("time_ms").?.integer >= 0);
}

// Regression: under the test runner, `io_mod.stdoutFile()` must not
// resolve to fd 1. The runner owns fd 1 for its IPC; any byte on it
// wedges the build runner in `read()`. If this assertion breaks,
// `zig build test` starts deadlocking again.
test "stdoutFile is not fd 1 under the test runner" {
    try testing.expect(io_mod.stdoutFile().handle != std.Io.File.stdout().handle);
}

// Regression (paired with the helper above): exercising a call site that
// previously deadlocked — `stdoutWriteAll` of a multi-KB payload — must
// complete without hanging.
test "stdoutWriteAll through the redirected path completes without blocking" {
    var buf: [4096]u8 = undefined;
    @memset(&buf, 'x');
    io_mod.stdoutWriteAll(&buf);
}

// ---------------------------------------------------------------------------
// Prefixed-line helpers — byte-level contract.
//
// Under the test runner, stderr is funneled to /dev/null (see `io_mod`).
// The `Capture` guard above swaps in an in-memory buffer so each emit can
// be asserted at the byte level — including the ANSI wrap shape, which
// differs between the prefix-only helpers (info/warn/success/err) and the
// full-line helpers (dim/skip). Keeping these locked down guards against
// accidental style regressions when the helpers are tweaked.
// ---------------------------------------------------------------------------

test "info wraps only the emoji prefix in cyan; msg stays unstyled" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, true, true, false);
    defer cap.deinit();

    output.info("hello {s}", .{"world"});
    try testing.expectEqualStrings("\x1b[36m  ▸ \x1b[0mhello world\n", buf.items);
}

test "info falls back to ASCII prefix with color and emoji disabled" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, false, false, false);
    defer cap.deinit();

    output.info("plain", .{});
    try testing.expectEqualStrings("  > plain\n", buf.items);
}

test "info is suppressed by --quiet" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, true, true, true);
    defer cap.deinit();

    output.info("hidden", .{});
    try testing.expectEqualStrings("", buf.items);
}

test "warn wraps the yellow prefix and uses the warning glyph" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, true, true, false);
    defer cap.deinit();

    output.warn("careful", .{});
    try testing.expectEqualStrings("\x1b[33m  ⚠ \x1b[0mcareful\n", buf.items);
}

test "success wraps the green prefix and uses the check glyph" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, true, true, false);
    defer cap.deinit();

    output.success("done", .{});
    try testing.expectEqualStrings("\x1b[32m  ✓ \x1b[0mdone\n", buf.items);
}

test "err wraps the red prefix and uses the cross glyph" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, true, true, false);
    defer cap.deinit();

    output.err("nope", .{});
    try testing.expectEqualStrings("\x1b[31m  ✗ \x1b[0mnope\n", buf.items);
}

// `question` prints a confirmation-style prompt: cyan `?` icon, bold msg,
// no trailing newline so the user types directly after the colon.
test "question wraps the cyan prefix and bold msg without a newline" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, true, true, false);
    defer cap.deinit();

    output.question("Replace {s}? ", .{"foo"});
    try testing.expectEqualStrings(
        "\x1b[36m  ? \x1b[0m\x1b[1mReplace foo? \x1b[0m",
        buf.items,
    );
}

test "question falls back to ASCII prefix without color or emoji" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, false, false, false);
    defer cap.deinit();

    output.question("Continue? ", .{});
    try testing.expectEqualStrings("  ? Continue? ", buf.items);
}

// Prompts must always render; --quiet only silences informational chatter.
// If `quiet` ever swallowed `question`, confirmTyped would block on a
// hidden prompt and the user would think malt hung.
test "question is NOT suppressed by --quiet" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, false, false, true);
    defer cap.deinit();

    output.question("Confirm? ", .{});
    try testing.expectEqualStrings("  ? Confirm? ", buf.items);
}

// Contract: errors always print, even under `--quiet`. If this ever flips,
// users will stop seeing failure reasons when they pass `-q` to scripts.
test "err is NOT suppressed by --quiet" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, false, false, true);
    defer cap.deinit();

    output.err("boom", .{});
    try testing.expectEqualStrings("  x boom\n", buf.items);
}

// `dim` and `skip` are full-line wrappers — the dim ANSI must span the
// whole line (prefix + msg) rather than just the prefix, so the entire
// line visually recedes.
test "dim wraps prefix and msg in a single dim ANSI block" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, true, true, false);
    defer cap.deinit();

    output.dim("background", .{});
    try testing.expectEqualStrings("\x1b[2m  ▸ background\x1b[0m\n", buf.items);
}

test "skip uses the bullet glyph and wraps the whole line in dim" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, true, true, false);
    defer cap.deinit();

    output.skip("{s} is already at latest version {s}", .{ "ripgrep", "14.1.1" });
    try testing.expectEqualStrings(
        "\x1b[2m  · ripgrep is already at latest version 14.1.1\x1b[0m\n",
        buf.items,
    );
}

test "skip falls back to ASCII dot when emoji is disabled" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, false, false, false);
    defer cap.deinit();

    output.skip("fd is already at latest version 10.2.0", .{});
    try testing.expectEqualStrings("  . fd is already at latest version 10.2.0\n", buf.items);
}

test "skip is suppressed by --quiet" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, true, true, true);
    defer cap.deinit();

    output.skip("hidden", .{});
    try testing.expectEqualStrings("", buf.items);
}

// Emoji off + color on is a real combination: NO_COLOR unset but
// MALT_NO_EMOJI set. Make sure the ANSI wrap still lands around the
// ASCII prefix (no accidental double-styling or missing reset).
test "info emits ANSI around the ASCII prefix when only emoji is disabled" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, true, false, false);
    defer cap.deinit();

    output.info("mixed", .{});
    try testing.expectEqualStrings("\x1b[36m  > \x1b[0mmixed\n", buf.items);
}

test "jsonStr output round-trips through std.json parser" {
    const inputs = [_][]const u8{
        "name with \"quote\"",
        "C:\\path\\to\\file",
        "line\nbreak",
        "\t\rmixed\x05controls",
        "",
        "café 🍺",
    };
    for (inputs) |s| {
        const encoded = try encode(s);
        defer testing.allocator.free(encoded);

        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, encoded, .{});
        defer parsed.deinit();
        try testing.expectEqualStrings(s, parsed.value.string);
    }
}
