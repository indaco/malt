//! malt — doctor row renderer.
//!
//! Pure rendering primitives for `mt doctor` check rows. Kept separate
//! from the walker so the glyph/colour invariants can be exercised
//! against a buffer writer in hermetic tests.

const std = @import("std");
const output = @import("../../ui/output.zig");
const color = @import("../../ui/color.zig");
const fix_mod = @import("fix.zig");

// `info_status` is the in-progress downgrade: a finding that would be a
// warn/err is recast as informational while an operation holds the prefix
// lock. It does not count toward the severity exit.
pub const CheckStatus = enum { ok, warn_status, err_status, info_status };

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
        .info_status => "info",
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

/// Resolve a `--fix <id>` token back to its safe-fix class, reusing the
/// `fixClassTag` vocabulary so the selector and the JSON findings can
/// never disagree on one set of ids. Unknown ids — including `"none"`
/// and the empty string — error; only the real safe classes resolve.
pub fn fixKindFromId(id: []const u8) error{UnknownFixId}!FixKind {
    inline for (std.meta.fields(FixKind)) |f| {
        const kind: FixKind = @field(FixKind, f.name);
        if (std.mem.eql(u8, id, fixClassTag(kind))) return kind;
    }
    return error.UnknownFixId;
}

/// Comma-joined list of the valid `--fix <id>` ids, built from the same
/// vocabulary so an unknown-id error can name the alternatives without a
/// hand-maintained string drifting from the enum.
pub const fix_ids_csv = blk: {
    var s: []const u8 = "";
    for (std.meta.fields(FixKind), 0..) |f, i| {
        const kind: FixKind = @field(FixKind, f.name);
        s = s ++ (if (i == 0) "" else ", ") ++ fixClassTag(kind);
    }
    break :blk s;
};

/// Write the `"checks":[...]` field (no surrounding braces, no newline)
/// so the doctor `--json` merger can embed it as one member of the single
/// versioned root. `detail` is always present (empty string when the row
/// had no detail) so consumers never special-case a missing field.
pub fn writeChecksField(w: *std.Io.Writer, findings: []const Finding) !void {
    try w.writeAll("\"checks\":[");
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
    try w.writeAll("]");
}

/// Serialize findings as a standalone `{"checks":[...]}` object. Pure
/// writer so tests pin the bytes; wraps `writeChecksField`.
pub fn writeChecksJson(w: *std.Io.Writer, findings: []const Finding) !void {
    try w.writeAll("{");
    try writeChecksField(w, findings);
    try w.writeAll("}\n");
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
        .info_status => "ℹ",
    } else switch (status) {
        .ok => "*",
        .warn_status => "!",
        .err_status => "x",
        .info_status => "i",
    };
}

fn statusCode(status: CheckStatus) []const u8 {
    return switch (status) {
        .ok => color.SemanticStyle.success.code(),
        .warn_status => color.SemanticStyle.warn.code(),
        .err_status => color.SemanticStyle.err.code(),
        .info_status => color.SemanticStyle.info.code(),
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
    // `info` is the in-progress downgrade — a non-fault, JSON-visible state.
    try testing.expectEqualStrings("info", severityTag(.info_status));
}

test "fixClassTag maps null to none and each FixKind to its tag" {
    try testing.expectEqualStrings("none", fixClassTag(null));
    try testing.expectEqualStrings("stale_lock", fixClassTag(.stale_lock));
    try testing.expectEqualStrings("orphaned_store", fixClassTag(.orphaned_store));
    try testing.expectEqualStrings("broken_symlinks", fixClassTag(.broken_symlinks));
}

test "fixKindFromId resolves every published id to its class" {
    try testing.expectEqual(FixKind.stale_lock, try fixKindFromId("stale_lock"));
    try testing.expectEqual(FixKind.orphaned_store, try fixKindFromId("orphaned_store"));
    try testing.expectEqual(FixKind.broken_symlinks, try fixKindFromId("broken_symlinks"));
}

test "fixKindFromId round-trips fixClassTag for every FixKind" {
    // The selector must accept exactly the ids the JSON findings emit;
    // pin the round-trip so the two views can never drift.
    inline for (std.meta.fields(FixKind)) |f| {
        const kind: FixKind = @field(FixKind, f.name);
        try testing.expectEqual(kind, try fixKindFromId(fixClassTag(kind)));
    }
}

test "fixKindFromId rejects unknown, none, and empty ids" {
    try testing.expectError(error.UnknownFixId, fixKindFromId("bogus"));
    try testing.expectError(error.UnknownFixId, fixKindFromId("none"));
    try testing.expectError(error.UnknownFixId, fixKindFromId(""));
}

test "fix_ids_csv lists every safe-fix id" {
    inline for (std.meta.fields(FixKind)) |f| {
        const kind: FixKind = @field(FixKind, f.name);
        try testing.expect(std.mem.indexOf(u8, fix_ids_csv, fixClassTag(kind)) != null);
    }
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

test "writeChecksJson: an in-progress finding serializes severity info, non-fixable" {
    // The downgrade must be visible in the contract, not silently dropped —
    // and never fixable (a transient is not actionable).
    var buf: [256]u8 = undefined;
    const findings = [_]Finding{
        .{
            .id = "missing_kegs",
            .severity = .info_status,
            .title = "Missing kegs",
            .detail = "operation in progress — re-run after it completes",
        },
    };
    const out = try checksToBuf(&findings, &buf);
    try testing.expect(std.mem.indexOf(u8, out, "\"severity\":\"info\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"fixable\":false") != null);
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
