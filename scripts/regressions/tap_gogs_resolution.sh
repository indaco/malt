#!/usr/bin/env bash
# Lock the Gogs tap registration + resolution-URL contract, no network.
#
# Resolution itself fetches over HTTPS, so it can't run offline through the
# binary; the deterministic, offline-observable contract is the persisted
# browse URL `mt tap --json` projects and the stored `--forge gogs` hint.
# The HTTP round-trip (HEAD + the bare pin endpoint) is covered by the
# recorded-response integration test `tests/tap_gogs_resolution_test.zig`.
#
# Pinned behaviour:
#   A self-hosted Gogs instance registered with `--forge gogs` projects the
#   instance host's browse URL (no `homebrew-` synthesis, unpinned) and
#   persists the `gogs` forge hint so resolution and `--pin` route to the
#   Gogs endpoints — Gogs is not name-detectable, so the hint is the only
#   signal.
#
# Usage: scripts/regressions/tap_gogs_resolution.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

PREFIX=$(mktemp -d -t mt_gogs.XXXXXX)
mkdir -p "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# self-hosted Gogs: --forge gogs projects the instance-host browse URL.
"$MALT_BIN" tap team/tap --host git.example.org --forge gogs --repo team/tap >/dev/null 2>&1 ||
  fail 'mt tap --host git.example.org --forge gogs --repo team/tap exited non-zero'

json=$("$MALT_BIN" tap --json)
printf '%s' "$json" | grep -q '"host":"git.example.org"' || fail 'self-hosted Gogs host not surfaced'
printf '%s' "$json" | grep -q '"url":"https://git.example.org/team/tap"' ||
  fail '--forge gogs did not project the instance-host browse URL'
printf '%s' "$json" | grep -q '"commit_sha":null' || fail 'Gogs tap should be unpinned'
printf '%s' "$json" | grep -q 'homebrew-' && fail 'unexpected homebrew- synthesis for a gogs tap'

# Forge hint persisted on the row (best-effort: only when sqlite3 is present).
if command -v sqlite3 >/dev/null; then
  stored=$(sqlite3 "$PREFIX/db/malt.db" "SELECT forge FROM taps WHERE name='team/tap';" 2>/dev/null || true)
  [[ "$stored" == "gogs" ]] || fail "expected stored forge 'gogs', got '$stored'"
fi

printf 'OK: Gogs tap registration projects forge-correct URLs and persists the --forge gogs hint.\n'
