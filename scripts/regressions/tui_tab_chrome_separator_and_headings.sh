#!/usr/bin/env bash
# Lock the `mt tui` list-tab chrome: a header/content separator and column
# headings.
#
# Pinned behaviour:
#   1. The Installed, Outdated, and Services tabs render a bold column-heading
#      row aligned over their value columns (NAME/VERSION/SIZE, etc.), so the
#      list reads as a table rather than loose text.
#   2. The shell paints a dim full-width rule between the filter row and the
#      content region on a list tab; the Doctor tab is left to its own band
#      rule so it never shows a doubled separator.
#
# The TUI render core is pure (`render`/`renderFrame` are functions of state +
# size), so this drives those cores directly through a standalone `zig test`
# rather than a PTY. The check imports the real source modules, so a regression
# in the render code fails it.
#
# Usage: scripts/regressions/tui_tab_chrome_separator_and_headings.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

command -v zig >/dev/null 2>&1 || fail 'zig not found on PATH'

WORK=$(mktemp -d -t mt_tui_chrome.XXXXXX)
# The check file must sit at the repo root so its imports stay inside the
# module path (the tui render modules reach into src/ui/). Both temp artifacts
# are removed on exit.
CHECK="$ROOT/.tui_chrome_check.zig"
trap 'rm -rf "$WORK" "$CHECK"' EXIT

cat >"$CHECK" <<ZIG
const std = @import("std");
const color = @import("src/ui/color.zig");
const tab = @import("src/tui/tab.zig");
const installed = @import("src/tui/installed_tab.zig");
const outdated = @import("src/tui/outdated_tab.zig");
const services = @import("src/tui/services_tab.zig");
const search = @import("src/tui/search_tab.zig");
const app = @import("src/tui/app.zig");

const bold = "\x1b[1m";

fn renderHas(comptime want: []const u8, out: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, out, want) != null);
}

// True when a dim separator sits at the cursor-move row_cup: the move, the muted
// SGR, then a box-drawing rule. Matches the exact chrome signature so a muted
// hint line (Doctor's "No findings.") at the same row never reads as a rule.
fn separatorAtRow(out: []const u8, comptime row_cup: []const u8) bool {
    const at = std.mem.indexOf(u8, out, row_cup) orelse return false;
    const after = out[at + row_cup.len ..];
    const muted = color.roleCode(.muted);
    if (!std.mem.startsWith(u8, after, muted)) return false;
    return std.mem.startsWith(u8, after[muted.len..], "\xe2\x94\x80");
}

test "installed tab heads its columns, bold and aligned" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const items = [_]installed.Pkg{
        .{ .name = "brotli", .version = "1.2.0", .kind = .formula, .pinned = false, .size_bytes = 1902690, .linked = true },
    };
    const s: installed.State = .{ .items = &items };
    installed.render(&s, &f, .{ .row = 3, .col = 1, .width = 80, .height = 10 });
    const out = f.slice();
    try renderHas(bold, out);
    // Exact padded heading proves the labels sit over the value columns.
    try renderHas("NAME" ++ " " ** 19 ++ "VERSION" ++ " " ** 8 ++ "SIZE", out);
    try renderHas("brotli", out); // the list still renders below the heading
}

test "outdated tab heads its columns past the checkbox" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    var checked = [_]bool{false};
    const items = [_]outdated.Row{
        .{ .name = "wget", .installed = "1.24.5", .latest = "1.25.0", .kind = .formula, .pinned = false, .tap = "" },
    };
    const s: outdated.State = .{ .items = &items, .checked = &checked };
    outdated.render(&s, &f, .{ .row = 3, .col = 1, .width = 80, .height = 10 });
    const out = f.slice();
    try renderHas(bold, out);
    try renderHas("    NAME" ++ " " ** 19 ++ "CURRENT" ++ " " ** 6 ++ "AVAILABLE" ++ " " ** 4 ++ "KIND", out);
    try renderHas("wget", out);
}

test "services tab heads its columns past the status dot" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const items = [_]services.Row{
        .{ .name = "redis", .state = "running", .auto_start = true, .keg_name = "redis" },
    };
    const s: services.State = .{ .items = &items };
    services.render(&s, &f, .{ .row = 3, .col = 1, .width = 80, .height = 10 });
    const out = f.slice();
    try renderHas(bold, out);
    try renderHas("  NAME" ++ " " ** 21 ++ "STATE" ++ " " ** 8 ++ "START" ++ " " ** 3 ++ "KEG", out);
    try renderHas("redis", out);
}

test "search tab heads its result columns past the checkbox" {
    var buf: [4096]u8 = undefined;
    var f: tab.Frame = .{ .buf = &buf };
    const items = [_]search.Match{.{ .name = "wget", .kind = .formula, .installed = false }};
    const s: search.State = .{ .items = &items, .phase = .loaded };
    search.render(&s, &f, .{ .row = 3, .col = 1, .width = 80, .height = 10 });
    const out = f.slice();
    try renderHas(bold, out);
    try renderHas("    NAME" ++ " " ** 25 ++ "KIND", out);
    try renderHas("wget", out);
}

test "a list tab gets a separator rule below the filter; Doctor does not double it" {
    var buf: [8192]u8 = undefined;
    // Search is the default list-style tab; content starts at row 4 (80x24).
    var a: app.App = .{};
    try std.testing.expect(separatorAtRow(app.renderFrame(&buf, &a, 80, 24), "\x1b[4;1H"));

    // Doctor is left to its own band rule — the shell must not add one at the
    // content top, or the tab would show a doubled rule. With no findings the
    // row carries only the muted hint, no rule.
    var buf2: [8192]u8 = undefined;
    var d: app.App = .{ .active = .doctor };
    try std.testing.expect(!separatorAtRow(app.renderFrame(&buf2, &d, 80, 24), "\x1b[4;1H"));
}
ZIG

if ! zig test "$CHECK" 2>"$WORK/err.txt"; then
  sed 's/^/  /' "$WORK/err.txt" >&2
  fail 'tui chrome render check failed — missing column headings and/or filter separator'
fi

printf 'PASS: tui list tabs render column headings and a filter separator\n'
