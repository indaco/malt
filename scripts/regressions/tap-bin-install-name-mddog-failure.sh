#!/usr/bin/env bash
# Regression: a formula whose archive holds a binary not named after the
# formula installs, because `bin.install "<file>"` names the file to promote.
#
# Offline: the archive sits in the sha-keyed tap cache, so the https URL is
# never fetched. The script fails if the install is refused as a source build,
# if a rename does not land under the new name, if an unsafe rename is
# accepted, or if a helper listed first hides the file named after the formula.
#
# Usage: scripts/regressions/tap-bin-install-name-mddog-failure.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
PREFIX=$(mktemp -d /tmp/mt.XXX)
trap 'rm -rf "$PREFIX"' EXIT

W=$PREFIX/w
mkdir -p "$PREFIX/tmp" "$PREFIX/cache/Tap" "$W/payload"

# $1.. = executable names. Packs them and seeds the sha-keyed cache slot.
# The archive is named after the last one.
make_archive() {
  local f
  rm -rf "$W/payload" && mkdir -p "$W/payload"
  for f in "$@"; do
    printf '#!/bin/sh\necho %s-ok\n' "$f" >"$W/payload/$f"
    chmod 755 "$W/payload/$f"
  done
  tar czf "$W/$f.tar.gz" -C "$W/payload" "$@"
  sha=$(shasum -a 256 "$W/$f.tar.gz" | cut -d' ' -f1)
  cp "$W/$f.tar.gz" "$PREFIX/cache/Tap/$sha.tar.gz"
}

# $1 = formula name, $2 = bin.install lines. Uses the archive made last.
install_formula() {
  local name=$1 lines=$2
  cat >"$W/$name.rb" <<EOF
class Formula < Formula
  version "1.0.0"
  url "https://example.invalid/$name.tar.gz"
  sha256 "$sha"
  def install
    $lines
  end
end
EOF
  MALT_PREFIX=$PREFIX MALT_CACHE=$PREFIX/cache "$BIN" install --local "$W/$name.rb" 2>&1
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The archive file is not named after the formula.
make_archive mdd
out=$(install_formula mddog 'bin.install "mdd"') || fail "install refused: $out"
[[ "$("$PREFIX/bin/mdd")" == mdd-ok ]] || fail "bin/mdd does not run"

# A rename lands under the new name.
out=$(install_formula mdrename 'bin.install "mdd" => "mdr"') || fail "rename install refused: $out"
[[ "$("$PREFIX/bin/mdr")" == mdd-ok ]] || fail "bin/mdr does not run"

# An unsafe rename is refused and writes nothing.
if out=$(install_formula mdevil 'bin.install "mdd" => "../evil"'); then
  fail "unsafe rename was accepted: $out"
fi
[[ "$out" == *"unsafe binary name"* ]] || fail "unsafe rename not refused for the right reason: $out"
[[ ! -e "$PREFIX/Cellar/mdevil" ]] || fail "unsafe rename created a keg"

# A helper listed first must not hide the file named after the formula.
make_archive helper kit
out=$(install_formula kit 'bin.install "helper"
    bin.install "kit"') || fail "helper-first install refused: $out"
[[ "$("$PREFIX/bin/helper")" == helper-ok ]] || fail "bin/helper does not run"
[[ "$("$PREFIX/bin/kit")" == kit-ok ]] || fail "bin/kit does not run"

echo "PASS"
