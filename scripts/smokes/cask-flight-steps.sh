#!/usr/bin/env bash
# Smoke test for cask flight steps.
#
# Installs 86box, whose `preflight_steps` creates the ROM directory under
# `$HOME/Library`, into a throwaway prefix with HOME pointed at a scratch
# dir, then checks the directory exists and that uninstall leaves the
# prefix clean. Also runs the dry-run sweep over every cask in the bulk
# index that declares `postflight_steps` and reports which steps are
# still refused (the acceptance target is `sudo`-only).
#
# Usage: scripts/smokes/cask-flight-steps.sh [--sweep-only]
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt,
# network access to the Homebrew API and GitHub releases.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d /tmp/mt.XXX)
HOME_DIR=$(mktemp -d /tmp/mt-home.XXXXXX)
export MALT_PREFIX="$PREFIX"
mkdir -p "$PREFIX/db" "$HOME_DIR/Library"
trap 'rm -rf "$PREFIX" "$HOME_DIR"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" != "--sweep-only" ]]; then
  printf '▸ mt install 86box runs the preflight mkdir_p under HOME\n'
  out=$(HOME="$HOME_DIR" "$BIN" install --cask 86box 2>&1) || {
    echo "$out" >&2
    fail "install failed"
  }
  echo "$out" | grep -q "preflight steps completed for 86box" || fail "no preflight report in: $out"
  [[ -d "$HOME_DIR/Library/Application Support/net.86box.86Box/roms" ]] || fail "roms directory missing"
  pass "roms directory created"

  printf '▸ mt uninstall 86box leaves nothing behind\n'
  HOME="$HOME_DIR" "$BIN" uninstall 86box >/dev/null 2>&1 || fail "uninstall failed"
  [[ ! -e "$PREFIX/Caskroom/86box" ]] || fail "Caskroom dir survived uninstall"
  pass "clean uninstall"
fi

printf '▸ dry-run sweep over every postflight_steps cask\n'
index="$PREFIX/cask.json"
curl -sSfL https://formulae.brew.sh/api/cask.json -o "$index" || fail "could not fetch the cask index"
tokens=$(jq -r '.[] | select(.artifacts[]? | has("postflight_steps")) | .token' "$index" | sort -u)
count=$(echo "$tokens" | grep -c . || true)
unsupported=0
sudo_only=0
for token in $tokens; do
  out=$(HOME="$HOME_DIR" "$BIN" install --cask --dry-run "$token" 2>&1 || true)
  lines=$(echo "$out" | grep "unsupported step:" || true)
  [[ -n "$lines" ]] || continue
  while IFS= read -r line; do printf '  %s: %s\n' "$token" "$line"; done <<<"$lines"
  n=$(echo "$lines" | grep -c .)
  s=$(echo "$lines" | grep -c "sudo" || true)
  unsupported=$((unsupported + n))
  sudo_only=$((sudo_only + s))
done
printf '  %d casks swept, %d unsupported step lines, %d of them sudo\n' "$count" "$unsupported" "$sudo_only"
