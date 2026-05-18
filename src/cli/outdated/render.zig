//! malt — outdated render helpers
//!
//! Presentation layer for `mt outdated` rows: JSON (one document for
//! formulas, NDJSON for casks — matches the legacy CLI shape) and the
//! human row format shared with `mt list` / `mt search`. Pulled into
//! its own module so the orchestrator stays focused on dispatch.

const std = @import("std");

const color = @import("../../ui/color.zig");
const output = @import("../../ui/output.zig");
const snap_mod = @import("snapshot.zig");
const OutdatedEntry = snap_mod.OutdatedEntry;

/// Render formula rows as a single JSON array (one document, matches
/// the documented `mt outdated --json` shape) or as styled bullets.
pub fn writeFormulaEntries(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    entries: []const OutdatedEntry,
    json_mode: bool,
) !void {
    if (json_mode) {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        const w = &aw.writer;
        try w.writeAll("[");
        for (entries, 0..) |e, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try output.jsonStr(w, e.name);
            try w.writeAll(",\"installed\":");
            try output.jsonStr(w, e.installed);
            try w.writeAll(",\"latest\":");
            try output.jsonStr(w, e.latest);
            try w.writeAll(",\"type\":\"formula\"}");
        }
        try w.writeAll("]\n");
        stdout.writeAll(aw.written()) catch return;
        return;
    }

    for (entries) |e| writeEntry(stdout, e, null);
}

/// Render cask rows. JSON mode streams one document per line (NDJSON)
/// to match the legacy `mt outdated --json --cask` shape; the human
/// mode shares the bullet row with formulas plus a `[cask]` kind tag.
pub fn writeCaskEntries(
    stdout: *std.Io.Writer,
    entries: []const OutdatedEntry,
    json_mode: bool,
) !void {
    if (json_mode) {
        for (entries) |e| {
            stdout.writeAll("{\"name\":") catch continue;
            output.jsonStr(stdout, e.name) catch continue;
            stdout.writeAll(",\"installed\":") catch continue;
            output.jsonStr(stdout, e.installed) catch continue;
            stdout.writeAll(",\"latest\":") catch continue;
            output.jsonStr(stdout, e.latest) catch continue;
            stdout.writeAll(",\"type\":\"cask\"}\n") catch continue;
        }
        return;
    }

    for (entries) |e| writeEntry(stdout, e, "cask");
}

/// Match the `mt list` / `mt search` row shape: cyan bullet, plain
/// name, dimmed `(installed)`, warn-coloured `< latest`, and an
/// optional dim `[kind]` tag for casks. Honours `NO_COLOR` / pipes
/// automatically via `color.isColorEnabled()`.
fn writeEntry(stdout: *std.Io.Writer, e: OutdatedEntry, kind_tag: ?[]const u8) void {
    if (output.isQuiet()) {
        stdout.writeAll(e.name) catch return;
        stdout.writeAll("\n") catch return;
        return;
    }

    writeBullet(stdout);
    stdout.writeAll(e.name) catch return;
    writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " (", e.installed, ")");
    writeStyledSpan(stdout, color.SemanticStyle.warn.code(), " < ", e.latest, "");
    if (kind_tag) |t| writeStyledSpan(stdout, color.SemanticStyle.detail.code(), " [", t, "]");
    stdout.writeAll("\n") catch return;
}

fn writeBullet(stdout: *std.Io.Writer) void {
    if (color.isColorEnabled()) {
        stdout.writeAll(color.SemanticStyle.info.code()) catch return;
        stdout.writeAll("  \xe2\x96\xb8 ") catch return;
        stdout.writeAll(color.Style.reset.code()) catch return;
    } else {
        stdout.writeAll("  \xe2\x96\xb8 ") catch return;
    }
}

fn writeStyledSpan(
    stdout: *std.Io.Writer,
    style_code: []const u8,
    open: []const u8,
    body: []const u8,
    close: []const u8,
) void {
    const use_color = color.isColorEnabled();
    if (use_color) stdout.writeAll(style_code) catch return;
    stdout.writeAll(open) catch return;
    stdout.writeAll(body) catch return;
    stdout.writeAll(close) catch return;
    if (use_color) stdout.writeAll(color.Style.reset.code()) catch return;
}

test "writeFormulaEntries --json emits a single canonical JSON array" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const entries = [_]OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
        .{ .name = @constCast("bravo"), .installed = @constCast("3.0"), .latest = @constCast("4.0") },
    };
    try writeFormulaEntries(std.testing.allocator, &aw.writer, &entries, true);

    const want =
        \\[{"name":"alpha","installed":"1.0","latest":"2.0","type":"formula"},{"name":"bravo","installed":"3.0","latest":"4.0","type":"formula"}]
    ++ "\n";
    try std.testing.expectEqualStrings(want, aw.written());
}

test "writeFormulaEntries --json emits an empty array for no entries" {
    // Shell-prompt integrations parse the output unconditionally; an
    // empty array is the documented "nothing outdated" shape.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeFormulaEntries(std.testing.allocator, &aw.writer, &.{}, true);
    try std.testing.expectEqualStrings("[]\n", aw.written());
}

test "writeFormulaEntries escapes embedded quotes in --json mode" {
    // Names from third-party taps can contain shell-hostile characters;
    // the JSON layer has to escape them, not pass them through raw.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const entries = [_]OutdatedEntry{
        .{ .name = @constCast("a\"b"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
    };
    try writeFormulaEntries(std.testing.allocator, &aw.writer, &entries, true);

    const want =
        \\[{"name":"a\"b","installed":"1.0","latest":"2.0","type":"formula"}]
    ++ "\n";
    try std.testing.expectEqualStrings(want, aw.written());
}

test "writeCaskEntries --json emits one NDJSON document per entry" {
    // `mt outdated --json` for casks predates the formula array shape;
    // changing it would break downstream parsers, so the NDJSON path
    // is pinned.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const entries = [_]OutdatedEntry{
        .{ .name = @constCast("alpha-cask"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
        .{ .name = @constCast("beta-cask"), .installed = @constCast("3.0"), .latest = @constCast("4.0") },
    };
    try writeCaskEntries(&aw.writer, &entries, true);

    const want =
        \\{"name":"alpha-cask","installed":"1.0","latest":"2.0","type":"cask"}
        \\{"name":"beta-cask","installed":"3.0","latest":"4.0","type":"cask"}
        \\
    ;
    try std.testing.expectEqualStrings(want, aw.written());
}

test "writeCaskEntries --json writes nothing when entries is empty" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeCaskEntries(&aw.writer, &.{}, true);
    try std.testing.expectEqualStrings("", aw.written());
}

test "writeFormulaEntries quiet mode prints only the name, no styling" {
    color.setForTest(false, null);
    output.setQuiet(true);
    defer color.setForTest(null, null);
    defer output.setQuiet(false);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const entries = [_]OutdatedEntry{
        .{ .name = @constCast("alpha"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
        .{ .name = @constCast("bravo"), .installed = @constCast("3.0"), .latest = @constCast("4.0") },
    };
    try writeFormulaEntries(std.testing.allocator, &aw.writer, &entries, false);

    try std.testing.expectEqualStrings("alpha\nbravo\n", aw.written());
}

test "writeCaskEntries human mode no-color path adds the [cask] kind tag" {
    // The bullet/styled-span path is exercised end-to-end in the smokes;
    // here we just pin that the cask kind suffix lands and the no-color
    // branch doesn't smuggle ANSI codes into a piped writer.
    color.setForTest(false, null);
    output.setQuiet(false);
    defer color.setForTest(null, null);

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const entries = [_]OutdatedEntry{
        .{ .name = @constCast("alpha-cask"), .installed = @constCast("1.0"), .latest = @constCast("2.0") },
    };
    try writeCaskEntries(&aw.writer, &entries, false);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "alpha-cask") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), " (1.0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), " < 2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), " [cask]") != null);
    // No ANSI escape leaked into the no-color path.
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[") == null);
}
