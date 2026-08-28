#!/usr/bin/env bash
# Regression: a Ruby-DSL formula must not be able to steer its own keg out of
# the Cellar through `name` or `version`.
#
# The bug: the tap/`--local` `.rb` install path built the Cellar destination as
# `<prefix>/Cellar/<name>/<version>` straight from the DSL, with no predicate
# between parse and use. A `..` in either field is a real path hop to the
# kernel, so a third-party tap could extract its payload, relocate it, and
# record the keg row anywhere the invoking user can write - and under
# `--force` the same string reached a `deleteTree`.
#
# The fix screens both fields with the existing `isPathComponent` predicate at
# the two points where the resolved formula is constructed, and makes
# `parseTapName` refuse a formula segment that is not a safe path component.
#
# Usage: scripts/regressions/ruby-dsl-name-version-escape-cellar.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt. No network: the
# archive is seeded into the SHA-keyed tap cache so the download is a warm hit.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
SB=$(mktemp -d /tmp/mt.XXX)
trap 'rm -rf "$SB"' EXIT

export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_OFFLINE=1

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# Run malt and fail unless it refused. Callers add their own filesystem
# assertions, then report the pass.
refuse() {
  local label=$1
  shift
  local st=0
  MALT_PREFIX="$PREFIX" "$BIN" "$@" >"$SB/log" 2>&1 || st=$?
  if [[ "$st" -eq 0 ]]; then
    cat "$SB/log" >&2
    fail "$label accepted (exit 0)"
  fi
}

PREFIX="$SB/p"
mkdir -p "$PREFIX/cache/Tap" "$SB/work/bin"

printf '#!/bin/sh\necho hi\n' >"$SB/work/bin/probe"
chmod +x "$SB/work/bin/probe"
tar czf "$SB/probe.tar.gz" -C "$SB/work" bin
SHA=$(shasum -a 256 "$SB/probe.tar.gz" | cut -d' ' -f1)
cp "$SB/probe.tar.gz" "$PREFIX/cache/Tap/$SHA.tar.gz"

# `version` walks the keg out of the prefix and into this directory, which
# stands in for anything the invoking user happens to own.
mkdir -p "$SB/victim"
: >"$SB/victim/keepme"

printf 'class Probe < Formula\n  version "../../../victim"\n  url "https://example.invalid/probe.tar.gz"\n  sha256 "%s"\nend\n' \
  "$SHA" >"$SB/probe.rb"

refuse "a traversal \`version\`" install --local "$SB/probe.rb"
[[ -e "$SB/victim/bin" ]] && fail "keg extracted outside the prefix at $SB/victim"
pass "a traversal \`version\` is refused before anything is written"

# The sharper half: under --force the same string reaches a deleteTree, so the
# refusal is what keeps an unrelated directory from being pruned away.
refuse "a traversal \`version\` under --force" install --local --force "$SB/probe.rb"
[[ -f "$SB/victim/keepme" ]] || fail "--force pruned a directory outside the prefix"
pass "--force cannot prune outside the prefix through a traversal \`version\`"

# The `name` side needs no slash to escape: a local formula's name is its
# basename minus `.rb`, so a file called `...rb` is simply named `..`. Its
# version is benign, so only the name can refuse this one.
printf 'class Probe < Formula\n  version "1.2.3"\n  url "https://example.invalid/probe.tar.gz"\n  sha256 "%s"\nend\n' \
  "$SHA" >"$SB/...rb"

refuse "a local formula named \`..\`" install --local "$SB/...rb"
pass "a local formula whose basename is \`..\` is refused"

# Same guard from the slug side: the formula segment reaches both the Cellar
# path and a raw-file URL, so it must be refused at parse, before any fetch.
MALT_PREFIX="$PREFIX" "$BIN" install --dry-run 'evil/tap/..' >"$SB/log2" 2>&1 || true
grep -q "Invalid tap formula format" "$SB/log2" ||
  fail "'evil/tap/..' was not refused at parse"
pass "a traversal formula segment is refused at parse"
