#!/usr/bin/env bash
# scripts/test/gen_man_test.sh — regression tests for scripts/gen-man.sh and
# the `just man-check` drift guard.
#
# Covers the four guarantees the man-page generator exists to provide:
#
#   1. determinism  — two regenerations are byte-identical, and the output
#      carries no machine-specific leaks ($HOME, $USER, wall-clock date).
#   2. coverage     — every command in `malt --help`'s Commands column is a
#      section in the page (the drift this approach exists to prevent).
#   3. roff lint    — `mandoc -T lint` is clean bar the one documented,
#      version-derived `.TH` date warning (skipped when mandoc is absent).
#   4. man-check    — `just man-check` exits non-zero on a stale committed
#      page and zero when it matches.
#
# Usage:
#   ./scripts/test/gen_man_test.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GEN="$ROOT/scripts/gen-man.sh"
BIN="$ROOT/zig-out/bin/malt"
COMMITTED="$ROOT/man/malt.1"

[ -x "$BIN" ] || {
  echo "malt binary missing at $BIN — run 'zig build' first" >&2
  exit 2
}
[ -x "$GEN" ] || {
  echo "generator missing or not executable at $GEN" >&2
  exit 2
}

TMP=$(mktemp -d /tmp/malt_gen_man_test.XXXXXX)
# The man-check test mutates the committed page in place; the trap restores it
# from BACKUP even if the run is interrupted before the inline restore.
BACKUP=""
cleanup() {
  [ -n "$BACKUP" ] && [ -f "$BACKUP" ] && cp "$BACKUP" "$COMMITTED"
  rm -rf "$TMP"
}
trap cleanup EXIT

pass=0
fail=0
failures=()

ok() {
  printf '  ✓ %s\n' "$1"
  pass=$((pass + 1))
}
ko() {
  printf '  ✗ %s\n' "$1" >&2
  fail=$((fail + 1))
  failures+=("$1")
}

# ── 1: determinism ───────────────────────────────────────────────────
printf '▸ determinism\n'
"$GEN" "$TMP/a.1"
"$GEN" "$TMP/b.1"
if cmp -s "$TMP/a.1" "$TMP/b.1"; then
  ok "two regenerations are byte-identical"
else
  ko "regenerations differ (non-deterministic output)"
fi

# No machine-specific leaks. $HOME and the username must never reach the page;
# a wall-clock month name would also break the byte-stable diff.
leaked=0
grep -qF "$HOME" "$TMP/a.1" && {
  ko "output leaks \$HOME ($HOME)"
  leaked=1
}
grep -qw "$(whoami)" "$TMP/a.1" && {
  ko "output leaks \$USER ($(whoami))"
  leaked=1
}
[ "$leaked" -eq 0 ] && ok "no \$HOME/\$USER leaks in output"

# ── 2: coverage ──────────────────────────────────────────────────────
# A heading alone documents nothing — services/bundle/version emit their help
# on stderr, so the body must be captured too. Assert each .SS section exists
# AND carries at least one content line between its .nf/.fi.
printf '▸ coverage\n'
missing=0
empty=0
while IFS= read -r tok; do
  if ! grep -qE "^\.SS ${tok//\//\\/}\$" "$TMP/a.1"; then
    ko "command '$tok' has no .SS section in the page"
    missing=1
    continue
  fi
  body=$(awk -v t="$tok" '
    $0==".SS " t {ins=1; next}
    ins && $0==".nf" {innf=1; next}
    ins && innf && $0==".fi" {exit}
    ins && innf {print}
  ' "$TMP/a.1")
  if [ -z "$(printf '%s' "$body" | tr -d '[:space:]')" ]; then
    ko "command '$tok' has an empty .SS body"
    empty=1
  fi
done < <("$BIN" --help | awk '/^Commands:/{f=1;next} /^Global flags:/{f=0} f && /^  [^ ]/{print $1}')
[ "$missing" -eq 0 ] && ok "every Commands-column token has a section"
[ "$empty" -eq 0 ] && ok "every section body is non-empty"

# ── 3: roff lint ─────────────────────────────────────────────────────
printf '▸ roff lint\n'
if command -v mandoc >/dev/null 2>&1; then
  # The page deliberately carries a version string in the .TH date slot for
  # byte-determinism, so mandoc emits exactly one "cannot parse date" warning.
  # Treat that single line as expected; any other lint output is a failure.
  lint=$(mandoc -T lint "$TMP/a.1" 2>&1 || true)
  other=$(printf '%s\n' "$lint" | grep -v 'cannot parse date' | grep -v '^[[:space:]]*$' || true)
  if [ -z "$other" ]; then
    ok "mandoc -T lint clean (bar the documented date warning)"
  else
    ko "mandoc -T lint reported unexpected issues:"
    printf '%s\n' "$other" >&2
  fi
else
  printf '  - mandoc absent, skipping roff lint\n'
fi

# ── 4: man-check drift guard ─────────────────────────────────────────
printf '▸ man-check\n'
if [ -f "$COMMITTED" ]; then
  BACKUP="$TMP/committed.bak"
  cp "$COMMITTED" "$BACKUP"
  restore() { cp "$BACKUP" "$COMMITTED"; }

  # Matches: exit 0.
  if (cd "$ROOT" && just man-check >/dev/null 2>&1); then
    ok "man-check exits 0 when the committed page matches"
  else
    ko "man-check failed against an in-sync committed page"
  fi

  # Stale: mutate the committed page, expect non-zero.
  printf '\n.\\" drift\n' >>"$COMMITTED"
  rc=0
  (cd "$ROOT" && just man-check >/dev/null 2>&1) || rc=$?
  restore
  if [ "$rc" -ne 0 ]; then
    ok "man-check exits non-zero on a stale committed page"
  else
    ko "man-check passed a stale committed page"
  fi
else
  ko "committed page missing at $COMMITTED (run 'just man-gen')"
fi

# ── summary ──────────────────────────────────────────────────────────
printf '\n── summary ──\npass: %d\nfail: %d\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf 'failures:\n'
  for f in "${failures[@]}"; do printf '  %s\n' "$f"; done
  exit 1
fi
