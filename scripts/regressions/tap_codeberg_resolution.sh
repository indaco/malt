#!/usr/bin/env bash
# Lock the Codeberg/Forgejo tap registration + resolution-URL contract,
# no network.
#
# Resolution itself fetches over HTTPS, so it can't run offline through the
# binary; the deterministic, offline-observable contract is the persisted
# browse URL `mt tap --json` projects from (host, owner, repo, forge). That
# URL is exactly what drives resolution, so pinning it here guards the
# Codeberg arm without a live request (the HTTP round-trip is covered by the
# recorded-response integration test `tests/tap_codeberg_resolution_test.zig`).
#
# Pinned behaviour:
#   1. A codeberg.org tap projects a codeberg.org browse URL (not
#      github-shaped), no `homebrew-` synthesis, unpinned.
#   2. A self-hosted Forgejo instance with `--forge codeberg` projects the
#      instance host's browse URL — the hint picks Codeberg where the host
#      name (not codeberg.org) can't.
#
# Usage: scripts/regressions/tap_codeberg_resolution.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

PREFIX=$(mktemp -d -t mt_codeberg.XXXXXX)
mkdir -p "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. codeberg.org tap: codeberg-shaped browse URL, no homebrew- synthesis.
"$MALT_BIN" tap grp/tap --host codeberg.org --repo grp/tap >/dev/null 2>&1 ||
  fail 'mt tap --host codeberg.org --repo grp/tap exited non-zero'

json=$("$MALT_BIN" tap --json)
printf '%s' "$json" | grep -q '"host":"codeberg.org"' || fail 'codeberg.org tap host not surfaced'
printf '%s' "$json" | grep -q '"url":"https://codeberg.org/grp/tap"' ||
  fail 'codeberg.org tap did not project a codeberg.org browse URL'
printf '%s' "$json" | grep -q '"commit_sha":null' || fail 'codeberg.org tap should be unpinned'
printf '%s' "$json" | grep -q 'homebrew-' && fail 'unexpected homebrew- synthesis for a codeberg tap'

# 2. self-hosted Forgejo: --forge codeberg pins Gitea where the host can't.
"$MALT_BIN" tap team/tap --host git.example.org --forge codeberg --repo team/tap >/dev/null 2>&1 ||
  fail 'mt tap --host git.example.org --forge codeberg --repo team/tap exited non-zero'

json=$("$MALT_BIN" tap --json)
printf '%s' "$json" | grep -q '"host":"git.example.org"' || fail 'self-hosted Forgejo host not surfaced'
printf '%s' "$json" | grep -q '"url":"https://git.example.org/team/tap"' ||
  fail '--forge codeberg did not project the instance-host browse URL'

# Forge hint persisted on the row (best-effort: only when sqlite3 is present).
if command -v sqlite3 >/dev/null; then
  stored=$(sqlite3 "$PREFIX/db/malt.db" "SELECT forge FROM taps WHERE name='team/tap';" 2>/dev/null || true)
  [[ "$stored" == "codeberg" ]] || fail "expected stored forge 'codeberg', got '$stored'"
fi

printf 'OK: Codeberg tap registration projects forge-correct URLs and --forge pins self-hosted Forgejo.\n'
