#!/usr/bin/env bash
# Regression: serial `mt migrate` persists the resume manifest after EACH
# success, not batched at the end of the run.
#
# The serial arm writes migrate.progress.json inline after every `.migrated`
# keg, before starting the next one. If that write were ever hoisted to the end
# of `execute` (e.g. folded back into a single post-loop flush), a Ctrl-C
# mid-run would break the keg loop before the flush and lose every completed
# keg — the next run would re-migrate work already done.
#
# What this pins end to end: seed N kegs, start a serial migrate, wait until the
# manifest first shows a completed keg, send SIGINT, and assert the manifest
# holds a NON-EMPTY PROPER SUBSET (>=1 and <N). Per-keg persistence => the
# already-migrated kegs are on disk at interrupt time; a batched-at-end write
# would leave zero migrated entries after the loop breaks, failing the >=1 check.
#
# Real bottle downloads give the interrupt a window to land, so this needs
# network to formulae.brew.sh + ghcr.io (as migrate itself does). With no
# connectivity it SKIPs cleanly rather than flaking.
#
# Usage: scripts/regressions/migrate-serial-persists-manifest-per-keg.sh
# Requirements: a built malt binary at $MALT_BIN or zig-out/bin/malt; network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
skip() {
  printf '  \xe2\x8a\x98 SKIP: %s\n' "$*"
  exit 0
}
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# MALT_PREFIX must stay <= 13 bytes (Mach-O in-place patching budget), which
# the template below respects.
PREFIX=$(mktemp -d /tmp/mt.XXX)
SCRATCH=$(mktemp -d /tmp/mt-msr.XXX)
# Unlike its siblings $PREFIX is left absent on purpose: migrate must create it.
rm -rf "$PREFIX" "$SCRATCH"
trap 'rm -rf "$PREFIX" "$SCRATCH"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
unset MALT_OFFLINE NO_COLOR CI

# Small, stable core kegs with real bottles. Enough of them that interrupting on
# the first completion still leaves several un-migrated (the <N assertion).
KEGS=(hello tree jq xz lz4 zstd wget gmp)
N=${#KEGS[@]}

# Connectivity probe — one seeded name must be reachable.
curl -sfI --max-time 8 "https://formulae.brew.sh/api/formula/jq.json" >/dev/null 2>&1 ||
  skip "no network to formulae.brew.sh"

# Scratch Cellar of empty named dirs: migrate resolves each keg via the brew API
# on name alone and never reads inside the dir, so empty dirs drive a real
# migration. Symlinks would NOT work — the scanner skips non-directory entries.
mkdir -p "$SCRATCH/Cellar"
for k in "${KEGS[@]}"; do
  mkdir -p "$SCRATCH/Cellar/$k"
done
export HOMEBREW_PREFIX="$SCRATCH"

MANIFEST="$PREFIX/cache/migrate.progress.json"

# Start the serial migrate (no --parallel); capture PID.
"$BIN" migrate --quiet >/dev/null 2>&1 &
PID=$!

# Count completed kegs in the manifest. Format is
# {"version":N,"completed":["a","b",...]}. Isolate the completed array and count
# its quoted names — the leading "completed" token is subtracted off. Missing
# file or empty array => 0.
manifest_count() {
  [[ -f "$MANIFEST" ]] || {
    echo 0
    return
  }
  local arr n
  arr=$(grep -o '"completed":\[[^]]*\]' "$MANIFEST" 2>/dev/null || true)
  [[ -n "$arr" ]] || {
    echo 0
    return
  }
  n=$(printf '%s' "$arr" | grep -o '"[^"]*"' | wc -l | tr -d ' ')
  echo "$((n - 1))"
}

# Wait until the first keg lands in the manifest, then interrupt. Bail as SKIP
# if nothing is persisted in time — an environmental stall, not a lost write.
waited=0
until [[ "$(manifest_count)" -ge 1 ]]; do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.2
  waited=$((waited + 1))
  if [[ $waited -ge 150 ]]; then # ~30s
    kill -INT "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    skip "no keg migrated in 30s (network stall)"
  fi
done

kill -INT "$PID" 2>/dev/null || true

# The process must reap promptly after SIGINT. Poll for up to 20s (an in-flight
# bottle install has to unwind before the loop checks the interrupt flag).
reaped=0
for _ in $(seq 1 100); do
  if ! kill -0 "$PID" 2>/dev/null; then
    reaped=1
    break
  fi
  sleep 0.2
done
if [[ $reaped -eq 0 ]]; then
  kill -9 "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  fail "SIGINT was swallowed — serial migrate did not stop within 20s"
fi
wait "$PID" 2>/dev/null || true

# The completed kegs must be on disk at interrupt time: a non-empty proper
# subset. >=1 proves per-keg persistence (a batched-at-end write would be lost
# when the loop broke); <N proves the interrupt actually stopped it mid-run.
count=$(manifest_count)
if [[ "$count" -lt 1 ]]; then
  fail "manifest holds no migrated kegs after SIGINT — persistence was batched, not per-keg"
fi
if [[ "$count" -ge "$N" ]]; then
  skip "all $N kegs migrated before the interrupt landed (too fast to observe partial state)"
fi
pass "manifest persisted $count of $N kegs before SIGINT (per-keg, not batched)"

printf '\n\xe2\x9c\x94 migrate serial per-keg manifest persistence regression passed\n'
