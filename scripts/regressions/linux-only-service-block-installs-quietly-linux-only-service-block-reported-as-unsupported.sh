#!/usr/bin/env bash
# Regression: a `service do ... end` block whose `run` carries only a
# `linux:` argv declares no service on macOS at all - Homebrew itself
# refuses to start it there and prints nothing at install time.
#
# The bug: both of malt's service parsers folded that shape into the
# generic "unsupported service block" refusal, so every install and
# upgrade of such a formula blamed a malt parser gap where there is
# nothing to support. The fix reads it as an absent block: a quiet
# install and no row.
#
# Offline: a one-file tarball is planted at the sha-keyed tap-cache path
# so the install skips the download.

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

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db" "$PREFIX/tmp" "$MALT_CACHE/Tap" "$PREFIX/stage/bin"

printf '#!/bin/sh\nexit 0\n' >"$PREFIX/stage/bin/lnxd"
chmod +x "$PREFIX/stage/bin/lnxd"
tar -czf "$PREFIX/lnxd-1.0.tar.gz" -C "$PREFIX/stage" bin
SHA=$(shasum -a 256 "$PREFIX/lnxd-1.0.tar.gz" | cut -d' ' -f1)
cp "$PREFIX/lnxd-1.0.tar.gz" "$MALT_CACHE/Tap/$SHA.tar.gz"

cat >"$PREFIX/lnxd.rb" <<EOF
class Lnxd < Formula
  url "https://example.invalid/lnxd-1.0.tar.gz"
  version "1.0"
  sha256 "$SHA"
  service do
    run linux: [opt_bin/"lnxd", "system", "service", "--time", "0"]
    working_dir HOMEBREW_PREFIX
  end
end
EOF
pass "warm tap cache seeded for a local formula with a linux-only service block"

"$BIN" install --local "$PREFIX/lnxd.rb" >"$PREFIX/install.log" 2>&1 || {
  tail -20 "$PREFIX/install.log" >&2
  fail "install failed (a linux-only service block must never fail the keg)"
}
pass "lnxd installed"

! grep -q 'could not register service' "$PREFIX/install.log" ||
  fail "linux-only service block still reported as a refused service"
! grep -q 'unsupported service block' "$PREFIX/install.log" ||
  fail "linux-only service block still called unsupported"
pass "install says nothing about a service that does not exist on macOS"

ROW=$(sqlite3 "$DB" "SELECT 1 FROM services WHERE name='com.malt.lnxd';")
[[ -z "$ROW" ]] ||
  fail "a services row was registered for a service that does not exist on macOS"
pass "no service registered"

echo "PASS: a linux-only service block installs quietly and registers nothing"
