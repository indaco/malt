#!/usr/bin/env bash
# Regression for a tap/local `.rb` that declares `revision N`.
#
# The outdated audit qualifies the upstream version with the `.rb` revision
# (`1.0.0_2`), but install recorded `revision = 0` and named the Cellar leaf
# by the bare version. `isCurrent` then saw `1.0.0` vs `1.0.0_2` on every
# audit, so the keg was listed as outdated forever and neither `upgrade`
# nor `--force` could clear it.
#
# Asserts, offline, on a `--local` install:
#   1. the keg row records the `.rb` revision;
#   2. the Cellar leaf and the opt link both name `<version>_<revision>`,
#      the same leaf uninstall/purge/rollback derive from the row;
#   3. uninstall resolves that leaf;
#   4. a revision-less `.rb` still lands bare.
#
# Usage: scripts/regressions/tap-install-records-rb-revision-1021-adjacent.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, sqlite3.
# Offline: the archive is pre-seeded at the SHA-keyed cache path.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null 2>&1 || {
  echo "sqlite3 is required" >&2
  exit 2
}

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX/cache/Tap"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Pack a one-script keg as bin/$1, seed it at the SHA-keyed cache path the
# warm-cache branch reads, and emit a local `.rb` carrying `$2` verbatim
# (a `revision N` line or nothing). Echoes the formula path.
stage() {
  local name=$1 extra=$2
  local work="$PREFIX/work_$name"
  mkdir -p "$work/bin"
  printf '#!/bin/sh\necho %s\n' "$name" >"$work/bin/$name"
  chmod +x "$work/bin/$name"

  local tarball="$PREFIX/$name.tar.gz"
  tar czf "$tarball" -C "$work" bin
  local sha
  sha=$(shasum -a 256 "$tarball" | cut -d' ' -f1)
  cp "$tarball" "$PREFIX/cache/Tap/$sha.tar.gz"

  local class
  class=$(printf '%s' "$name" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  cat >"$PREFIX/$name.rb" <<FORMULA
class $class < Formula
  desc "Fixture"
  homepage "https://example.invalid/$name"
  version "1.0.0"
  $extra
  url "https://example.invalid/releases/download/v1.0.0/$name.tar.gz"
  sha256 "$sha"
end
FORMULA
  printf '%s\n' "$PREFIX/$name.rb"
}

keg_col() { sqlite3 "$PREFIX/db/malt.db" "SELECT $1 FROM kegs WHERE name='$2'"; }

# ── 1–3: a revision-bearing .rb ─────────────────────────────────────────
LOG="$PREFIX/install.log"
"$BIN" install --local "$(stage revfix 'revision 2')" >"$LOG" 2>&1 || {
  cat "$LOG" >&2
  fail "install of a revision-bearing .rb reported a failure"
}

WANT="$PREFIX/Cellar/revfix/1.0.0_2"
row=$(keg_col "revision||'|'||cellar_path" revfix)
[[ "$row" == "2|$WANT" ]] || fail "keg row records '$row', want '2|$WANT'"
pass "keg row records the .rb revision and the revisioned leaf"

[[ -d "$WANT" ]] || fail "Cellar leaf is not 1.0.0_2: $(ls "$PREFIX/Cellar/revfix")"
[[ "$(readlink "$PREFIX/opt/revfix")" == "$WANT" ]] || fail "opt link names $(readlink "$PREFIX/opt/revfix"), want $WANT"
pass "Cellar leaf and opt link agree on the revisioned leaf"

"$BIN" uninstall revfix >"$LOG" 2>&1 || {
  cat "$LOG" >&2
  fail "uninstall of the revisioned keg reported a failure"
}
[[ ! -e "$WANT" ]] || fail "uninstall left the revisioned leaf behind"
pass "uninstall resolves the revisioned leaf"

# ── 4: a revision-less .rb still lands bare ─────────────────────────────
"$BIN" install --local "$(stage bare '')" >"$LOG" 2>&1 || {
  cat "$LOG" >&2
  fail "install of a revision-less .rb reported a failure"
}
[[ "$(keg_col revision bare)" == "0" && -d "$PREFIX/Cellar/bare/1.0.0" ]] ||
  fail "revision-less .rb no longer lands bare: revision=$(keg_col revision bare) $(ls "$PREFIX/Cellar/bare")"
pass "a revision-less .rb still lands on the bare leaf"

printf '\n✔ tap install records rb revision regression passed\n'
