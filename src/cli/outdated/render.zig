//! malt — outdated render helpers
//!
//! Presentation layer for `mt outdated` rows: one versioned JSON root
//! (`{"schema_version":1,"outdated":[...]}`) carrying formulae and casks,
//! and the human row format shared with `mt list` / `mt search`. Pulled
//! into its own module so the orchestrator stays focused on dispatch.

const std = @import("std");

const color = @import("../../ui/color.zig");
const output = @import("../../ui/output.zig");
const snap_mod = @import("snapshot.zig");
const OutdatedEntry = snap_mod.OutdatedEntry;

/// Which package family a unified-array row describes. Exhaustive
/// `switch` (no `else`) so a new kind is a compile error at the encoder.
pub const Kind = enum { formula, cask };

/// One row of the unified `mt outdated --json` array. `pinned` and `tap`
/// are live DB attributes (not snapshot state), so the orchestrator
/// stitches them onto the snapshot/recompute entries at emit time.
/// `tap` is `""` when unattributed — present always, matching how
/// `mt info` exposes tap.
pub const Row = struct {
    name: []const u8,
    installed: []const u8,
    latest: []const u8,
    kind: Kind,
    pinned: bool,
    tap: []const u8,
};

/// Render formula rows as styled bullets. JSON now flows through the
/// unified `writeJsonArray`; this path is human-only.
pub fn writeFormulaEntries(stdout: *std.Io.Writer, entries: []const OutdatedEntry) void {
    for (entries) |e| writeEntry(stdout, e, null);
}

/// Cask sibling of `writeFormulaEntries`: the bullet row plus a `[cask]`
/// kind tag. Human-only — casks join formulae in the unified JSON array.
pub fn writeCaskEntries(stdout: *std.Io.Writer, entries: []const OutdatedEntry) void {
    for (entries) |e| writeEntry(stdout, e, "cask");
}

/// Render a mixed slice of formula + cask rows under one versioned JSON
/// root — `{"schema_version":1,"outdated":[...]}`. Casks live inside the
/// array alongside formulae (a deliberate break from the old per-line
/// cask NDJSON), and every row carries `pinned` + `tap`. The object wrap
/// gives the array a root that can carry `schema_version`.
pub fn writeJsonArray(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    rows: []const Row,
) !void {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    try output.writeSchemaVersionPrefix(w);
    try w.writeAll("\"outdated\":[");
    for (rows, 0..) |r, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try output.jsonStr(w, r.name);
        try w.writeAll(",\"installed\":");
        try output.jsonStr(w, r.installed);
        try w.writeAll(",\"latest\":");
        try output.jsonStr(w, r.latest);
        try w.writeAll(switch (r.kind) {
            .formula => ",\"type\":\"formula\",\"pinned\":",
            .cask => ",\"type\":\"cask\",\"pinned\":",
        });
        try w.writeAll(if (r.pinned) "true" else "false");
        try w.writeAll(",\"tap\":");
        try output.jsonStr(w, r.tap);
        try w.writeAll("}");
    }
    try w.writeAll("]}\n");
    stdout.writeAll(aw.written()) catch return;
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

test "writeJsonArray wraps formulae and casks in a versioned root with all six fields" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const rows = [_]Row{
        .{ .name = "alpha", .installed = "1.0", .latest = "2.0", .kind = .formula, .pinned = false, .tap = "" },
        .{ .name = "beta-cask", .installed = "3.0", .latest = "4.0", .kind = .cask, .pinned = true, .tap = "user/repo" },
    };
    try writeJsonArray(std.testing.allocator, &aw.writer, &rows);

    const want =
        \\{"schema_version":1,"outdated":[{"name":"alpha","installed":"1.0","latest":"2.0","type":"formula","pinned":false,"tap":""},{"name":"beta-cask","installed":"3.0","latest":"4.0","type":"cask","pinned":true,"tap":"user/repo"}]}
    ++ "\n";
    try std.testing.expectEqualStrings(want, aw.written());
}

test "writeJsonArray keeps casks inside the array, not as per-line NDJSON" {
    // Regression against the old cask shape: a cask row must be a member
    // of the single array (no `}\n{` document boundary, no trailing line).
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const rows = [_]Row{
        .{ .name = "only-cask", .installed = "1.0", .latest = "2.0", .kind = .cask, .pinned = false, .tap = "" },
    };
    try writeJsonArray(std.testing.allocator, &aw.writer, &rows);

    const out = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"schema_version\":1,\"outdated\":["));
    try std.testing.expectEqualStrings("]}\n", out[out.len - 3 ..]);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"type\":\"cask\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "}\n{") == null);
}

test "writeJsonArray comma-separates a formula-only array with no trailing comma" {
    // Formula-only scope still yields one array (not the old per-kind path).
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const rows = [_]Row{
        .{ .name = "alpha", .installed = "1.0", .latest = "2.0", .kind = .formula, .pinned = false, .tap = "" },
        .{ .name = "bravo", .installed = "3.0", .latest = "4.0", .kind = .formula, .pinned = false, .tap = "" },
    };
    try writeJsonArray(std.testing.allocator, &aw.writer, &rows);

    const want =
        \\{"schema_version":1,"outdated":[{"name":"alpha","installed":"1.0","latest":"2.0","type":"formula","pinned":false,"tap":""},{"name":"bravo","installed":"3.0","latest":"4.0","type":"formula","pinned":false,"tap":""}]}
    ++ "\n";
    try std.testing.expectEqualStrings(want, aw.written());
}

test "writeJsonArray emits an empty array under the versioned root for no rows" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeJsonArray(std.testing.allocator, &aw.writer, &.{});
    try std.testing.expectEqualStrings("{\"schema_version\":1,\"outdated\":[]}\n", aw.written());
}

test "writeJsonArray keeps a pinned-but-outdated row with pinned:true" {
    // Acceptance: pinned packages stay visible rather than being dropped.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const rows = [_]Row{
        .{ .name = "held", .installed = "1.0", .latest = "2.0", .kind = .formula, .pinned = true, .tap = "" },
    };
    try writeJsonArray(std.testing.allocator, &aw.writer, &rows);

    const want =
        \\{"schema_version":1,"outdated":[{"name":"held","installed":"1.0","latest":"2.0","type":"formula","pinned":true,"tap":""}]}
    ++ "\n";
    try std.testing.expectEqualStrings(want, aw.written());
}

test "writeJsonArray escapes embedded quotes in name and tap" {
    // Names/labels from third-party taps can carry shell-hostile bytes;
    // the JSON layer escapes rather than passing them through raw.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    const rows = [_]Row{
        .{ .name = "a\"b", .installed = "1.0", .latest = "2.0", .kind = .cask, .pinned = false, .tap = "x\"y" },
    };
    try writeJsonArray(std.testing.allocator, &aw.writer, &rows);

    const want =
        \\{"schema_version":1,"outdated":[{"name":"a\"b","installed":"1.0","latest":"2.0","type":"cask","pinned":false,"tap":"x\"y"}]}
    ++ "\n";
    try std.testing.expectEqualStrings(want, aw.written());
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
    writeFormulaEntries(&aw.writer, &entries);

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
    writeCaskEntries(&aw.writer, &entries);

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "alpha-cask") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), " (1.0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), " < 2.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), " [cask]") != null);
    // No ANSI escape leaked into the no-color path.
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[") == null);
}
