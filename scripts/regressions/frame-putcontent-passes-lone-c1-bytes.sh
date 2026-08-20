#!/usr/bin/env bash
# Regression: Frame.putContent filtered row content with a flat byte switch that
# dropped 0x00-0x1F and 0x7F and passed everything else. Every byte >= 0x80 was
# therefore treated as "printable or continuation" with no notion of a pending
# sequence, so a lone 8-bit C1 introducer -- 0x9B (CSI), 0x9D (OSC), 0x9C (ST) --
# in a row reached the terminal verbatim, on an already-positioned cursor.
#
# putContent has no CLI surface (it paints into a TUI frame that needs a pty), so
# a standalone ReleaseSafe `zig test` harness drives Frame.putContent directly and
# asserts on the emitted bytes. It checks both directions: no hostile row emits a
# byte in 0x80..0x9F, and legitimate UTF-8 -- including a codepoint whose own
# continuation byte is 0x9B -- still passes byte-identically, so a blanket C1 drop
# does not make it pass.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# No network required; finishes well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# The standalone harness proves the byte-level property directly, but it cannot
# notice the real tests being deleted, so guard their names too.
while IFS= read -r name; do
  if ! grep -Fqs -- "$name" "$ROOT/src/tui/tab.zig"; then
    echo "FAIL: the C1 row-content test is missing from src/tui/tab.zig: $name" >&2
    exit 1
  fi
done <<'NAMES'
putContent drops a lone 8-bit C1 introducer from row content
putContent passes well-formed UTF-8 through byte-identically
putContent state is per call, so a split rune cannot arm the next row
NAMES

# The harness imports the tab module via a repo-relative path, so it must sit at
# the repo root for `../ui/*.zig` to resolve; $$ keeps concurrent runs from
# clobbering each other's file.
HARNESS="$ROOT/.putcontent-c1-regression.$$.zig"
trap 'rm -f "$HARNESS"' EXIT

cat >"$HARNESS" <<'ZIG'
const std = @import("std");
const tab = @import("src/tui/tab.zig");

fn paint(buf: []u8, bytes: []const u8) []const u8 {
    var f: tab.Frame = .{ .buf = buf };
    f.putContent(bytes);
    return f.slice();
}

const hostile = [_][]const u8{
    "\x9b31mX", // lone 8-bit CSI: an SGR a hostile package name might carry
    "a\x9d0;pwn\x9c", // 8-bit OSC title-set closed by an 8-bit ST
    "\xc0\xaf", // overlong: C0 is never a legal lead
    "\x80", // lone continuation byte
    "\xf5\x9b\x9d", // invalid lead: would have armed a 3-byte window
};

test "putContent drops a lone 8-bit C1 introducer from row content" {
    for (hostile) |bad| {
        var buf: [64]u8 = undefined;
        for (paint(&buf, bad)) |b| try std.testing.expect(b < 0x80 or b > 0x9F);
    }
}

test "putContent passes well-formed UTF-8 through byte-identically" {
    // U+065B is the case that matters: its continuation byte IS 0x9B, so a
    // blanket C1 drop would fail here.
    const good = [_][]const u8{ "caf\u{00e9} \u{2014} \u{1d7f6}", "\xd9\x9b", "\xed\x9b\x80" };
    for (good) |ok| {
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings(ok, paint(&buf, ok));
    }
}
ZIG

if (cd "$ROOT" && zig test -OReleaseSafe "$HARNESS") >/dev/null 2>&1; then
  echo "PASS: a lone 8-bit control byte cannot reach the frame through row content"
else
  echo "FAIL: Frame.putContent still lets a lone 8-bit control byte reach the frame" >&2
  exit 1
fi
