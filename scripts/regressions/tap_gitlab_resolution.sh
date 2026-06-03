#!/usr/bin/env bash
# Lock the GitLab tap registration + resolution-URL contract, no network.
#
# Resolution itself fetches over HTTPS, so it can't run offline through the
# binary; the deterministic, offline-observable contract is the persisted
# browse URL `mt tap --json` projects from (host, owner, repo, forge). That
# URL is exactly what drives resolution, so pinning it here guards the
# GitLab arm without a live request (the HTTP round-trip is covered by the
# recorded-response integration test `tests/tap_gitlab_resolution_test.zig`).
#
# Pinned behaviour:
#   1. A gitlab.com tap projects a gitlab.com browse URL (not github-shaped),
#      no `homebrew-` synthesis, unpinned.
#   2. A custom-domain instance with `--forge gitlab` projects the instance
#      host's GitLab browse URL — the hint, not host sniffing, picks GitLab.
#   3. `--forge` with an unknown provider is rejected.
#   4. `--forge` without `--host`/`--url` is rejected.
#
# Usage: scripts/regressions/tap_gitlab_resolution.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

PREFIX=$(mktemp -d -t mt_gitlab.XXXXXX)
mkdir -p "$PREFIX/db"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# 1. gitlab.com tap: gitlab-shaped browse URL, no homebrew- synthesis.
"$MALT_BIN" tap grp/tap --host gitlab.com --repo grp/tap >/dev/null 2>&1 ||
  fail 'mt tap --host gitlab.com --repo grp/tap exited non-zero'

json=$("$MALT_BIN" tap --json)
printf '%s' "$json" | grep -q '"host":"gitlab.com"' || fail 'gitlab.com tap host not surfaced'
printf '%s' "$json" | grep -q '"url":"https://gitlab.com/grp/tap"' ||
  fail 'gitlab.com tap did not project a gitlab.com browse URL'
printf '%s' "$json" | grep -q '"commit_sha":null' || fail 'gitlab.com tap should be unpinned'
printf '%s' "$json" | grep -q 'homebrew-' && fail 'unexpected homebrew- synthesis for a gitlab tap'

# 2. custom-domain instance: --forge pins GitLab where the host can't.
"$MALT_BIN" tap acme/tap --host code.acme.com --forge gitlab --repo acme/tap >/dev/null 2>&1 ||
  fail 'mt tap --host code.acme.com --forge gitlab --repo acme/tap exited non-zero'

json=$("$MALT_BIN" tap --json)
printf '%s' "$json" | grep -q '"host":"code.acme.com"' || fail 'custom-domain host not surfaced'
printf '%s' "$json" | grep -q '"url":"https://code.acme.com/acme/tap"' ||
  fail '--forge gitlab did not project the instance-host GitLab browse URL'

# Forge hint persisted on the row (best-effort: only when sqlite3 is present).
if command -v sqlite3 >/dev/null; then
  stored=$(sqlite3 "$PREFIX/db/malt.db" "SELECT forge FROM taps WHERE name='acme/tap';" 2>/dev/null || true)
  [[ "$stored" == "gitlab" ]] || fail "expected stored forge 'gitlab', got '$stored'"
fi

# 3. an unknown --forge is rejected.
if "$MALT_BIN" tap bad/tap --host code.acme.com --forge bogus --repo bad/tap >/dev/null 2>"$PREFIX/err.log"; then
  fail 'an unknown --forge value should be rejected'
fi
grep -q "Unknown --forge" "$PREFIX/err.log" || fail 'missing unknown-forge message'

# 4. --forge without a host is rejected.
if "$MALT_BIN" tap bad/tap --forge gitlab --repo bad/tap >/dev/null 2>"$PREFIX/err.log"; then
  fail '--forge without --host/--url should be rejected'
fi
grep -q -- '--forge requires --host or --url' "$PREFIX/err.log" || fail 'missing forge-needs-host message'

printf 'OK: GitLab tap registration projects forge-correct URLs and --forge pins custom-domain instances.\n'
