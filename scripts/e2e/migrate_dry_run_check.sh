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
# A malt/brew-installed jq can sit on PATH yet fail to run when a removed
# dependency leaves its dylib dangling. A crashing jq emits no kegs, which
# would otherwise read as a keg mismatch instead of a broken tool. Pick the
# first jq that actually executes; fall back to the system one.
# Probe via command substitution so a jq that dies on a signal (SIGABRT
# from a missing dylib) doesn't leak an "Abort trap" notice to stderr.
JQ=""
for cand in jq /usr/bin/jq; do
  command -v "$cand" >/dev/null 2>&1 || continue
  _v=$("$cand" --version 2>/dev/null) || continue
  JQ="$cand"
  break
done
unset _v
if [[ -z "$JQ" ]]; then
  echo "migrate-check: no runnable jq found (a PATH jq may be failing to load a dylib)" >&2
  exit 2
fi

TMP=$(mktemp -d /tmp/mt_migcheck.XXX)
trap 'rm -rf "$TMP"' EXIT

# 1. What `brew` thinks is installed.
brew list --formulae | sort -u >"$TMP/brew.txt"

# 2. What `mt migrate --dry-run` discovers in the same Cellar. JSON
#    output is stable + parseable; the keg list lives at `.kegs`.
"$MT_BIN" migrate --dry-run --json | "$JQ" -r '.kegs[]' | sort -u >"$TMP/mt.txt"

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
