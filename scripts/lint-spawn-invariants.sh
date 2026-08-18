#!/usr/bin/env bash
# scripts/lint-spawn-invariants.sh — fail on shell-invocation patterns
#
# Every Zig-side process spawn in malt goes through argv-style APIs
# (`std.process.spawn` via `fs_compat.Child.init`). A bare `sh -c …`
# or `/bin/sh …` argv in src/ would quietly restore the shell-injection
# surface we've spent time eliminating — run this in CI to catch
# regressions before they merge.
#
# Exits 0 if src/ is clean, non-zero with offending lines on violation.
#
# Usage:
#   scripts/lint-spawn-invariants.sh           # check the tree
#
# The allowlist file lives at scripts/.spawn-lint-allow. Each line is a
# `path:regex` that excuses a specific match; keep it empty unless you
# have a real reason.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

ALLOW_FILE="scripts/.spawn-lint-allow"

PATTERN='sh -c|bash -c|zsh -c|/bin/sh|/bin/bash|/bin/zsh|/usr/bin/env '
hits=$(grep -RnE --include='*.zig' "$PATTERN" src || true)

# Drop allowlisted matches.
if [ -s "$ALLOW_FILE" ]; then
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    [[ "$rule" == \#* ]] && continue
    hits=$(printf '%s\n' "$hits" | grep -vE "$rule" || true)
  done <"$ALLOW_FILE"
fi

if [ -n "$hits" ]; then
  printf '✗ argv-only spawn invariant violated:\n\n' >&2
  printf '%s\n' "$hits" >&2
  printf '\nIf a match is intentional (it almost never is), add a line to %s.\n' "$ALLOW_FILE" >&2
  exit 1
fi

printf '✓ argv-only spawn invariant holds across src/\n'

# A platform helper named without a path resolves through PATH, and a package's
# own bin directory can sit ahead of the system one. Every tool in
# src/system_tools.zig is spawned by absolute path; this catches a bare name
# creeping back. Matching the bare literal anywhere beats matching an argv
# shape: a multi-line argv literal puts the name on its own line, which is the
# form the original bug had.
#
# `install` is skipped: it is also a malt subcommand, so the bare literal is
# ambiguous and would fire on ordinary argv tails.
TOOLS=$(grep -oE '^pub const [a-z_]+ = "/[^"]+"' src/system_tools.zig |
  sed -E 's|^pub const [a-z_]+ = "/.*/([^/"]+)"|\1|' | grep -vx install | tr '\n' ' ')

bare=""
for bin in $TOOLS; do
  found=$(grep -RnF --include='*.zig' "\"$bin\"" src || true)
  [ -n "$found" ] && bare="$bare$found
"
done

if [ -s "$ALLOW_FILE" ]; then
  while IFS= read -r rule; do
    [ -z "$rule" ] && continue
    [[ "$rule" == \#* ]] && continue
    bare=$(printf '%s\n' "$bare" | grep -vE "$rule" || true)
  done <"$ALLOW_FILE"
fi
bare=$(printf '%s' "$bare" | grep -v '^$' || true)

if [ -n "$bare" ]; then
  printf '✗ platform helper named without a path (resolves through PATH):\n\n' >&2
  printf '%s\n' "$bare" >&2
  printf '\nUse the matching constant in src/system_tools.zig, or allowlist in %s.\n' "$ALLOW_FILE" >&2
  exit 1
fi

printf '✓ platform helpers are named by absolute path\n'
