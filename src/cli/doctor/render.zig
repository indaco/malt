//! malt — doctor row renderer.
//!
//! Pure rendering primitives for `mt doctor` check rows. Kept separate
//! from the walker so the glyph/colour invariants can be exercised
//! against a buffer writer in hermetic tests.

const std = @import("std");
const output = @import("../../ui/output.zig");
const color = @import("../../ui/color.zig");
const fix_mod = @import("fix.zig");

pub const CheckStatus = enum { ok, warn_status, err_status };

/// Safe-fix vocabulary shared with `--fix`. `mt doctor --json` reports a
/// finding's class from this set (or `none`) so the dashboard and the
/// per-finding selector pin one vocabulary.
pub const FixKind = fix_mod.FixKind;

/// One machine-readable doctor finding. `mt doctor --json`'s `checks[]`
/// serializes these; the human rows render from the same call, so the
/// two views never drift.
pub const Finding = struct {
    /// Stable per-finding slug (same finding → same id across runs).
    id: []const u8,
    severity: CheckStatus,
    /// Human row title (the check name).
    title: []const u8,
    detail: []const u8 = "",
    /// True when `mt doctor --fix` can act on this finding.
    fixable: bool = false,
    /// Safe-fix class, or `null` (serialized as `"none"`) when `--fix`
    /// cannot resolve it.
    fix_class: ?FixKind = null,
};

/// JSON severity vocabulary, mirroring `CheckStatus`. Exhaustive switch
/// (no `else =>`) so a new status can't silently leak an unmapped tag
/// into the published contract.
pub fn severityTag(status: CheckStatus) []const u8 {
    return switch (status) {
        .ok => "ok",
        .warn_status => "warn",
        .err_status => "err",
    };
}

/// JSON fix-class vocabulary. `null` → `"none"`; otherwise the safe-fix
/// class name. Explicit exhaustive switch so a renamed/added `FixKind`
/// is a compile error here, never a silent API change.
pub fn fixClassTag(kind: ?FixKind) []const u8 {
    const k = kind orelse return "none";
    return switch (k) {
        .stale_lock => "stale_lock",
        .orphaned_store => "orphaned_store",
        .broken_symlinks => "broken_symlinks",
    };
}

/// Serialize findings as a `{"checks":[...]}` object. Pure writer so
/// tests pin the bytes; every string routes through the shared JSON
/// escaper. `detail` is always present (empty string when the row had
/// no detail) so consumers never special-case a missing field.
pub fn writeChecksJson(w: *std.Io.Writer, findings: []const Finding) !void {
    try w.writeAll("{\"checks\":[");
    for (findings, 0..) |f, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try output.jsonStr(w, f.id);
        try w.writeAll(",\"severity\":");
        try output.jsonStr(w, severityTag(f.severity));
        try w.writeAll(",\"title\":");
        try output.jsonStr(w, f.title);
        try w.writeAll(",\"detail\":");
        try output.jsonStr(w, f.detail);
        try w.writeAll(if (f.fixable) ",\"fixable\":true,\"fix_class\":" else ",\"fixable\":false,\"fix_class\":");
        try output.jsonStr(w, fixClassTag(f.fix_class));
        try w.writeAll("}");
    }
    try w.writeAll("]}\n");
}

pub const CheckStyle = struct {
    /// Emit ANSI colour codes. False for plain terminals and tests.
    color: bool,
    /// Use the ✓/⚠/✗ glyphs. False falls back to ASCII */!/x.
    emoji: bool,
};

fn glyphFor(status: CheckStatus, emoji: bool) []const u8 {
    return if (emoji) switch (status) {
        .ok => "✓",
        .warn_status => "⚠",
        .err_status => "✗",
    } else switch (status) {
        .ok => "*",
        .warn_status => "!",
        .err_status => "x",
    };
}

fn statusCode(status: CheckStatus) []const u8 {
    return switch (status) {
        .ok => color.SemanticStyle.success.code(),
        .warn_status => color.SemanticStyle.warn.code(),
        .err_status => color.SemanticStyle.err.code(),
    };
}

/// Render one check row. Pure (no stderr / global state), so tests
/// can drive it against a buffer writer and assert on the bytes.
pub fn renderCheckRow(
    writer: *std.Io.Writer,
    status: CheckStatus,
    name: []const u8,
    detail: ?[]const u8,
    style_opts: CheckStyle,
) !void {
    const glyph = glyphFor(status, style_opts.emoji);
    try writer.writeAll("  ");
    if (style_opts.color) {
        try writer.writeAll(statusCode(status));
        try writer.writeAll(glyph);
        try writer.writeAll(color.Style.reset.code());
    } else {
        try writer.writeAll(glyph);
    }
    try writer.writeAll(" ");
    try writer.writeAll(name);

    if (detail) |d| {
        if (style_opts.color) {
            try writer.writeAll(" ");
            try writer.writeAll(color.SemanticStyle.detail.code());
            try writer.writeAll("— ");
            try writer.writeAll(d);
            try writer.writeAll(color.Style.reset.code());
        } else {
            try writer.writeAll(" — ");
            try writer.writeAll(d);
        }
    }
    try writer.writeAll("\n");
}

pub fn printCheck(name: []const u8, status: CheckStatus, detail: ?[]const u8) void {
    if (output.isQuiet()) return;
    // `File.writer.flush` writes positionally from offset 0, overwriting
    // prior rows when stderr is a regular file; stream via `stderrWriteAll`.
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Truncation of an oversized row is acceptable - `buffered()` still emits what fit.
    renderCheckRow(&w, status, name, detail, .{
        .color = color.isColorEnabled(),
        .emoji = color.isEmojiEnabled(),
    }) catch {};
    output.writeStderrAll(w.buffered());
}

// ── inline unit tests: JSON findings vocabulary + serializer ─────────

const testing = std.testing;

test "severityTag maps every CheckStatus to its JSON token" {
    try testing.expectEqualStrings("ok", severityTag(.ok));
    try testing.expectEqualStrings("warn", severityTag(.warn_status));
    try testing.expectEqualStrings("err", severityTag(.err_status));
}

test "fixClassTag maps null to none and each FixKind to its tag" {
    try testing.expectEqualStrings("none", fixClassTag(null));
    try testing.expectEqualStrings("stale_lock", fixClassTag(.stale_lock));
    try testing.expectEqualStrings("orphaned_store", fixClassTag(.orphaned_store));
    try testing.expectEqualStrings("broken_symlinks", fixClassTag(.broken_symlinks));
}

fn checksToBuf(findings: []const Finding, buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try writeChecksJson(&w, findings);
    return w.buffered();
}

test "writeChecksJson: empty findings keep a stable empty array" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{\"checks\":[]}\n", try checksToBuf(&.{}, &buf));
}

test "writeChecksJson: ok finding serializes detail and none/false defaults" {
    var buf: [256]u8 = undefined;
    const findings = [_]Finding{
        .{ .id = "malt_prefix", .severity = .ok, .title = "MALT_PREFIX", .detail = "/opt/malt (default)" },
    };
    try testing.expectEqualStrings(
        "{\"checks\":[{\"id\":\"malt_prefix\",\"severity\":\"ok\",\"title\":\"MALT_PREFIX\"," ++
            "\"detail\":\"/opt/malt (default)\",\"fixable\":false,\"fix_class\":\"none\"}]}\n",
        try checksToBuf(&findings, &buf),
    );
}

test "writeChecksJson: a fixable warn finding carries its fix_class" {
    var buf: [256]u8 = undefined;
    const findings = [_]Finding{
        .{
            .id = "stale_lock",
            .severity = .warn_status,
            .title = "Stale lock",
            .detail = "Stale lock from dead PID 42",
            .fixable = true,
            .fix_class = .stale_lock,
        },
    };
    try testing.expectEqualStrings(
        "{\"checks\":[{\"id\":\"stale_lock\",\"severity\":\"warn\",\"title\":\"Stale lock\"," ++
            "\"detail\":\"Stale lock from dead PID 42\",\"fixable\":true,\"fix_class\":\"stale_lock\"}]}\n",
        try checksToBuf(&findings, &buf),
    );
}

test "writeChecksJson: comma-separates multiple findings" {
    var buf: [256]u8 = undefined;
    const findings = [_]Finding{
        .{ .id = "a", .severity = .ok, .title = "A" },
        .{ .id = "b", .severity = .err_status, .title = "B" },
    };
    const out = try checksToBuf(&findings, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "},{") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"severity\":\"err\"") != null);
}

test "writeChecksJson: detail with quotes is JSON-escaped" {
    var buf: [256]u8 = undefined;
    const findings = [_]Finding{
        .{ .id = "x", .severity = .warn_status, .title = "X", .detail = "needs \"quotes\"" },
    };
    const out = try checksToBuf(&findings, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "\\\"quotes\\\"") != null);
}
