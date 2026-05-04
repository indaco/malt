//! malt — purge output tests
//! Exercises the sectioned Reporter + Summary table via the stderr-capture
//! seam in `ui/output.zig`. These cover behaviour that pure unit tests in
//! `cli/purge/report.zig` cannot: header/item/footer formatting, the cap +
//! "… N more" tail, the verbose bypass, and the aligned summary table.

const std = @import("std");
const testing = std.testing;
const malt = @import("malt");
const output = malt.output;
const color = malt.color;
const report = malt.purge_report;

const Capture = struct {
    buf: *std.ArrayList(u8),
    prior_quiet: bool,
    prior_verbose: bool,

    fn init(buf: *std.ArrayList(u8), opts: struct {
        color_on: bool = false,
        emoji_on: bool = false,
        verbose: bool = false,
        quiet: bool = false,
    }) Capture {
        const prior_quiet = output.isQuiet();
        const prior_verbose = output.isVerbose();
        color.setForTest(opts.color_on, opts.emoji_on);
        color.setBackgroundForTest(color.Background.dark);
        color.setTruecolorForTest(false);
        output.setQuiet(opts.quiet);
        output.setVerbose(opts.verbose);
        output.beginStderrCapture(testing.allocator, buf);
        return .{ .buf = buf, .prior_quiet = prior_quiet, .prior_verbose = prior_verbose };
    }

    fn deinit(self: Capture) void {
        output.endStderrCapture();
        color.setForTest(null, null);
        color.setBackgroundForTest(null);
        color.setTruecolorForTest(null);
        output.setQuiet(self.prior_quiet);
        output.setVerbose(self.prior_verbose);
    }
};

fn newBuf() std.ArrayList(u8) {
    return .empty;
}

// ── Reporter.header ─────────────────────────────────────────────────────────

test "header singular vs plural noun is selected by count" {
    var buf = newBuf();
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, .{});
    defer cap.deinit();

    var rep = report.Reporter.init("unused-deps", false);
    rep.header(1, "package", "packages");
    rep.header(10, "package", "packages");

    try testing.expect(std.mem.indexOf(u8, buf.items, "removing 1 package\n") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "removing 10 packages\n") != null);
}

test "header reads 'would remove' under dry-run" {
    var buf = newBuf();
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, .{});
    defer cap.deinit();

    var rep = report.Reporter.init("store-orphans", true);
    rep.header(3, "entry", "entries");

    try testing.expect(std.mem.indexOf(u8, buf.items, "would remove 3 entries") != null);
    // Defensive: dry-run path must not say "removing".
    try testing.expect(std.mem.indexOf(u8, buf.items, "removing 3") == null);
}

// ── Reporter.item + cap ─────────────────────────────────────────────────────

test "item caps the listed entries at default_item_cap and prints the more line" {
    var buf = newBuf();
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, .{});
    defer cap.deinit();

    var rep = report.Reporter.init("store-orphans", false);
    rep.fmt = .short_hash;

    const total: usize = 15;
    var i: usize = 0;
    while (i < total) : (i += 1) {
        // 64-char hex, distinct first 12 nibbles per item.
        var sha: [64]u8 = undefined;
        @memset(&sha, '0');
        const hexd = "0123456789abcdef";
        sha[0] = hexd[i & 0xf];
        sha[1] = hexd[(i >> 4) & 0xf];
        rep.item(&sha);
    }
    rep.done(total);

    // Every printed item line uses the bullet glyph; under emoji-off it's '-'.
    var lines = std.mem.splitScalar(u8, buf.items, '\n');
    var bullets: usize = 0;
    while (lines.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "    - ") != null) bullets += 1;
    }
    try testing.expectEqual(@as(usize, report.default_item_cap), bullets);

    // Tail line names the remaining count.
    try testing.expect(std.mem.indexOf(u8, buf.items, "… 5 more") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "use --verbose") != null);
}

test "verbose mode bypasses the cap and prints every item" {
    var buf = newBuf();
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, .{ .verbose = true });
    defer cap.deinit();

    var rep = report.Reporter.init("unused-deps", false);
    const names = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l" };
    for (names) |n| rep.item(n);
    rep.done(names.len);

    var lines = std.mem.splitScalar(u8, buf.items, '\n');
    var bullets: usize = 0;
    while (lines.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "    - ") != null) bullets += 1;
    }
    try testing.expectEqual(@as(usize, names.len), bullets);
    try testing.expect(std.mem.indexOf(u8, buf.items, "more (use --verbose") == null);
}

test "short_hash item format truncates long SHAs but leaves short labels alone" {
    var buf = newBuf();
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, .{});
    defer cap.deinit();

    var rep = report.Reporter.init("store-orphans", false);
    rep.fmt = .short_hash;
    rep.item("f81449aaecf0d71e3679c230904eaaf746b2fc61b3186870a8c2f33e38eb8404");
    rep.item("short");

    try testing.expect(std.mem.indexOf(u8, buf.items, "    - f81449aaecf0…\n") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "    - short\n") != null);
    // Full SHA must NOT leak when the format asks for short hashes.
    try testing.expect(std.mem.indexOf(u8, buf.items, "f81449aaecf0d71e3679c230904eaaf7") == null);
}

// ── Reporter.empty / note ───────────────────────────────────────────────────

test "empty emits a dim 'nothing to remove' line under the scope name" {
    var buf = newBuf();
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, .{});
    defer cap.deinit();

    var rep = report.Reporter.init("stale-casks", false);
    rep.empty("nothing to remove");

    try testing.expect(std.mem.indexOf(u8, buf.items, "stale-casks: nothing to remove") != null);
}

// ── Summary table ──────────────────────────────────────────────────────────

test "Summary.render emits one row per scope plus a total line" {
    var buf = newBuf();
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, .{});
    defer cap.deinit();

    var summary = report.Summary{};
    defer summary.deinit(testing.allocator);

    try summary.add(testing.allocator, .{ .name = "unused-deps", .removed = 10, .bytes = 2 * 1024 * 1024 * 1024 });
    try summary.add(testing.allocator, .{ .name = "store-orphans", .removed = 57, .bytes = 1024 * 1024 });
    try summary.add(testing.allocator, .{ .name = "cache", .removed = 0, .bytes = 0 });

    summary.render();

    try testing.expect(std.mem.indexOf(u8, buf.items, "Summary") != null);
    // Each scope name appears as a row.
    try testing.expect(std.mem.indexOf(u8, buf.items, "unused-deps") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "store-orphans") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "cache") != null);
    // Total row carries the summed count (10 + 57 + 0 = 67) and a bytes value.
    try testing.expect(std.mem.indexOf(u8, buf.items, "total") != null);
    try testing.expect(std.mem.indexOf(u8, buf.items, "67") != null);
    // Two rule lines bracket the body.
    var rules: usize = 0;
    var lines = std.mem.splitScalar(u8, buf.items, '\n');
    while (lines.next()) |ln| {
        if (std.mem.indexOf(u8, ln, "----------") != null) rules += 1;
    }
    try testing.expectEqual(@as(usize, 2), rules);
}

// ── --quiet propagation ─────────────────────────────────────────────────────

test "quiet mode silences items, the more-hint, and the summary table" {
    var buf = newBuf();
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, .{ .quiet = true });
    defer cap.deinit();

    var rep = report.Reporter.init("store-orphans", false);
    rep.fmt = .short_hash;
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        var sha: [64]u8 = undefined;
        @memset(&sha, '0');
        sha[0] = 'a';
        sha[1] = '0' + @as(u8, @intCast(i % 10));
        rep.item(&sha);
    }
    rep.done(15);

    var summary = report.Summary{};
    defer summary.deinit(testing.allocator);
    try summary.add(testing.allocator, .{ .name = "store-orphans", .removed = 15, .bytes = 1024 });
    summary.render();

    // Nothing should reach stderr under --quiet — neither the bullets
    // (writeItem) nor the truncation hint (writeMore) nor the table rules
    // (writeRule) may bypass the quiet flag.
    try testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "Summary.render is a no-op when no rows were added" {
    var buf = newBuf();
    defer buf.deinit(testing.allocator);
    const cap = Capture.init(&buf, .{});
    defer cap.deinit();

    var summary = report.Summary{};
    defer summary.deinit(testing.allocator);
    summary.render();

    try testing.expectEqual(@as(usize, 0), buf.items.len);
}
