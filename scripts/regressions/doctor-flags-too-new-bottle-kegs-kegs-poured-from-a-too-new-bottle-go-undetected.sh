#!/usr/bin/env bash
# Regression: a keg poured from a bottle built for a newer macOS than the
# host (what bottle selection did before it honoured the host version) went
# unnoticed. `mt doctor` must name it, pointing at `mt reinstall` when a
# bottle for this macOS exists and at `mt uninstall` when none does, and must
# leave a keg poured from the host's own bottle alone.
#
# Hermetic: each keg's recorded digest is matched against a formula document
# seeded under `$MALT_CACHE/api`; `MALT_OFFLINE=1` keeps doctor off the
# network.
#
# Usage: scripts/regressions/doctor-flags-too-new-bottle-kegs-kegs-poured-from-a-too-new-bottle-go-undetected.sh
# Requirements: built malt at $MALT_BIN or zig-out/bin/malt; sqlite3 on PATH.
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
command -v sqlite3 >/dev/null 2>&1 || {
  echo "this regression needs sqlite3 on PATH" >&2
  exit 2
}

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

HOST=$(sw_vers -productVersion | cut -d. -f1)
case "$HOST" in
11) CODENAME=big_sur ;;
12) CODENAME=monterey ;;
13) CODENAME=ventura ;;
14) CODENAME=sonoma ;;
15) CODENAME=sequoia ;;
26) CODENAME=tahoe ;;
*)
  # 27 is the newest tag malt knows, so nothing can be newer than the host.
  echo "SKIP: no known bottle tag is newer than macOS $HOST"
  exit 0
  ;;
esac
ARCH=""
[[ $(uname -m) == arm64 ]] && ARCH=arm64_
NEWER_TAG="${ARCH}golden_gate"
HOST_TAG="${ARCH}${CODENAME}"

PREFIX="/tmp/mt_bottle_host_$$"
rm -rf "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db" "$MALT_CACHE/api"
"$BIN" list >/dev/null 2>&1 || true
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

digest() { printf "$1%.0s" {1..64}; }

# seed <name> <recorded digest> <tag>=<digest>...
seed() {
  local name=$1 sha=$2 files="" sep=""
  shift 2
  for pair in "$@"; do
    files+="$sep\"${pair%%=*}\":{\"cellar\":\":any\",\"url\":\"https://x/$name\",\"sha256\":\"${pair#*=}\"}"
    sep=,
  done
  printf '{"name":"%s","full_name":"%s","versions":{"stable":"1.0"},"revision":0,"dependencies":[],"bottle":{"stable":{"root_url":"https://x","files":{%s}}}}' \
    "$name" "$name" "$files" >"$MALT_CACHE/api/formula_$name.json"
  mkdir -p "$PREFIX/Cellar/$name/1.0/bin"
  sqlite3 "$DB" "INSERT INTO kegs (name, full_name, version, revision, store_sha256, cellar_path, install_reason)
    VALUES ('$name', '$name', '1.0', 0, '$sha', '$PREFIX/Cellar/$name/1.0', 'direct');"
}

A=$(digest a) B=$(digest b) C=$(digest c) D=$(digest d)
seed regnone "$A" "$NEWER_TAG=$A"                  # no bottle for this macOS
seed regreinst "$B" "$NEWER_TAG=$B" "$HOST_TAG=$C" # reinstallable
seed regok "$D" "$HOST_TAG=$D"                     # control

OUT=$("$BIN" doctor --verbose 2>&1 || true)

grep -q 'mt uninstall regnone' <<<"$OUT" ||
  fail "keg with no bottle for this macOS not pointed at mt uninstall"
pass "no-bottle keg flagged with the uninstall remedy"

grep -q 'mt reinstall regreinst' <<<"$OUT" ||
  fail "reinstallable keg not pointed at mt reinstall"
pass "reinstallable keg flagged with the reinstall remedy"

if grep -q regok <<<"$OUT"; then
  fail "keg poured from the host's own bottle was flagged"
fi
pass "host-tag keg left alone"

printf '\n\xe2\x9c\x94 doctor flags kegs poured from a too-new bottle\n'
