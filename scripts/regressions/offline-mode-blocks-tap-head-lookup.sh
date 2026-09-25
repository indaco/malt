#!/usr/bin/env bash
# Regression: offline mode must cover a tap's HEAD lookup. The resolver built
# its own HTTP client without the offline flag, so `MALT_OFFLINE=1 mt install
# <user>/<repo>/<name>` still called the forge API and reported a network or
# 404 failure instead of refusing up front. A `mt tap --repo --force` rebind
# must also refuse before touching the row: the lookup that follows it cannot
# succeed offline, so rebinding first would strip the tap's pin for nothing.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.
# The fixed binary never dials out; all state lives under a throwaway prefix.

set -euo pipefail

# A caller's MALT_OFFLINE would make the `--offline` flag case pass on its own.
unset MALT_OFFLINE MALT_CACHE MALT_API_DOMAIN MALT_BOTTLE_DOMAIN \
  MALT_GITHUB_TOKEN MALT_GITLAB_TOKEN MALT_GITEA_TOKEN

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

# The shell harness runs the built binary; `zig build test` does not refresh
# it, so a stale binary would mask the fix.
zig build >/dev/null

command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export NO_COLOR=1 MALT_NO_EMOJI=1
mkdir -p "$tmp/prefix/db" "$tmp/prefix/Cellar"
export MALT_PREFIX="$tmp/prefix"

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

for mode in env flag; do
  if [[ $mode == env ]]; then
    out=$(MALT_OFFLINE=1 "$BIN" install acme/tools/foo 2>&1 || true)
  else
    out=$("$BIN" --offline install acme/tools/foo 2>&1 || true)
  fi
  grep -q "Could not resolve acme/tools's HEAD commit: offline mode" <<<"$out" ||
    fail "$mode: tap HEAD lookup ignored offline mode: $(grep -m1 'HEAD commit' <<<"$out" || head -1 <<<"$out")"
done

sha=$(printf 'a%.0s' {1..40})
"$BIN" backup -o - >/dev/null 2>&1 # materialise the schema
sqlite3 "$MALT_PREFIX/db/malt.db" "INSERT INTO taps (name, url, github_owner, github_repo, host, commit_sha)
  VALUES ('acme/tools', 'https://github.com/acme/homebrew-tools', 'acme', 'homebrew-tools', 'github.com', '$sha');"
"$BIN" --offline tap acme/tools --repo acme/other --force >/dev/null 2>&1 &&
  fail "offline rebind reported success"
row=$(sqlite3 "$MALT_PREFIX/db/malt.db" "SELECT github_repo || '|' || ifnull(commit_sha, 'no pin') FROM taps WHERE name = 'acme/tools';")
[[ $row == "homebrew-tools|$sha" ]] || fail "offline rebind rewrote the tap row: $row"

# Re-adding a pinned tap needs no lookup, so it (and a Brewfile `tap` line)
# must still succeed offline.
"$BIN" --offline tap acme/tools >"$tmp/readd" 2>&1 ||
  fail "offline re-add of a pinned tap failed: $(head -1 "$tmp/readd")"
row=$(sqlite3 "$MALT_PREFIX/db/malt.db" "SELECT ifnull(commit_sha, 'no pin') FROM taps WHERE name = 'acme/tools';")
[[ $row == "$sha" ]] || fail "offline re-add changed the pin: $row"
printf 'tap "acme/tools"\n' >"$tmp/Brewfile"
"$BIN" --offline bundle install "$tmp/Brewfile" >"$tmp/bundle" 2>&1 ||
  fail "offline bundle install with a pinned tap line failed: $(tr '\n' ' ' <"$tmp/bundle")"

# Every row of an offline refresh fails, so it must not exit 0.
if "$BIN" --offline tap --refresh --all >"$tmp/refresh" 2>&1; then
  fail "offline tap --refresh --all exited 0 having refreshed nothing"
fi

printf '  ✓ offline mode refuses tap HEAD lookups and leaves a pinned tap untouched\n'
