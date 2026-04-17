#!/usr/bin/env bash
# scripts/test/install_sh_test.sh — fail-closed regression tests
#
# Exercises the integrity-check paths in scripts/install.sh against a
# local HTTP fixture server. Locks in Finding #5 of the 2026-04-17
# audit: every failure mode that could otherwise silently install an
# attacker-supplied tarball must exit non-zero with nothing installed.
#
# Paths covered:
#   1. missing checksums.txt          → fail, no binary installed
#   2. archive name not listed in it  → fail, no binary installed
#   3. SHA256 mismatch                → fail, no binary installed
#   4. happy path                     → success, binary installed
#
# Usage:
#   ./scripts/test/install_sh_test.sh
#
# Requirements: python3 on PATH (used for the fixture HTTP server).
# The cosign signature path is bypassed via MALT_ALLOW_UNVERIFIED=1 so
# the harness doesn't need to materialise a live Sigstore certificate.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

command -v python3 >/dev/null 2>&1 || {
  echo "python3 required for install.sh regression tests" >&2
  exit 2
}

TMP=$(mktemp -d /tmp/malt_install_sh_test.XXXXXX)
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    disown "$SERVER_PID" 2>/dev/null || true
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# Copy install.sh to a location far from the malt repo. install.sh's
# own "Local repository detected?" probe uses `dirname $BASH_SOURCE/..`
# to find `build.zig`; running it from inside the repo would take the
# build-from-source branch and never hit the checksum/sig paths we're
# trying to exercise.
cp scripts/install.sh "$TMP/install.sh"
INSTALLER="$TMP/install.sh"

pass=0
fail=0
failures=()

start_server() {
  local root="$1"
  PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("",0));print(s.getsockname()[1]);s.close()')
  python3 -m http.server --directory "$root" --bind 127.0.0.1 "$PORT" >/dev/null 2>&1 &
  SERVER_PID=$!
  # Wait for listen.
  for _ in $(seq 1 50); do
    if curl -fsSL "http://127.0.0.1:${PORT}/" >/dev/null 2>&1; then return; fi
    sleep 0.05
  done
  echo "fixture http server never came up" >&2
  exit 2
}
stop_server() {
  if [ -n "$SERVER_PID" ]; then
    # Suppress the shell's "Terminated: 15" job-control banner by
    # detaching before killing.
    disown "$SERVER_PID" 2>/dev/null || true
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}

# Build a minimal "release" layout: a tarball that install.sh will
# accept on the happy path. Every test case starts from this snapshot
# and then mutates it (deletes checksums, scrambles entries, etc).
make_release_fixture() {
  local dest="$1"
  local version="$2"
  rm -rf "$dest"
  mkdir -p "$dest/v${version}"
  local archive_name="malt_${version}_darwin_all.tar.gz"
  local stage="$TMP/stage_${version}"
  rm -rf "$stage"
  mkdir -p "$stage/malt_${version}_darwin_all"
  # Minimal contents: install.sh does a `find -name malt -type f -perm
  # -u+x` after extraction. A shell script with the exec bit satisfies
  # it without requiring a real binary.
  cat >"$stage/malt_${version}_darwin_all/malt" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$stage/malt_${version}_darwin_all/malt"
  tar -C "$stage" -czf "$dest/v${version}/${archive_name}" "malt_${version}_darwin_all"
  # Correct checksum so the happy path passes. install.sh itself uses
  # /usr/bin/shasum; the fixture generator avoids it because some
  # developer environments ship a broken perl-backed shasum ahead of
  # it on PATH. Use openssl for deterministic hashing regardless.
  local hash
  hash=$(/usr/bin/openssl dgst -sha256 "$dest/v${version}/${archive_name}" | awk '{print $NF}')
  printf '%s  %s\n' "$hash" "$archive_name" >"$dest/v${version}/checksums.txt"
  # GitHub API shape for the /releases/latest endpoint.
  cat >"$dest/latest.json" <<JSON
{"tag_name": "v${version}", "name": "${version}"}
JSON
}

run_installer() {
  local prefix="$TMP/prefix_$RANDOM"
  local install_dir="$TMP/bin_$RANDOM"
  mkdir -p "$prefix" "$install_dir"
  local rc=0
  # Force a minimal PATH so the test is stable across dev machines
  # that shadow `shasum` or `curl` with broken homebrew/nanobrew
  # binaries ahead of the system install.
  env -i \
    HOME="$HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="$prefix" \
    INSTALL_DIR="$install_dir" \
    MALT_ALLOW_UNVERIFIED=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    NO_COLOR=1 \
    bash "$INSTALLER" >"$TMP/out.log" 2>&1 || rc=$?
  # Caller wants rc, prefix, install_dir. Use distinct separators so
  # downstream parsers never trip on embedded ':' (there aren't any
  # here, but future paths may grow).
  printf '%s|%s|%s\n' "$rc" "$prefix" "$install_dir"
}

case_result() {
  local name="$1" expect="$2" got="$3"
  if [ "$got" = "$expect" ]; then
    printf '  ✓ %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  ✗ %s (expected rc=%s, got rc=%s)\n' "$name" "$expect" "$got" >&2
    fail=$((fail + 1))
    failures+=("$name")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
}

split_result() {
  local line="$1"
  RC=${line%%|*}
  local rest=${line#*|}
  # We only track the install_dir side — callers assert on the
  # binary landing (or not) there. The prefix dir is populated by
  # run_installer but never inspected after the fact.
  INSTALL_DIR_USED=${rest#*|}
}

# ── test 1: happy path ────────────────────────────────────────────────
printf '▸ happy path\n'
make_release_fixture "$TMP/releases1" "9.9.9"
start_server "$TMP/releases1"
split_result "$(run_installer)"
stop_server
case_result "happy path: rc=0" 0 "$RC"
if [ -x "$INSTALL_DIR_USED/malt" ]; then
  printf '  ✓ happy path: binary installed\n'
  pass=$((pass + 1))
else
  printf '  ✗ happy path: binary NOT installed at %s\n' "$INSTALL_DIR_USED/malt" >&2
  fail=$((fail + 1))
  failures+=("binary-missing")
fi

# ── test 2: missing checksums.txt ────────────────────────────────────
printf '▸ missing checksums.txt\n'
make_release_fixture "$TMP/releases2" "9.9.9"
rm "$TMP/releases2/v9.9.9/checksums.txt"
start_server "$TMP/releases2"
split_result "$(run_installer)"
stop_server
if [ "$RC" != "0" ]; then
  printf '  ✓ missing checksums.txt rejected (rc=%s)\n' "$RC"
  pass=$((pass + 1))
else
  printf '  ✗ missing checksums.txt did NOT fail\n' >&2
  fail=$((fail + 1))
  failures+=("missing-checksums-allowed")
fi
[ ! -e "$INSTALL_DIR_USED/malt" ] || {
  printf '  ✗ missing checksums.txt: artifact landed anyway (%s)\n' "$INSTALL_DIR_USED/malt" >&2
  fail=$((fail + 1))
  failures+=("missing-checksums-artifact")
}

# ── test 3: archive name not listed ──────────────────────────────────
printf '▸ archive not listed in checksums.txt\n'
make_release_fixture "$TMP/releases3" "9.9.9"
printf 'deadbeef  other.tar.gz\n' >"$TMP/releases3/v9.9.9/checksums.txt"
start_server "$TMP/releases3"
split_result "$(run_installer)"
stop_server
if [ "$RC" != "0" ]; then
  printf '  ✓ unlisted archive rejected (rc=%s)\n' "$RC"
  pass=$((pass + 1))
else
  printf '  ✗ unlisted archive did NOT fail\n' >&2
  fail=$((fail + 1))
  failures+=("unlisted-allowed")
fi
[ ! -e "$INSTALL_DIR_USED/malt" ] || {
  printf '  ✗ unlisted archive: artifact landed anyway\n' >&2
  fail=$((fail + 1))
  failures+=("unlisted-artifact")
}

# ── test 4: SHA mismatch ─────────────────────────────────────────────
printf '▸ SHA256 mismatch\n'
make_release_fixture "$TMP/releases4" "9.9.9"
archive_name="malt_9.9.9_darwin_all.tar.gz"
printf 'dead000000000000000000000000000000000000000000000000000000000000  %s\n' "$archive_name" \
  >"$TMP/releases4/v9.9.9/checksums.txt"
start_server "$TMP/releases4"
split_result "$(run_installer)"
stop_server
if [ "$RC" != "0" ]; then
  printf '  ✓ SHA mismatch rejected (rc=%s)\n' "$RC"
  pass=$((pass + 1))
else
  printf '  ✗ SHA mismatch did NOT fail\n' >&2
  fail=$((fail + 1))
  failures+=("sha-mismatch-allowed")
fi
[ ! -e "$INSTALL_DIR_USED/malt" ] || {
  printf '  ✗ SHA mismatch: artifact landed anyway\n' >&2
  fail=$((fail + 1))
  failures+=("sha-mismatch-artifact")
}

# ── test 5: source-fallback refuses unverified clone ────────────────
# When the API is unreachable AND `git ls-remote` surfaces no tags,
# install.sh must refuse to build from the default branch. We fake
# both: API URL points at a dead port; a shim `git ls-remote` returns
# empty so no release tag can be resolved offline either.
printf '▸ source fallback refuses unverified clone\n'

FAKE_BIN="$TMP/fake-bin-5"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/git" <<'EOF'
#!/bin/bash
if [ "$1" = "ls-remote" ]; then exit 0; fi
exec /usr/bin/git "$@"
EOF
# install.sh aborts early if zig isn't on PATH. The refuse-unverified
# check happens after that probe but before any real zig invocation —
# a stub that satisfies `command -v` is enough.
cat >"$FAKE_BIN/zig" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKE_BIN/git" "$FAKE_BIN/zig"

prefix5="$TMP/prefix_5"
install_dir5="$TMP/bin_5"
mkdir -p "$prefix5" "$install_dir5"
rc5=0
env -i \
  HOME="$HOME" \
  PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
  USER="$USER" \
  PREFIX="$prefix5" \
  INSTALL_DIR="$install_dir5" \
  MALT_ALLOW_UNVERIFIED=1 \
  MALT_TEST_RELEASES_URL="http://127.0.0.1:1" \
  MALT_TEST_API_URL="http://127.0.0.1:1/unreachable" \
  NO_COLOR=1 \
  bash "$INSTALLER" >"$TMP/out.log" 2>&1 || rc5=$?

if [ "$rc5" != "0" ]; then
  printf '  ✓ unverified source clone rejected (rc=%s)\n' "$rc5"
  pass=$((pass + 1))
else
  printf '  ✗ unverified source clone did NOT fail\n' >&2
  fail=$((fail + 1))
  failures+=("source-fallback-allowed")
  sed 's/^/      /' "$TMP/out.log" >&2 || true
fi
[ ! -e "$install_dir5/malt" ] || {
  printf '  ✗ source fallback: artifact landed anyway\n' >&2
  fail=$((fail + 1))
  failures+=("source-fallback-artifact")
}
if grep -q "MALT_ALLOW_UNVERIFIED_SOURCE" "$TMP/out.log"; then
  printf '  ✓ refuse message references the opt-out env\n'
  pass=$((pass + 1))
else
  printf '  ✗ refuse message missing the opt-out env hint\n' >&2
  fail=$((fail + 1))
  failures+=("source-fallback-message")
fi

printf '\n── summary ──\n'
printf 'pass: %d\n' "$pass"
printf 'fail: %d\n' "$fail"
if [ "$fail" -gt 0 ]; then
  printf 'failures: %s\n' "${failures[*]}" >&2
  exit 1
fi
