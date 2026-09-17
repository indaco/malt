#!/usr/bin/env bash
# Regression: a tap raw host that already exhausted one retry budget must not
# be re-dialled for every remaining keg in the same audit.
#
# The bug: `tap.fetchRawFile` kept no memory across calls, so every tap keg
# behind one dead raw host paid the full `net/client` retry budget (4 dials
# plus 1+2+4 s backoff). `mt vulns` fans tap kegs over eight workers, so N
# kegs cost ceil(N / 8) rounds of that budget. The fix records the host after
# the first exhausted budget and fails the remaining kegs immediately.
#
# Gate, no external network: 17 tap kegs (more than two worker rounds) whose
# tap lives on a closed loopback port. Before the fix the walk needs three
# rounds (~22 s); after it, one (~8 s). Exit code and the `unchecked` list are
# the same either way, so the assertion is wall-clock with a wide margin, plus
# an existence guard on the inline unit checks that pin the breaker's shape.
#
# Exits 0 when the dead host is paid for once, non-zero when every keg pays.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MT="$ROOT/zig-out/bin/malt"
if [[ ! -x "$MT" ]]; then
  echo "FAIL: build first (zig build)" >&2
  exit 1
fi

# A trailing slash on TMPDIR would put "//" in the prefix, which malt refuses.
TMP=${TMPDIR:-/tmp}
PREFIX=$(mktemp -d "${TMP%/}/malt-tripped-XXXXXX")
trap 'rm -rf "$PREFIX"' EXIT
mkdir -p "$PREFIX/db" "$PREFIX/cache"
MALT_PREFIX="$PREFIX" "$MT" list >/dev/null 2>&1 || true

# Port 1 is never listened on, so the raw fetch fails at connect and the run
# stays offline. `forge` gitea keeps the loopback host in the raw url (the
# github arm hard-codes its hosts). A recorded commit skips the HEAD walk.
N=17
{
  echo "INSERT INTO taps (name, url, github_owner, github_repo, host, forge) VALUES ('someone/tap', 'https://127.0.0.1:1/someone/tap', 'someone', 'tap', '127.0.0.1:1', 'gitea');"
  for i in $(seq 1 "$N"); do
    echo "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, tap, tap_commit_sha) VALUES ('pkg$i', 'someone/tap/pkg$i', '1.0', 0, '', '/c/x$i', 'someone/tap', '0000000000000000000000000000000000000000');"
  done
} | sqlite3 "$PREFIX/db/malt.db"

START=$(date +%s)
set +e
OUT=$(MALT_PREFIX="$PREFIX" MALT_CACHE="$PREFIX/cache" "$MT" --json vulns 2>/dev/null)
RC=$?
set -e
WALL=$(($(date +%s) - START))

if [[ "$RC" -ne 2 ]]; then
  echo "FAIL: expected exit 2 (every keg unchecked), got rc=$RC $OUT" >&2
  exit 1
fi
SEEN=$(grep -o 'pkg[0-9]*' <<<"$OUT" | sort -u | wc -l | tr -d ' ')
if [[ "$SEEN" -ne "$N" ]]; then
  echo "FAIL: expected $N kegs in unchecked, saw $SEEN: $OUT" >&2
  exit 1
fi
# One retry budget is ~7-8 s; three rounds are ~22 s. 15 s leaves room for a
# loaded box without letting a second round through.
if [[ "$WALL" -gt 15 ]]; then
  echo "FAIL: $N kegs behind one dead host took ${WALL}s; the raw host is not tripping after the first exhausted budget" >&2
  exit 1
fi

# If the inline checks are ever deleted, `zig build test` would still pass.
# Fail loudly instead.
for needle in "TrippedHosts" "does not trip on 404"; do
  if ! grep -Fqs -- "$needle" src/core/tap.zig; then
    echo "FAIL: the per-host breaker unit check '$needle' is missing from src/core/tap.zig" >&2
    exit 1
  fi
done

echo "PASS: a dead tap host is paid for once per run (${WALL}s for $N kegs)"
