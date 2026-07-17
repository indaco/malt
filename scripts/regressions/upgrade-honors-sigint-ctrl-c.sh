#!/usr/bin/env bash
# Regression: Ctrl-C stops `mt upgrade --dry-run` instead of being swallowed.
#
# The signal handler installed at startup replaces SIGINT's default kill with a
# flag flip, so interruptibility depends on the upgrade audit both wiring
# `http.cancel` (to abort the in-flight fetch) and polling the flag between
# packages. When either is missing, Ctrl-C during a network-bound dry-run does
# nothing and the full keg set is audited to completion.
#
# What this pins end to end: seed N outdated core kegs, start a streaming
# dry-run, send SIGINT the moment the audit emits its first per-package event,
# and assert (a) the process reaps promptly and (b) it emitted FEWER per-package
# events than kegs seeded — i.e. it stopped early. Before the fix the flag is
# ignored: every keg is audited (event count == N) or the run outlives the
# SIGINT and is only killed by the outer timeout. Either way this fails.
#
# The dry-run's blocking wall-clock is a real HTTPS fetch per keg, so this needs
# network to formulae.brew.sh (the bug itself needs it). With no connectivity it
# SKIPs cleanly rather than flaking.
#
# Usage: scripts/regressions/upgrade-honors-sigint-ctrl-c.sh
# Requirements: a built malt binary at $MALT_BIN or zig-out/bin/malt; network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d -t malt_upgrade_sigint.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
unset MALT_OFFLINE NO_COLOR CI

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
skip() {
  printf '  \xe2\x8a\x98 SKIP: %s\n' "$*"
  exit 0
}
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

# Real core formulae — stable, unlikely to vanish. Each must return 200 JSON so
# the audit spends time fetching. Seeded as outdated (version 0.0.1) so every
# one would be a candidate the loop must walk.
FORMULAE=(
  git curl wget jq tree htop tmux vim node ruby go rust cmake make
  openssl@3 sqlite zlib readline pcre2 xz lz4 zstd gmp libyaml
)
N=${#FORMULAE[@]}

# Connectivity probe — one of the seeded names must be reachable.
curl -sfI --max-time 8 "https://formulae.brew.sh/api/formula/jq.json" >/dev/null 2>&1 ||
  skip "no network to formulae.brew.sh"

# Init + migrate the schema, then seed the kegs.
mkdir -p "$PREFIX/db" "$MALT_CACHE"
"$BIN" list >/dev/null 2>&1 || true
DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "malt did not create $DB"

{
  echo "BEGIN;"
  for f in "${FORMULAE[@]}"; do
    printf "INSERT INTO kegs (name, full_name, version, store_sha256, cellar_path) VALUES ('%s','%s','0.0.1','sha-%s','/c/%s/0.0.1');\n" \
      "$f" "$f" "$f" "$f"
  done
  echo "COMMIT;"
} | sqlite3 "$DB"

OUT="$PREFIX/events.ndjson"

# Start the streaming dry-run; capture PID.
"$BIN" --output-format=ndjson upgrade --dry-run >"$OUT" 2>/dev/null &
PID=$!

# Wait until the audit emits its first per-package event (a line carrying a
# "name" field), then interrupt. Bail as SKIP if nothing streams in time — that
# is an environmental stall, not a swallowed signal.
#
# PRECONDITION: this guard only guards while the dry-run emits per-package
# events. Stop emitting them and the SKIP below turns a dead guard green
# instead of failing — re-point the probe at the new observable, never accept
# the SKIP as a pass. (Only the dry-run streams these; the real bulk path
# already reports via a summary footer.)
waited=0
until grep -q '"name":' "$OUT" 2>/dev/null; do
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.2
  waited=$((waited + 1))
  if [[ $waited -ge 60 ]]; then # ~12s
    kill -INT "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    skip "audit produced no events in 12s (network stall)"
  fi
done

kill -INT "$PID" 2>/dev/null || true

# The process must reap promptly after SIGINT. Poll for up to 8s.
reaped=0
for _ in $(seq 1 40); do
  if ! kill -0 "$PID" 2>/dev/null; then
    reaped=1
    break
  fi
  sleep 0.2
done
if [[ $reaped -eq 0 ]]; then
  kill -9 "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true
  fail "SIGINT was swallowed — dry-run did not stop within 8s"
fi
wait "$PID" 2>/dev/null || true
pass "dry-run reaped promptly after SIGINT"

# It must have stopped early: fewer per-package events than kegs seeded.
events=$(grep -c '"name":' "$OUT" 2>/dev/null || echo 0)
if [[ "$events" -ge "$N" ]]; then
  fail "audit walked all $N kegs after SIGINT ($events events) — loop guard missing"
fi
pass "audit stopped early after SIGINT ($events of $N kegs)"

printf '\n\xe2\x9c\x94 upgrade honors SIGINT (Ctrl-C) regression passed\n'
