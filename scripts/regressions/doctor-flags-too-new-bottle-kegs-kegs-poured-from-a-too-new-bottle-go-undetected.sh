#!/usr/bin/env bash
# Regression: a keg poured from a bottle built for a newer macOS than the
# host (what bottle selection did before it honoured the host version) went
# unnoticed. `mt doctor` must name it, pointing at `mt reinstall` when a
# bottle for this macOS exists and at `mt uninstall` when none does, and must
# leave a keg poured from the host's own bottle alone. After `mt update` wipes
# the per-formula documents, the bulk side-car `mt outdated` rebuilds must be
# enough to check a keg; one the side-car no longer lists (it left
# homebrew/core) is judged by its binary alone. A keg whose bottle was rebuilt
# upstream (digest gone) is judged by the macOS floor its own binary declares.
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
ARCH="" SIDECAR=bottles_formula.x86_64.txt
[[ $(uname -m) == arm64 ]] && ARCH=arm64_ SIDECAR=bottles_formula.arm64.txt
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

# macho <path> <major>: a thin Mach-O whose only load command is
# LC_BUILD_VERSION (macOS, minos <major>.0), all the floor check reads.
macho() {
  local x
  x=$(printf '\\x%02x' "$2")
  mkdir -p "$(dirname "$1")"
  printf '%b' '\xcf\xfa\xed\xfe\x0c\x00\x00\x01\x00\x00\x00\x00\x02\x00\x00\x00' \
    '\x01\x00\x00\x00\x18\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' \
    '\x32\x00\x00\x00\x18\x00\x00\x00\x01\x00\x00\x00' \
    "\\x00\\x00$x\\x00\\x00\\x00$x\\x00" '\x00\x00\x00\x00' >"$1"
}

A=$(digest a) B=$(digest b) C=$(digest c) D=$(digest d) E=$(digest e)
seed regnone "$A" "$NEWER_TAG=$A"                  # no bottle for this macOS
seed regreinst "$B" "$NEWER_TAG=$B" "$HOST_TAG=$C" # reinstallable
seed regok "$D" "$HOST_TAG=$D"                     # control
seed reggone "$D" "$HOST_TAG=$D"
rm "$MALT_CACHE/api/formula_reggone.json" # and absent from the side-car
macho "$PREFIX/Cellar/reggone/1.0/bin/tool" 27
seed regside "$A" "$NEWER_TAG=$A"
rm "$MALT_CACHE/api/formula_regside.json"
printf 'regside\t%s=%s\n' "$NEWER_TAG" "$A" >"$MALT_CACHE/api/$SIDECAR"
seed regrebuilt "$E" "$HOST_TAG=$C" # bottle rebuilt since: digest unknown
macho "$PREFIX/Cellar/regrebuilt/1.0/bin/tool" 27
seed regfloorok "$E" "$HOST_TAG=$C"
macho "$PREFIX/Cellar/regfloorok/1.0/bin/tool" "$HOST"

OUT=$("$BIN" doctor --verbose 2>&1 || true)

grep -q 'mt uninstall regnone, dependents first' <<<"$OUT" ||
  fail "keg with no bottle for this macOS not pointed at mt uninstall"
pass "no-bottle keg flagged with the uninstall remedy"

grep -q 'mt reinstall regreinst' <<<"$OUT" ||
  fail "reinstallable keg not pointed at mt reinstall"
pass "reinstallable keg flagged with the reinstall remedy"

if grep -q regok <<<"$OUT"; then
  fail "keg poured from the host's own bottle was flagged"
fi
pass "host-tag keg left alone"

grep -q 'mt uninstall regside' <<<"$OUT" ||
  fail "keg covered only by the bulk side-car not checked"
pass "bulk side-car alone is enough to check a keg"

grep -q 'mt reinstall regrebuilt' <<<"$OUT" ||
  fail "rebuilt keg whose binary needs a newer macOS not flagged"
if grep -q regfloorok <<<"$OUT"; then
  fail "rebuilt keg whose binary fits this macOS was flagged"
fi
pass "rebuilt keg judged by its binary's macOS floor"

grep -q 'mt uninstall reggone, dependents first' <<<"$OUT" ||
  fail "keg that left homebrew/core with a too-new binary not flagged for uninstall"
pass "keg that left homebrew/core judged by its binary"

# The row must be a warning, not an ok carrying text: --json and the TUI key
# on severity, and the exit code is the scripting contract.
set +e
JSON=$("$BIN" doctor --json 2>/dev/null)
RC=$?
set -e
grep -q '"id":"bottles_built_for_a_newer_macos","severity":"warn"' <<<"$JSON" ||
  fail "row not reported as a warning in --json"
[[ $RC -eq 1 ]] || fail "doctor exited $RC with warnings, expected 1"
pass "row is a warning in --json and doctor exits 1"

printf '\n\xe2\x9c\x94 doctor flags kegs poured from a too-new bottle\n'
