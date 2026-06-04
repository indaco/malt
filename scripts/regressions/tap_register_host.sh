#!/usr/bin/env bash
# Lock the non-GitHub tap registration contract end-to-end, no network.
#
# Pinned behaviour:
#   1. `mt tap <slug> --host <host> --repo <o>/<r>` persists the row with
#      the chosen host, no `homebrew-` synthesis, and unpinned (resolution
#      for non-GitHub forges lands in a later release).
#   2. `mt tap <slug> --url https://<host>/<o>/<r>` derives and persists
#      (host, owner, repo) the same way.
#   3. `mt tap --json` / `mt tap` surface the host.
#   4. A non-GitHub host with no explicit repo fails with a hint — never a
#      silent `homebrew-<repo>` guess.
#   5. A `--host` carrying a scheme/path is rejected.
#
# The non-GitHub path never touches the network, so this runs offline.
#
# Usage: scripts/regressions/tap_register_host.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

PREFIX=$(mktemp -d -t mt_taphost.XXXXXX)
mkdir -p "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. --host + --repo registers a gitlab tap, unpinned, no homebrew- synthesis.
"$MALT_BIN" tap grp/tap --host gitlab.com --repo grp/tap >/dev/null 2>&1 ||
  fail 'mt tap --host gitlab.com --repo grp/tap exited non-zero'

json=$("$MALT_BIN" tap --json)
printf '%s' "$json" | grep -q '"name":"grp/tap"' || fail 'gitlab tap missing from --json'
printf '%s' "$json" | grep -q '"host":"gitlab.com"' || fail 'gitlab tap host not surfaced in --json'
printf '%s' "$json" | grep -q '"commit_sha":null' || fail 'gitlab tap should be unpinned'
printf '%s' "$json" | grep -q 'homebrew-' && fail 'unexpected homebrew- synthesis for a gitlab tap'

# text listing tags the off-github host.
"$MALT_BIN" tap | grep -q '\[gitlab.com\]' || fail 'text listing does not tag the gitlab host'

# 2. --url derives (host, owner, repo).
"$MALT_BIN" tap mygrp/mytap --url https://codeberg.org/o/r >/dev/null 2>&1 ||
  fail 'mt tap --url https://codeberg.org/o/r exited non-zero'
json=$("$MALT_BIN" tap --json)
printf '%s' "$json" | grep -q '"host":"codeberg.org"' || fail 'gitea tap host not surfaced in --json'

# 4. non-github host without a repo fails with a hint.
if "$MALT_BIN" tap other/tap --host gitlab.com >/dev/null 2>"$PREFIX/err.log"; then
  fail 'non-github --host without --repo should fail'
fi
grep -q 'needs an explicit repo' "$PREFIX/err.log" || fail 'missing explicit-repo hint'

# 5. a --host with a scheme/path is rejected.
if "$MALT_BIN" tap bad/tap --host https://gitlab.com --repo bad/tap >/dev/null 2>"$PREFIX/err.log"; then
  fail 'a --host carrying a scheme should be rejected'
fi
grep -q 'Invalid --host' "$PREFIX/err.log" || fail 'missing invalid-host message'

printf 'OK: non-GitHub tap registration persists host, skips homebrew- synthesis, and validates input.\n'
