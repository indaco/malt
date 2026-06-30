#!/usr/bin/env bash
# Regression: a Brewfile directive whose trailing comment contains "if" or a
# "do"-prefixed word (download, documentation, done, "do not") must still parse.
#
# The bug: the conditional/block guard scanned the raw line *including* its
# trailing comment for " if " and " do", before comment stripping ran. So any
# valid directive carrying such a comment was rejected with
# Conditionals/BlocksUnsupported, and because the guard returns out of the
# parser the whole Brewfile import aborted — not just the offending line. The
# " do" arm was also substring-only, firing mid-word on "download".
#
# Asserts the comment-bearing lines round-trip all three packages via a
# read-only `bundle install --dry-run`, and that a genuine `if`/`do` block is
# still rejected.
#
# Exits 0 when valid comments parse and real conditionals are rejected;
# non-zero otherwise. No network; runs the built binary against a throwaway
# MALT_PREFIX so no real keg is touched.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# The shell harness runs the built binary, which `zig build test` does not
# rebuild — build it here so a stale binary never masks the fix.
zig build >/dev/null

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export MALT_PREFIX="$tmp/p"
mkdir -p "$MALT_PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1

bf="$tmp/Brewfile"
cat >"$bf" <<'EOF'
brew "wget" # build if needed
brew "git"  # download manager
cask "firefox" # do not remove
EOF

# Positive: comments containing if/do must not abort the import.
out="$("$BIN" --dry-run bundle install "$bf" 2>&1)" || {
  echo "FAIL: valid comments containing if/do were rejected:" >&2
  echo "$out" >&2
  exit 1
}
echo "$out" | grep -q wget || {
  echo "FAIL: wget missing" >&2
  echo "$out" >&2
  exit 1
}
echo "$out" | grep -q git || {
  echo "FAIL: git missing" >&2
  echo "$out" >&2
  exit 1
}
echo "$out" | grep -q firefox || {
  echo "FAIL: firefox missing" >&2
  echo "$out" >&2
  exit 1
}

# Negative: a real conditional must still be rejected.
printf 'if OS.mac?\nbrew "wget"\nend\n' >"$bf"
if "$BIN" --dry-run bundle install "$bf" >/dev/null 2>&1; then
  echo "FAIL: real conditional was not rejected" >&2
  exit 1
fi

# Negative: real do…end block openers must still be rejected, including the
# pipe-without-space form that a literal " do " check would silently accept.
for opener in 'brew "wget" do |f|' 'brew "wget" do|f|'; do
  printf '%s\nend\n' "$opener" >"$bf"
  if "$BIN" --dry-run bundle install "$bf" >/dev/null 2>&1; then
    echo "FAIL: real do block was not rejected: $opener" >&2
    exit 1
  fi
done

echo "PASS"
