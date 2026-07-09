#!/usr/bin/env bash
# Regression: tui/text_wrap.wrapTake hard-breaks an over-long spaceless token
# at a raw byte index. Without a rune-boundary check the cut can land between
# a UTF-8 lead byte and its continuation bytes, so one wrapped row ends with
# an orphan lead byte and the next starts mid-sequence — mojibake at the wrap
# point in the detail pane (tab.Frame.putContent passes bytes >= 0x80 through
# by design, so the split reaches the terminal verbatim).
#
# text_wrap.zig is a leaf module (imports only std), so the shipped file is
# copied to a temp dir, assertion tests are appended, and `zig test` runs the
# copy directly — no malt build, no network, well under 30s.
#
# Exits 0 when every hard-break lands on a rune boundary and the iterator
# terminates on degenerate widths; non-zero with a clear message otherwise.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cp "$ROOT/src/tui/text_wrap.zig" "$TMP/text_wrap_regression.zig"
cat >>"$TMP/text_wrap_regression.zig" <<'ZIG'

test "REGRESSION: hard-break never splits a multibyte rune" {
    const s = "caféteria"; // 'é' = 0xC3 0xA9 at byte offsets 3..5
    const take = wrapTake(s, 4);
    try testing.expect(std.unicode.utf8ValidateSlice(s[0..take]));
    try testing.expect(std.unicode.utf8ValidateSlice(s[take..]));
}

test "REGRESSION: width narrower than the leading rune still terminates" {
    var it = iter("é", 1);
    var rows: usize = 0;
    while (it.next()) |_| {
        rows += 1;
        if (rows > 8) return error.WrapIterDidNotTerminate;
    }
}
ZIG

zig test "$TMP/text_wrap_regression.zig" ||
  {
    echo "FAIL: text_wrap hard-break splits UTF-8 sequences" >&2
    exit 1
  }
echo "OK: text_wrap hard-break is rune-safe"
