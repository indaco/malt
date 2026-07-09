#!/usr/bin/env bash
# A top-level arch-segmented formula (on_arm/on_intel, no on_macos wrapper)
# whose only block targets the arch we are NOT running on must be REFUSED
# at parse time — never resolved via the arch-blind global fallback to the
# other arch's url+sha256 (that pair is self-consistent, so the checksum
# gate cannot catch the mismatch and a non-executable binary lands silently).
#
# The refusal is a parse error, emitted before any download, so this stays
# offline. The wrong-arch URL uses a reserved .invalid host so that on a
# BROKEN tree — where the fallback wrongly parses and install proceeds to
# download — DNS fails fast instead of hanging.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX="$(mktemp -d)/opt-malt"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX"
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT

# Emit a formula whose ONLY block is for the arch we are NOT running on.
if [[ "$(uname -m)" == arm64 ]]; then
  wrong="on_intel"
  wrong_url="https://wrong.invalid/foo-1.2.3-intel.tar.gz"
else
  wrong="on_arm"
  wrong_url="https://wrong.invalid/foo-1.2.3-arm.tar.gz"
fi

cat >"$PREFIX/foo.rb" <<RB
class Foo < Formula
  version "1.2.3"
  $wrong do
    url "$wrong_url"
    sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  end
end
RB

err="$PREFIX/err.log"
if MALT_PREFIX="$PREFIX" "$BIN" install --local "$PREFIX/foo.rb" >/dev/null 2>"$err"; then
  echo "FAIL: wrong-arch-only formula installed instead of refusing" >&2
  exit 1
fi

# Non-zero alone is ambiguous (a broken tree fails later at download too).
# The parse-refusal message is what proves it was refused, not merely a
# download miss on the wrongly-resolved artifact.
if ! grep -q "Cannot parse local formula" "$err"; then
  echo "FAIL: wrong-arch pair was resolved (no parse refusal); fallback crossed arch boundary" >&2
  exit 1
fi

[[ ! -d "$PREFIX/Cellar/foo" ]] || {
  echo "FAIL: keg created for wrong-arch install" >&2
  exit 1
}

echo "OK: wrong-arch fallback refused at parse time"
exit 0
