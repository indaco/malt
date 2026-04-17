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
