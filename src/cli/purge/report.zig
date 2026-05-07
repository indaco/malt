//! malt — purge per-scope sectioned reporter.
//! Each scope feeds: header → items → done.  The reporter caps long
//! lists, truncates SHAs, and the orchestrator collects subtotals into
//! a `Summary` so the final table reads at a glance.

const std = @import("std");
const output = @import("../../ui/output.zig");
const color = @import("../../ui/color.zig");
const util = @import("util.zig");

/// Item-list cap; bypassed by `--verbose`.  Picked to fit a half-screen
/// in a typical 24-row terminal alongside the header + footer.
pub const default_item_cap: usize = 10;
/// Matches git/docker/nix short-ref convention; long enough to stay
/// unambiguous against current store sizes.
pub const short_hash_len: usize = 12;

/// `name` is borrowed from a caller-owned literal (scope label) — no
/// allocation needed.
pub const SummaryRow = struct {
    name: []const u8,
    removed: u32,
    bytes: u64,
    status: util.ScopeStatus = .ok,
    error_kind: ?[]const u8 = null,
};

pub const Summary = struct {
    rows: std.ArrayList(SummaryRow) = .empty,

    pub fn add(self: *Summary, allocator: std.mem.Allocator, row: SummaryRow) !void {
        try self.rows.append(allocator, row);
    }

    pub fn deinit(self: *Summary, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
    }

    pub fn isEmpty(self: *const Summary) bool {
        return self.rows.items.len == 0;
    }

    pub fn render(self: *const Summary) void {
        renderTable(self.rows.items);
    }
};

/// Pass both forms so irregular nouns ("entry"/"entries") stay at the
/// call site instead of being baked into a lookup here.
pub fn pluralize(n: usize, singular: []const u8, plural: []const u8) []const u8 {
    return if (n == 1) singular else plural;
}

/// Returns the input slice when it already fits, so callers can route
/// every value through this helper without a length check.
pub fn shortHash(sha: []const u8, buf: []u8) []const u8 {
    if (sha.len <= short_hash_len) return sha;
    const ell = "…"; // 3 bytes UTF-8
    std.debug.assert(buf.len >= short_hash_len + ell.len);
    @memcpy(buf[0..short_hash_len], sha[0..short_hash_len]);
    @memcpy(buf[short_hash_len..][0..ell.len], ell);
    return buf[0 .. short_hash_len + ell.len];
}

pub const ItemFormat = enum { plain, short_hash };

pub const Reporter = struct {
    scope: []const u8,
    dry_run: bool,
    verbose: bool,
    item_cap: usize = default_item_cap,
    fmt: ItemFormat = .plain,
    seen: usize = 0,

    pub fn init(scope: []const u8, dry_run: bool) Reporter {
        return .{
            .scope = scope,
            .dry_run = dry_run,
            .verbose = output.isVerbose(),
        };
    }

    /// Header reads "scope: removing N <noun>" — the dry-run/live wording
    /// split lives here so call sites don't repeat it.
    pub fn header(self: *const Reporter, count: usize, singular: []const u8, plural: []const u8) void {
        const noun = pluralize(count, singular, plural);
        if (self.dry_run) {
            output.info("{s}: would remove {d} {s}", .{ self.scope, count, noun });
        } else {
            output.info("{s}: removing {d} {s}", .{ self.scope, count, noun });
        }
    }

    /// Dim "nothing to do" line so empty scopes recede next to active ones.
    pub fn empty(self: *const Reporter, message: []const u8) void {
        output.skip("{s}: {s}", .{ self.scope, message });
    }

    /// Status line for sections that work without per-item trace
    /// (cache pruning announces its window before it walks).
    /// Buffer matches `output.info`'s 4096B so a long `cache_dir`
    /// passed by `runCache` doesn't silently drop the header.
    pub fn note(self: *const Reporter, comptime fmt: []const u8, args: anytype) void {
        var buf: [4096]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        output.info("{s}: {s}", .{ self.scope, msg });
    }

    pub fn item(self: *Reporter, label: []const u8) void {
        defer self.seen += 1;
        if (!self.verbose and self.seen >= self.item_cap) return;
        var buf: [128]u8 = undefined;
        const text: []const u8 = switch (self.fmt) {
            .plain => label,
            .short_hash => shortHash(label, &buf),
        };
        writeItem(text);
    }

    /// Emits the "… N more" hint when items were clipped.  Subtotal
    /// bookkeeping happens in the orchestrator; the reporter is print-only.
    pub fn done(self: *const Reporter, total_seen: usize) void {
        if (!self.verbose and total_seen > self.item_cap) {
            writeMore(total_seen - self.item_cap);
        }
    }
};

fn writeItem(text: []const u8) void {
    if (output.isQuiet()) return; // raw stderr writes don't honour --quiet on their own
    const bullet: []const u8 = if (color.isEmojiEnabled()) "    • " else "    - ";
    if (color.isColorEnabled()) {
        output.writeStderrAll(color.SemanticStyle.detail.code());
        output.writeStderrAll(bullet);
        output.writeStderrAll(color.Style.reset.code());
    } else {
        output.writeStderrAll(bullet);
    }
    output.writeStderrAll(text);
    output.writeStderrAll("\n");
}

fn writeMore(remaining: usize) void {
    if (output.isQuiet()) return;
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "    … {d} more (use --verbose to show all)",
        .{remaining},
    ) catch return;
    if (color.isColorEnabled()) {
        output.writeStderrAll(color.SemanticStyle.detail.code());
        output.writeStderrAll(msg);
        output.writeStderrAll(color.Style.reset.code());
    } else {
        output.writeStderrAll(msg);
    }
    output.writeStderrAll("\n");
}

// ── Summary table rendering ────────────────────────────────────────────────
// Fixed widths instead of dynamic ones: the layout is more predictable and
// the longest scope label today ("store-orphans", 13 chars) fits comfortably.

const name_col: usize = 16;
const count_col: usize = 6;
const bytes_col: usize = 12;
const gap: usize = 4;
const rule_width: usize = name_col + count_col + gap + bytes_col;

fn renderTable(rows: []const SummaryRow) void {
    if (rows.len == 0) return;

    output.plain("", .{});
    output.boldPlain("  Summary", .{});
    writeRule();

    var total_count: u64 = 0;
    var total_bytes: u64 = 0;
    for (rows) |r| {
        total_count += r.removed;
        total_bytes += r.bytes;
        writeRow(r.name, r.removed, r.bytes);
    }
    writeRule();
    writeRow("total", @intCast(total_count), total_bytes);
}

fn writeRule() void {
    if (output.isQuiet()) return;
    var buf: [rule_width]u8 = undefined;
    @memset(buf[0..], '-');
    if (color.isColorEnabled()) output.writeStderrAll(color.SemanticStyle.detail.code());
    output.writeStderrAll("  ");
    output.writeStderrAll(buf[0..rule_width]);
    if (color.isColorEnabled()) output.writeStderrAll(color.Style.reset.code());
    output.writeStderrAll("\n");
}

fn writeRow(name: []const u8, count: u32, bytes: u64) void {
    var bytes_buf: [32]u8 = undefined;
    const bytes_str = util.formatBytes(bytes, &bytes_buf);

    var line_buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(
        &line_buf,
        "  {s:<16}{d:>6}    {s:>12}",
        .{ name, count, bytes_str },
    ) catch return;
    output.plain("{s}", .{line});
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test "pluralize picks singular for n=1, plural otherwise" {
    try testing.expectEqualStrings("package", pluralize(1, "package", "packages"));
    try testing.expectEqualStrings("packages", pluralize(0, "package", "packages"));
    try testing.expectEqualStrings("packages", pluralize(2, "package", "packages"));
    try testing.expectEqualStrings("entry", pluralize(1, "entry", "entries"));
    try testing.expectEqualStrings("entries", pluralize(57, "entry", "entries"));
}

test "shortHash truncates a full SHA-256 to 12 chars + ellipsis" {
    var buf: [32]u8 = undefined;
    const sha = "f81449aaecf0d71e3679c230904eaaf746b2fc61b3186870a8c2f33e38eb8404";
    const got = shortHash(sha, &buf);
    try testing.expectEqualStrings("f81449aaecf0…", got);
}

test "shortHash returns the input slice when it is already short" {
    var buf: [32]u8 = undefined;
    const got = shortHash("abc", &buf);
    try testing.expectEqualStrings("abc", got);
}

test "shortHash leaves a 12-char input untouched (boundary)" {
    var buf: [32]u8 = undefined;
    const exact = "0123456789ab";
    const got = shortHash(exact, &buf);
    try testing.expectEqualStrings(exact, got);
}

test "note prints messages whose formatted length exceeds the legacy 320-byte cap" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const prior_quiet = output.isQuiet();
    color.setForTest(false, false);
    output.setQuiet(false);
    output.beginStderrCapture(testing.allocator, &buf);
    defer {
        output.endStderrCapture();
        color.setForTest(null, null);
        output.setQuiet(prior_quiet);
    }

    var path_buf: [600]u8 = undefined;
    @memset(path_buf[0..], 'a');
    const long_path: []const u8 = path_buf[0..];

    const rep = Reporter.init("cache", true);
    rep.note("under {s}", .{long_path});

    try testing.expect(std.mem.indexOf(u8, buf.items, long_path) != null);
}
