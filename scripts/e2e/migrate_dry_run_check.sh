#!/usr/bin/env bash
# scripts/e2e/migrate_dry_run_check.sh
#
# Manual QA check: runs `mt migrate --dry-run --json` against the user's
# real Homebrew install and diffs the reported keg set against
# `brew list --formulae`. Meant for a dev machine with brew already set
# up — never runs in CI.
#
# Read-only: --dry-run never touches MALT_PREFIX, never hits GHCR, never
# writes to the Homebrew Cellar.
#
# Usage:
#   ./scripts/e2e/migrate_dry_run_check.sh                # default brew
#   HOMEBREW_PREFIX=/custom/brew ./scripts/e2e/migrate_dry_run_check.sh
#   MT_BIN=./zig-out/bin/malt ./scripts/e2e/migrate_dry_run_check.sh

set -uo pipefail

MT_BIN="${MT_BIN:-./zig-out/bin/malt}"

if [[ ! -x "$MT_BIN" ]]; then
  echo "migrate-check: $MT_BIN not found or not executable" >&2
  echo "migrate-check: run 'zig build' first (or set MT_BIN)" >&2
  exit 2
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "migrate-check: brew not on PATH — nothing to compare against" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "migrate-check: jq is required to parse --json output" >&2
  exit 2
fi

TMP=$(mktemp -d /tmp/mt_migcheck.XXX)
trap 'rm -rf "$TMP"' EXIT

# 1. What `brew` thinks is installed.
brew list --formulae | sort -u >"$TMP/brew.txt"

# 2. What `mt migrate --dry-run` discovers in the same Cellar. JSON
#    output is stable + parseable; the keg list lives at `.kegs`.
"$MT_BIN" migrate --dry-run --json | jq -r '.kegs[]' | sort -u >"$TMP/mt.txt"

BREW_N=$(wc -l <"$TMP/brew.txt" | tr -d ' ')
MT_N=$(wc -l <"$TMP/mt.txt" | tr -d ' ')

echo "brew list --formulae : $BREW_N"
echo "mt migrate --dry-run : $MT_N"
echo

if diff -u "$TMP/brew.txt" "$TMP/mt.txt" >"$TMP/diff.txt"; then
  echo "migrate-check: OK — keg sets match"
  exit 0
fi

echo "migrate-check: MISMATCH — diff (< brew, > malt):"
cat "$TMP/diff.txt"
exit 1
