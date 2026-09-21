#!/usr/bin/env bash
# Regression: a `service do ... end` block that carries only
# `name macos: "<label>"` and no `run` is Homebrew's second service shape -
# the formula installs a pre-rendered `<keg>/<label>.plist` itself. malt
# has no plist reader, so it deliberately registers nothing for it.
#
# The bug: the install refused the block with the generic "unsupported
# service block" reason, which reads as a parser gap in malt when the
# block is perfectly well-formed. The user is left with an installed keg,
# a daemon `services start` cannot find, and the wrong explanation.
#
# Offline: a one-file tarball is planted at the sha-keyed tap-cache path
# so the install skips the download. The fix must only change the reason
# string; it must neither fail the keg nor start registering a service
# it cannot render.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1
export MALT_NO_EMOJI=1
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# The behavioural half drives `--local`; the tap path converges on the
# same reason but cannot be reached without a live forge, so its warning
# is pinned statically: the tap resolver must print the parser's reason,
# not a literal.
LOCAL_SRC="$ROOT/src/cli/install/local.zig"
TAP_FN=$(awk '/^fn installTapRb\(/,/^}/' "$LOCAL_SRC")
grep -q 'could not register service for {s}: {s}", .{ parts.formula, svc.reason }' <<<"$TAP_FN" ||
  fail "the tap resolver no longer prints the parser's refusal reason"
pass "tap resolver still prints the parser's refusal reason"

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db" "$PREFIX/tmp" "$MALT_CACHE/Tap" "$PREFIX/stage/bin"

printf '#!/bin/sh\nexit 0\n' >"$PREFIX/stage/bin/shipd"
chmod +x "$PREFIX/stage/bin/shipd"
tar -czf "$PREFIX/shipd-1.0.tar.gz" -C "$PREFIX/stage" bin
SHA=$(shasum -a 256 "$PREFIX/shipd-1.0.tar.gz" | cut -d' ' -f1)
cp "$PREFIX/shipd-1.0.tar.gz" "$MALT_CACHE/Tap/$SHA.tar.gz"

cat >"$PREFIX/shipd.rb" <<EOF
class Shipd < Formula
  url "https://example.invalid/shipd-1.0.tar.gz"
  version "1.0"
  sha256 "$SHA"
  service do
    name macos: "homebrew.mxcl.shipd"
  end
end
EOF
pass "warm tap cache seeded for a local formula that ships its own plist"

"$BIN" install --local "$PREFIX/shipd.rb" >"$PREFIX/install.log" 2>&1 || {
  tail -20 "$PREFIX/install.log" >&2
  fail "install failed (a shipped plist must never fail the keg)"
}
pass "shipd installed"

grep -q 'could not register service for shipd: formula ships its own plist, which malt does not adopt' "$PREFIX/install.log" ||
  fail "install did not say the formula ships its own plist"
! grep -q 'unsupported service block' "$PREFIX/install.log" ||
  fail "shipped-plist block still reported as an unsupported service block"
pass "install names the real reason"

ROW=$(sqlite3 "$DB" "SELECT 1 FROM services WHERE name='com.malt.shipd';")
[[ -z "$ROW" ]] ||
  fail "a services row was registered for a plist malt cannot render"
pass "no service registered for a plist malt cannot render"

echo "PASS: shipped-plist service block warns with its real reason and registers nothing"
