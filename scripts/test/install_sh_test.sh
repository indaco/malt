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
  chmod -R u+rwx "$TMP" 2>/dev/null || true
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

# A sudo that always refuses. Tests that expect no sudo put it first on
# PATH, so a wrong sudo choice fails the run instead of prompting or
# writing root-owned files.
NOSUDO="$TMP/nosudo"
mkdir -p "$NOSUDO"
printf '#!/bin/sh\necho "sudo called: $*" >&2\nexit 97\n' >"$NOSUDO/sudo"
chmod +x "$NOSUDO/sudo"

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
  # include_man=1 mirrors a post-T-003 tarball (page at the goreleaser
  # path share/man/man1/malt.1); 0 mimics an older binary-only tarball.
  local include_man="${3:-1}"
  rm -rf "$dest"
  mkdir -p "$dest/v${version}"
  local archive_name="malt_${version}_darwin_all.tar.gz"
  local stage="$TMP/stage_${version}"
  rm -rf "$stage"
  mkdir -p "$stage"
  # Minimal contents: install.sh does a `find -name malt -type f -perm
  # -u+x` after extraction. A shell script with the exec bit satisfies
  # it without requiring a real binary.
  cat >"$stage/malt" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$stage/malt"
  if [ "$include_man" = 1 ]; then
    mkdir -p "$stage/share/man/man1"
    printf '.TH MALT 1\n' >"$stage/share/man/man1/malt.1"
  fi
  tar -C "$stage" -czf "$dest/v${version}/${archive_name}" .
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
  # Pass an empty first arg to run without the cosign opt-out.
  local bypass="${1-MALT_ALLOW_UNVERIFIED=1}"
  # Force a minimal PATH so the test is stable across dev machines
  # that shadow `shasum` or `curl` with broken homebrew/nanobrew
  # binaries ahead of the system install.
  env -i \
    HOME="$HOME" \
    PATH="$NOSUDO:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="$prefix" \
    INSTALL_DIR="$install_dir" \
    ${bypass:+"$bypass"} \
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
  # Track both sides: the binary lands in install_dir, the man page
  # under prefix/share/man/man1 — callers assert on each.
  PREFIX_USED=${rest%%|*}
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
MAN1_DIR="$PREFIX_USED/share/man/man1"
if [ -f "$MAN1_DIR/malt.1" ]; then
  printf '  ✓ happy path: man page installed\n'
  pass=$((pass + 1))
else
  printf '  ✗ happy path: man page NOT installed at %s\n' "$MAN1_DIR/malt.1" >&2
  fail=$((fail + 1))
  failures+=("man-missing")
fi
# Reinstall must be able to overwrite the page → the dir is user-owned.
man_owner=$(stat -f '%Su' "$MAN1_DIR" 2>/dev/null || stat -c '%U' "$MAN1_DIR" 2>/dev/null || true)
if [ "$man_owner" = "$USER" ]; then
  printf '  ✓ happy path: man1 dir owned by %s\n' "$USER"
  pass=$((pass + 1))
else
  printf '  ✗ happy path: man1 dir owned by %s, expected %s\n' "$man_owner" "$USER" >&2
  fail=$((fail + 1))
  failures+=("man-ownership")
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
  PATH="$NOSUDO:$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
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
# The assignment must sit on the `bash` side of the pipe, or it never reaches the installer.
if grep -qF '| MALT_ALLOW_UNVERIFIED_SOURCE=1 bash' "$TMP/out.log" &&
  grep -qF 'MALT_ALLOW_UNVERIFIED_SOURCE=1 bash /path/to/install.sh' "$TMP/out.log"; then
  printf '  ✓ refuse message shows the opt-out env on the bash side\n'
  pass=$((pass + 1))
else
  printf '  ✗ refuse message missing the opt-out env hint\n' >&2
  fail=$((fail + 1))
  failures+=("source-fallback-message")
fi

# ── test 5c: the source opt-out lifts the refusal ────────────────────
# Same offline setup as test 5, plus the opt-out. The build may fail later
# on the stubs; only the gate decision matters here.
printf '▸ source fallback honours the opt-out\n'
FAKE_BIN5C="$TMP/fake-bin-5c"
mkdir -p "$FAKE_BIN5C"
cat >"$FAKE_BIN5C/git" <<'EOF'
#!/bin/bash
if [ "$1" = "ls-remote" ]; then exit 0; fi
# Offline clone: create the target dir (last argument) only.
if [ "$1" = "clone" ]; then mkdir -p "${@: -1}"; exit 0; fi
exec /usr/bin/git "$@"
EOF
cp "$FAKE_BIN/zig" "$FAKE_BIN5C/zig"
chmod +x "$FAKE_BIN5C/git" "$FAKE_BIN5C/zig"
mkdir -p "$TMP/prefix_5c" "$TMP/bin_5c"
env -i \
  HOME="$HOME" \
  PATH="$NOSUDO:$FAKE_BIN5C:/usr/bin:/bin:/usr/sbin:/sbin" \
  USER="$USER" \
  PREFIX="$TMP/prefix_5c" \
  INSTALL_DIR="$TMP/bin_5c" \
  MALT_ALLOW_UNVERIFIED_SOURCE=1 \
  MALT_TEST_RELEASES_URL="http://127.0.0.1:1" \
  MALT_TEST_API_URL="http://127.0.0.1:1/unreachable" \
  NO_COLOR=1 \
  bash "$INSTALLER" >"$TMP/out.log" 2>&1 || true
if grep -qF 'cloning default branch without a pinned tag' "$TMP/out.log" &&
  ! grep -qF 'Could not resolve a release tag' "$TMP/out.log"; then
  printf '  ✓ source opt-out: refusal lifted\n'
  pass=$((pass + 1))
else
  printf '  ✗ source opt-out: refusal still raised or no warning\n' >&2
  fail=$((fail + 1))
  failures+=("source-optout")
  sed 's/^/      /' "$TMP/out.log" >&2 || true
fi

# ── test 5b: missing cosign refuses and shows a working bypass ───────
# The test PATH has no cosign, so omitting the opt-out hits the refusal.
printf '▸ missing cosign refuses without opt-out\n'
make_release_fixture "$TMP/releases5b" "9.9.9"
start_server "$TMP/releases5b"
split_result "$(run_installer "")"
stop_server
case_result "missing cosign: rc=1" 1 "$RC"
if [ ! -e "$INSTALL_DIR_USED/malt" ]; then
  printf '  ✓ missing cosign: no artifact installed\n'
  pass=$((pass + 1))
else
  printf '  ✗ missing cosign: artifact landed anyway\n' >&2
  fail=$((fail + 1))
  failures+=("cosign-missing-artifact")
fi
if grep -qF 'cosign is required' "$TMP/out.log" &&
  grep -qF '| MALT_ALLOW_UNVERIFIED=1 bash' "$TMP/out.log" &&
  grep -qF 'MALT_ALLOW_UNVERIFIED=1 bash /path/to/install.sh' "$TMP/out.log"; then
  printf '  ✓ missing cosign: hint shows the opt-out env on the bash side\n'
  pass=$((pass + 1))
else
  printf '  ✗ missing cosign: hint missing or misplaced\n' >&2
  fail=$((fail + 1))
  failures+=("cosign-missing-message")
fi

# ── test 6: tarball without a man page still installs the binary ─────
# Pre-T-003 tarballs carry no man page. The installer must warn and
# keep going — a missing page never blocks a binary install.
printf '▸ tarball without man page\n'
make_release_fixture "$TMP/releases6" "9.9.9" 0
start_server "$TMP/releases6"
split_result "$(run_installer)"
stop_server
case_result "no man page: rc=0" 0 "$RC"
if [ -x "$INSTALL_DIR_USED/malt" ]; then
  printf '  ✓ no man page: binary still installed\n'
  pass=$((pass + 1))
else
  printf '  ✗ no man page: binary NOT installed\n' >&2
  fail=$((fail + 1))
  failures+=("nomanpage-binary-missing")
fi
[ ! -e "$PREFIX_USED/share/man/man1/malt.1" ] || {
  printf '  ✗ no man page: a page appeared from nowhere\n' >&2
  fail=$((fail + 1))
  failures+=("nomanpage-ghost")
}
if grep -qi 'man page' "$TMP/out.log"; then
  printf '  ✓ no man page: install warned\n'
  pass=$((pass + 1))
else
  printf '  ✗ no man page: no warning emitted\n' >&2
  fail=$((fail + 1))
  failures+=("nomanpage-no-warn")
fi

# ── test 7: build-from-source places the committed man page ──────────
# No network: drive the local-repo branch with a fake repo + a fake zig
# that drops an executable at zig-out/bin/malt. Asserts the committed
# man/malt.1 lands under the prefix without going through a tarball.
printf '▸ build-from-source places man page\n'
FAKE_REPO="$TMP/fake-repo-7"
mkdir -p "$FAKE_REPO/scripts" "$FAKE_REPO/src" "$FAKE_REPO/man"
cp scripts/install.sh "$FAKE_REPO/scripts/install.sh"
printf '// build\n' >"$FAKE_REPO/build.zig"
printf '// main\n' >"$FAKE_REPO/src/main.zig"
printf '.TH MALT 1\n' >"$FAKE_REPO/man/malt.1"
FAKE_BIN7="$TMP/fake-bin-7"
mkdir -p "$FAKE_BIN7"
cat >"$FAKE_BIN7/zig" <<'EOF'
#!/bin/bash
# Mimic `zig build`: drop an executable at zig-out/bin/malt under cwd.
mkdir -p zig-out/bin
printf '#!/bin/sh\nexit 0\n' >zig-out/bin/malt
chmod +x zig-out/bin/malt
EOF
chmod +x "$FAKE_BIN7/zig"
prefix7="$TMP/prefix_7"
install_dir7="$TMP/bin_7"
mkdir -p "$prefix7" "$install_dir7"
rc7=0
env -i \
  HOME="$HOME" \
  PATH="$NOSUDO:$FAKE_BIN7:/usr/bin:/bin:/usr/sbin:/sbin" \
  USER="$USER" \
  PREFIX="$prefix7" \
  INSTALL_DIR="$install_dir7" \
  NO_COLOR=1 \
  bash "$FAKE_REPO/scripts/install.sh" >"$TMP/out.log" 2>&1 || rc7=$?
if [ "$rc7" = 0 ] && [ -f "$prefix7/share/man/man1/malt.1" ]; then
  printf '  ✓ build-from-source installed man page\n'
  pass=$((pass + 1))
else
  printf '  ✗ build-from-source did not place man page (rc=%s)\n' "$rc7" >&2
  fail=$((fail + 1))
  failures+=("source-man-missing")
  sed 's/^/      /' "$TMP/out.log" >&2 || true
fi

# ── test 8: a longer entry never shadows the wanted archive ──────────
# checksums.txt is cosign-verified, so a wrong pick was never exploitable -
# but the lookup must not depend on what else the file happens to list. The
# decoy's name merely starts with the wanted one and sits first, so a lookup
# that anchors only the start of the name field takes its bogus hash and the
# install dies on a mismatch that is not there.
printf '▸ prefix-colliding checksum entry\n'
make_release_fixture "$TMP/releases8" "9.9.9"
ck8="$TMP/releases8/v9.9.9/checksums.txt"
archive8="malt_9.9.9_darwin_all.tar.gz"
real8=$(awk '{print $1}' "$ck8")
printf 'dead000000000000000000000000000000000000000000000000000000000000  %s.sig\n%s  %s\n' \
  "$archive8" "$real8" "$archive8" >"$ck8"
start_server "$TMP/releases8"
split_result "$(run_installer)"
stop_server
case_result "prefix-colliding entry: rc=0" 0 "$RC"
if [ -x "$INSTALL_DIR_USED/malt" ]; then
  printf '  ✓ prefix-colliding entry: matched on the whole name\n'
  pass=$((pass + 1))
else
  printf '  ✗ prefix-colliding entry: took the decoy hash\n' >&2
  fail=$((fail + 1))
  failures+=("prefix-collision")
fi

# ── test 9: a missing INSTALL_DIR is created, without escalating ─────
# BSD install(1) does not create parent directories. The nested path also
# guards the sudo decision: the nearest existing ancestor is user-writable,
# so a refusing sudo shim must never be called.
printf '▸ missing install dir\n'
make_release_fixture "$TMP/releases9" "9.9.9"
start_server "$TMP/releases9"
prefix9="$TMP/prefix_9"
install_dir9="$TMP/missing_9/a/bin"
SHIM9="$TMP/shim_9"
mkdir -p "$prefix9" "$SHIM9"
printf '#!/bin/sh\necho "sudo called: $*" >&2\nexit 97\n' >"$SHIM9/sudo"
chmod +x "$SHIM9/sudo"
rc9=0
env -i \
  HOME="$HOME" \
  PATH="$SHIM9:/usr/bin:/bin:/usr/sbin:/sbin" \
  USER="$USER" \
  PREFIX="$prefix9" \
  INSTALL_DIR="$install_dir9" \
  MALT_ALLOW_UNVERIFIED=1 \
  MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
  MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
  NO_COLOR=1 \
  bash "$INSTALLER" >"$TMP/out.log" 2>&1 || rc9=$?
stop_server
case_result "missing install dir: rc=0" 0 "$rc9"
if [ -x "$install_dir9/malt" ] && [ "$(readlink "$install_dir9/mt")" = malt ]; then
  printf '  ✓ missing install dir: malt installed, mt links to malt\n'
  pass=$((pass + 1))
else
  printf '  ✗ missing install dir: malt or the mt link is missing\n' >&2
  fail=$((fail + 1))
  failures+=("missing-install-dir")
fi

# ── test 10: a root-owned ancestor (/usr, SIP-protected) still uses sudo ───────────────────
# Guards the other half of the sudo rule: if it ever dropped sudo for every
# case, test 9 would still pass but /usr/local/bin would fail for users.
printf '▸ root-owned ancestor\n'
if [ "$(id -u)" = 0 ] || [ -w /usr ]; then
  printf '  - skipped: running as root, or /usr is writable here\n'
else
  make_release_fixture "$TMP/releases10" "9.9.9"
  start_server "$TMP/releases10"
  prefix10="$TMP/prefix_10"
  SHIM10="$TMP/shim_10"
  mkdir -p "$prefix10" "$SHIM10"
  printf '#!/bin/sh\necho "sudo called: $*" >&2\nexit 97\n' >"$SHIM10/sudo"
  chmod +x "$SHIM10/sudo"
  rc10=0
  env -i \
    HOME="$HOME" \
    PATH="$SHIM10:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="$prefix10" \
    INSTALL_DIR="/usr/malt_test_nonexistent/bin" \
    MALT_ALLOW_UNVERIFIED=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    NO_COLOR=1 \
    bash "$INSTALLER" >"$TMP/out.log" 2>&1 || rc10=$?
  stop_server
  if [ "$rc10" = 97 ] && grep -q 'sudo called: mkdir -p' "$TMP/out.log"; then
    printf '  ✓ root-owned ancestor: sudo used for mkdir\n'
    pass=$((pass + 1))
  else
    printf '  ✗ root-owned ancestor: expected the sudo shim to run (rc=%s)\n' "$rc10" >&2
    fail=$((fail + 1))
    failures+=("root-ancestor-sudo")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── test 11: a user-creatable bin dir never uses sudo, even if PREFIX does ─
# PREFIX is a path the user cannot create, so sudo stays on for the prefix
# step. The bin dir sits under a writable ancestor: its mkdir must not go
# through sudo, or root owns a directory in the user's tree.
printf '▸ bin dir without sudo while PREFIX needs it\n'
if [ "$(id -u)" = 0 ] || [ -w /usr ]; then
  printf '  - skipped: running as root, or /usr is writable here\n'
else
  make_release_fixture "$TMP/releases11" "9.9.9"
  start_server "$TMP/releases11"
  SHIM11="$TMP/shim_11"
  install_dir11="$TMP/missing_11/a/bin"
  mkdir -p "$SHIM11"
  printf '#!/bin/sh\necho "sudo called: $*" >&2\n' >"$SHIM11/sudo"
  chmod +x "$SHIM11/sudo"
  env -i \
    HOME="$HOME" \
    PATH="$SHIM11:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="/usr/malt_test_nonexistent_prefix" \
    INSTALL_DIR="$install_dir11" \
    MALT_ALLOW_UNVERIFIED=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    NO_COLOR=1 \
    bash "$INSTALLER" >"$TMP/out.log" 2>&1 || true
  stop_server
  if [ -x "$install_dir11/malt" ] && ! grep -q "sudo called: .*$install_dir11" "$TMP/out.log"; then
    printf '  ✓ bin dir without sudo: created and installed as the user\n'
    pass=$((pass + 1))
  else
    printf '  ✗ bin dir without sudo: sudo touched %s\n' "$install_dir11" >&2
    fail=$((fail + 1))
    failures+=("bin-dir-sudo-scope")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── test 11b: a failed PREFIX step leaves no binary behind ───────────
# The prefix step runs before the binary install, so a refused sudo must stop
# the run before anything lands in the bin dir.
printf '▸ failed PREFIX step\n'
if [ "$(id -u)" = 0 ] || [ -w /usr ]; then
  printf '  - skipped: running as root, or /usr is writable here\n'
else
  make_release_fixture "$TMP/releases24" "9.9.9"
  start_server "$TMP/releases24"
  SHIM24="$TMP/shim_24"
  install_dir24="$TMP/bin_24"
  mkdir -p "$SHIM24"
  printf '#!/bin/sh\nexit 97\n' >"$SHIM24/sudo"
  chmod +x "$SHIM24/sudo"
  rc24=0
  env -i \
    HOME="$HOME" \
    PATH="$SHIM24:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="/usr/malt_test_nonexistent_24" \
    INSTALL_DIR="$install_dir24" \
    MALT_ALLOW_UNVERIFIED=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    NO_COLOR=1 \
    bash "$INSTALLER" >"$TMP/out.log" 2>&1 || rc24=$?
  stop_server
  if [ "$rc24" != 0 ] && [ ! -e "$install_dir24/malt" ]; then
    printf '  ✓ failed PREFIX step: nothing installed\n'
    pass=$((pass + 1))
  else
    printf '  ✗ failed PREFIX step: rc=%s, binary present=%s\n' "$rc24" "$([ -e "$install_dir24/malt" ] && echo yes || echo no)" >&2
    fail=$((fail + 1))
    failures+=("failed-prefix-step")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── tests 12, 15, 16: ownership of a bin dir under PREFIX ────────────
# The installer creates PREFIX before the binary, so the user creates a
# missing <prefix>/bin and no hand-back is needed. The logging shim only
# records argv and succeeds, so nothing is created under /usr.
run_logging_sudo() {
  local prefix="$1" install_dir="$2" n="$3"
  make_release_fixture "$TMP/releases$n" "9.9.9"
  start_server "$TMP/releases$n"
  local shim="$TMP/shim_$n"
  mkdir -p "$shim"
  # shellcheck disable=SC2016 # $* belongs to the generated shim
  printf '#!/bin/sh\necho "sudo called: $*" >&2\n' >"$shim/sudo"
  chmod +x "$shim/sudo"
  env -i \
    HOME="$HOME" \
    PATH="$shim:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="$prefix" \
    INSTALL_DIR="$install_dir" \
    MALT_ALLOW_UNVERIFIED=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    NO_COLOR=1 \
    bash "$INSTALLER" >"$TMP/out.log" 2>&1 || true
  stop_server
}

# Stand-in for a PREFIX that needs root: the parent is read-only until the
# sudo shim opens it. The shim then runs the command as the user, so any
# sudo argv naming the bin dir proves root would have created it. The first
# `test` call fails, like a failed first prompt.
# The sudo argv log lands in $TMP/sudo.log.
run_emulating_sudo() {
  local prefix="$1" install_dir="$2" parent="$3" n="$4"
  make_release_fixture "$TMP/releases$n" "9.9.9"
  start_server "$TMP/releases$n"
  local shim="$TMP/shim_$n"
  mkdir -p "$shim" "$parent"
  chmod 555 "$parent"
  cat >"$shim/sudo" <<SHIM
#!/bin/sh
echo "sudo called: \$*" >>"$TMP/sudo.log"
if [ "\$1" = test ] && [ ! -e "$shim/first" ]; then : >"$shim/first"; exit 1; fi
chmod 755 "$parent"
exec "\$@"
SHIM
  chmod +x "$shim/sudo"
  : >"$TMP/sudo.log"
  env -i \
    HOME="$HOME" \
    PATH="$shim:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="$prefix" \
    INSTALL_DIR="$install_dir" \
    MALT_ALLOW_UNVERIFIED=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    NO_COLOR=1 \
    bash "$INSTALLER" >"$TMP/out.log" 2>&1 || true
  stop_server
}

# Pass when the binary landed and no sudo argv names the bin dir. $1 label, $2 failure tag, $3 bin dir.
check_user_created_bin_dir() {
  local label="$1" tag="$2" dir="$3"
  if [ -x "$dir/malt" ] && ! grep -qF "$dir" "$TMP/sudo.log"; then
    printf '  ✓ %s\n' "$label"
    pass=$((pass + 1))
  else
    printf '  ✗ %s: the bin dir was not created by the user\n' "$label" >&2
    fail=$((fail + 1))
    failures+=("$tag")
    cat "$TMP/sudo.log" "$TMP/out.log" | sed 's/^/      /' >&2 || true
  fi
}

printf '▸ bin dir under a PREFIX that needs root\n'
if [ "$(id -u)" = 0 ]; then
  printf '  - skipped: running as root\n'
else
  pfx12="$TMP/ro_12/pfx"
  run_emulating_sudo "$pfx12" "$pfx12/bin" "$TMP/ro_12" 12
  check_user_created_bin_dir "bin dir under PREFIX: created by the user" "bin-dir-under-prefix" "$pfx12/bin"

  # A trailing slash on PREFIX must not change who creates the dir.
  pfx15="$TMP/ro_15/pfx"
  run_emulating_sudo "$pfx15/" "$pfx15/bin" "$TMP/ro_15" 15
  check_user_created_bin_dir "bin dir under PREFIX: trailing slash" "bin-dir-prefix-slash" "$pfx15/bin"

  # Every level of a nested path is the user's.
  pfx23="$TMP/ro_23/pfx"
  run_emulating_sudo "$pfx23" "$pfx23/a/b/bin" "$TMP/ro_23" 23
  check_user_created_bin_dir "bin dir under PREFIX: nested path" "bin-dir-nested" "$pfx23/a/b/bin"
fi

# An existing bin dir was not made by the installer: leave its owner alone.
printf '▸ existing bin dir under PREFIX\n'
if [ "$(id -u)" = 0 ] || [ -w /usr ]; then
  printf '  - skipped: running as root, or /usr is writable here\n'
else
  run_logging_sudo "/usr" "/usr/bin" 16
  if ! grep -Eq 'sudo called: chown .* /usr/bin( |$)' "$TMP/out.log"; then
    printf '  ✓ existing bin dir under PREFIX: owner left alone\n'
    pass=$((pass + 1))
  else
    printf '  ✗ existing bin dir under PREFIX: chown reached a dir the installer did not create\n' >&2
    fail=$((fail + 1))
    failures+=("bin-dir-existing-chown")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── test 25: missing parents of PREFIX are the user's to create ──────
# The nearest existing ancestor decides: a PREFIX under a writable dir needs
# no sudo even when its parent is missing, or root would own the parents.
printf '▸ PREFIX with a missing parent\n'
if [ "$(id -u)" = 0 ] || [ -w /usr ]; then
  printf '  - skipped: running as root, or /usr is writable here\n'
else
  make_release_fixture "$TMP/releases25" "9.9.9"
  start_server "$TMP/releases25"
  rc25=0
  env -i \
    HOME="$HOME" \
    PATH="$NOSUDO:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="$TMP/missing_25/pfx" \
    INSTALL_DIR="$TMP/missing_25/bin" \
    MALT_ALLOW_UNVERIFIED=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    NO_COLOR=1 \
    bash "$INSTALLER" >"$TMP/out.log" 2>&1 || rc25=$?
  stop_server
  if [ "$rc25" = 0 ] && [ -x "$TMP/missing_25/bin/malt" ]; then
    printf '  ✓ PREFIX with a missing parent: installed without sudo\n'
    pass=$((pass + 1))
  else
    printf '  ✗ PREFIX with a missing parent: rc=%s\n' "$rc25" >&2
    fail=$((fail + 1))
    failures+=("prefix-missing-parent")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── test 26: a sticky PREFIX is refused ──────────────────────────────
# chown on /tmp would hand the user a dir that holds other users' entries.
printf '▸ sticky PREFIX\n'
if [ ! -k /tmp ]; then
  printf '  - skipped: /tmp is not sticky here\n'
else
  run_logging_sudo "/tmp" "$TMP/bin_26" 26
  if grep -q 'sticky' "$TMP/out.log" && ! grep -q 'sudo called' "$TMP/out.log" && [ ! -e "$TMP/bin_26/malt" ]; then
    printf '  ✓ sticky PREFIX: refused before any sudo call\n'
    pass=$((pass + 1))
  else
    printf '  ✗ sticky PREFIX: the installer went on\n' >&2
    fail=$((fail + 1))
    failures+=("prefix-sticky")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── test 27: a reinstall into a user-owned PREFIX needs no sudo ──────
# The default /opt/malt sits under a root-owned parent. The existing dir,
# not its parent, decides.
printf '▸ existing user-owned PREFIX under a read-only parent\n'
if [ "$(id -u)" = 0 ]; then
  printf '  - skipped: running as root\n'
else
  mkdir -p "$TMP/ro_27/pfx"
  chmod 555 "$TMP/ro_27"
  make_release_fixture "$TMP/releases27" "9.9.9"
  start_server "$TMP/releases27"
  rc27=0
  env -i \
    HOME="$HOME" \
    PATH="$NOSUDO:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="$TMP/ro_27/pfx" \
    INSTALL_DIR="$TMP/bin_27" \
    MALT_ALLOW_UNVERIFIED=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    NO_COLOR=1 \
    bash "$INSTALLER" >"$TMP/out.log" 2>&1 || rc27=$?
  stop_server
  if [ "$rc27" = 0 ] && [ -x "$TMP/bin_27/malt" ]; then
    printf '  ✓ existing PREFIX: reinstall without sudo\n'
    pass=$((pass + 1))
  else
    printf '  ✗ existing PREFIX: rc=%s, sudo was needed\n' "$rc27" >&2
    fail=$((fail + 1))
    failures+=("prefix-existing-no-sudo")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── test 28: a relative PREFIX is resolved before the source build cds ─
printf '▸ relative PREFIX in a source build\n'
FAKE_REPO28="$TMP/fake-repo-28"
mkdir -p "$FAKE_REPO28/scripts" "$FAKE_REPO28/src" "$FAKE_REPO28/man"
cp scripts/install.sh "$FAKE_REPO28/scripts/install.sh"
printf '// build\n' >"$FAKE_REPO28/build.zig"
printf '// main\n' >"$FAKE_REPO28/src/main.zig"
printf '.TH MALT 1\n' >"$FAKE_REPO28/man/malt.1"
FAKE_BIN28="$TMP/fake-bin-28"
mkdir -p "$FAKE_BIN28" "$TMP/cwd_28"
cp "$FAKE_BIN7/zig" "$FAKE_BIN28/zig"
rc28=0
(cd "$TMP/cwd_28" && env -i \
  HOME="$HOME" \
  PATH="$NOSUDO:$FAKE_BIN28:/usr/bin:/bin:/usr/sbin:/sbin" \
  USER="$USER" \
  PREFIX="rel/pfx" \
  INSTALL_DIR="$TMP/cwd_28/bin" \
  NO_COLOR=1 \
  bash "$FAKE_REPO28/scripts/install.sh" >"$TMP/out.log" 2>&1) || rc28=$?
if [ "$rc28" = 0 ] && [ -f "$TMP/cwd_28/rel/pfx/share/man/man1/malt.1" ]; then
  printf '  ✓ relative PREFIX: created under the caller cwd\n'
  pass=$((pass + 1))
else
  printf '  ✗ relative PREFIX: rc=%s, prefix not under the caller cwd\n' "$rc28" >&2
  fail=$((fail + 1))
  failures+=("relative-prefix")
  sed 's/^/      /' "$TMP/out.log" >&2 || true
fi

# ── tests 29, 30: PREFIX rules ───────────────────────────────────────
# Root creates and chowns PREFIX. A ".." can steer it to another dir, and an
# unexpanded ~ would pin a dir named "~". malt refuses any other byte, an empty
# or "." component, and more than 493 bytes, so the installer must refuse them
# too, or the install works and every later malt call fails.
make_release_fixture "$TMP/releases29" "9.9.9"
start_server "$TMP/releases29"
prefix_run() { # $1 = tag, $2 = prefix, $3 = cwd; output goes to $TMP/out.log
  (cd "$3" && env -i \
    HOME="$HOME" \
    PATH="$NOSUDO:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="$2" \
    LC_ALL=en_US.UTF-8 \
    INSTALL_DIR="$TMP/bin_$1" \
    MALT_ALLOW_UNVERIFIED=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    NO_COLOR=1 \
    bash "$INSTALLER") >"$TMP/out.log" 2>&1
}
prefix_fail() { # $1 = label, $2 = tag, $3 = what went wrong
  printf '  ✗ %s: %s\n' "$1" "$3" >&2
  fail=$((fail + 1))
  failures+=("$2")
  sed 's/^/      /' "$TMP/out.log" >&2 || true
}
# $5 is a fragment of the refusal message: a refusal for the wrong reason
# must not pass.
check_prefix_refused() {
  local label="$1" tag="$2" prefix="$3" watch="$4" expect="$5" rc=0
  prefix_run "$tag" "$prefix" "$watch" || rc=$?
  if [ "$rc" != 0 ] && [ -z "$(command ls -A "$watch")" ] && [ ! -e "$TMP/bin_$tag/malt" ] &&
    grep -qF -- "$expect" "$TMP/out.log"; then
    printf '  ✓ %s: refused, nothing written\n' "$label"
    pass=$((pass + 1))
  else
    prefix_fail "$label" "$tag" "rc=$rc, dir holds: $(command ls -A "$watch"), wanted message: $expect"
  fi
}
check_prefix_accepted() {
  local label="$1" tag="$2" prefix="$3" watch="$4" rc=0
  prefix_run "$tag" "$prefix" "$watch" || rc=$?
  if [ "$rc" = 0 ] && [ -x "$TMP/bin_$tag/malt" ] && [ -d "$prefix" ]; then
    printf '  ✓ %s: installed\n' "$label"
    pass=$((pass + 1))
  else
    prefix_fail "$label" "$tag" "rc=$rc, expected an install"
  fi
}
printf '▸ PREFIX rules\n'
mkdir -p "$TMP/dd_29" "$TMP/cwd_30" "$TMP"/sp_30{,_utf8,_empty,_dot,_reldot,_long,_root,_root2,_ok,_over}
check_prefix_refused '".." in PREFIX' prefix-dotdot "$TMP/dd_29/a/../b" "$TMP/dd_29" 'must not contain a ".." component'
check_prefix_refused 'space in PREFIX' prefix-space "$TMP/sp_30/a b" "$TMP/sp_30" 'may hold only letters'
# A letter range in a case pattern follows the locale: stock bash 3.2 in a
# UTF-8 locale accepts the é unless the letters are spelled out.
check_prefix_refused 'non-ASCII letter in PREFIX' prefix-utf8 "$TMP/sp_30_utf8/malté" "$TMP/sp_30_utf8" 'may hold only letters'
check_prefix_refused 'empty component in PREFIX' prefix-empty "$TMP/sp_30_empty/a//b" "$TMP/sp_30_empty" 'no empty or "." component'
check_prefix_refused '"." component in PREFIX' prefix-dot "$TMP/sp_30_dot/./x" "$TMP/sp_30_dot" 'no empty or "." component'
check_prefix_refused 'relative "./" PREFIX' prefix-reldot './malt' "$TMP/sp_30_reldot" 'no empty or "." component'
# The filesystem root is refused on purpose: malt accepts "/", but the
# installer would chown it to the user.
check_prefix_refused 'PREFIX is /' prefix-root '/' "$TMP/sp_30_root" 'filesystem root'
check_prefix_refused 'PREFIX is //' prefix-root2 '//' "$TMP/sp_30_root2" 'filesystem root'
# From "/", a relative PREFIX must pin to /malt, not //malt (an empty
# component). The sudo shim refuses, so the run stops at the first sudo call
# and nothing is created. Skipped as root, or where / is writable or /malt
# exists: there the installer could really create /malt.
if [ "$(id -u)" = 0 ] || [ -w / ] || [ -e /malt ]; then
  printf '  ~ relative PREFIX from /: skipped, / is writable or /malt exists\n'
else
  prefix_run prefix-fromroot malt / || true
  if grep -qF 'sudo called: mkdir -p /malt' "$TMP/out.log" && ! grep -qF '//malt' "$TMP/out.log" &&
    ! grep -qF 'no empty or' "$TMP/out.log" && [ ! -e /malt ]; then
    printf '  ✓ relative PREFIX from /: pinned to /malt\n'
    pass=$((pass + 1))
  else
    prefix_fail 'relative PREFIX from /' prefix-fromroot 'did not reach the /malt step cleanly'
  fi
fi
# Two long components, so each fits NAME_MAX and only the total length varies.
# 493 bytes is malt's own cap; one more must be refused.
long_comp=$(printf 'a%.0s' $(seq 1 200))
# A prefix of exactly $2 bytes: "$1/<200 bytes>/<tail>".
prefix_of_len() {
  local head="$1/$long_comp" n
  n=$(($2 - ${#head} - 1))
  [ "$n" -ge 1 ] && [ "$n" -le 255 ] || return 1
  printf '%s/%s' "$head" "$(printf 'a%.0s' $(seq 1 "$n"))"
}
p493=$(prefix_of_len "$TMP/sp_30_ok" 493)
p494=$(prefix_of_len "$TMP/sp_30_over" 494)
check_prefix_accepted 'PREFIX of exactly 493 bytes' prefix-493 "$p493" "$TMP/sp_30_ok"
check_prefix_refused 'PREFIX of 494 bytes' prefix-494 "$p494" "$TMP/sp_30_over" 'longer than 493 bytes'
# shellcheck disable=SC2088 # the literal tilde is the input under test
check_prefix_refused 'literal ~ in PREFIX' prefix-tilde '~/.malt' "$TMP/cwd_30" 'starts with "~"'
stop_server

# ── test 13: an unexpanded ~ in INSTALL_DIR is refused ───────────────
# A quoted tilde reaches the script as a literal. Installing into ./~/...
# leaves a dir named "~", and the usual `rm -rf ~` cleanup then removes $HOME.
printf '▸ literal tilde in INSTALL_DIR\n'
cwd13="$TMP/cwd_13"
mkdir -p "$cwd13" "$TMP/prefix_13"
# A fixture release lets an unguarded installer reach the install step.
make_release_fixture "$TMP/releases13" "9.9.9"
start_server "$TMP/releases13"
rc13=0
(cd "$cwd13" && env -i \
  HOME="$HOME" \
  PATH="$NOSUDO:/usr/bin:/bin:/usr/sbin:/sbin" \
  USER="$USER" \
  PREFIX="$TMP/prefix_13" \
  INSTALL_DIR='~/.local/bin' \
  MALT_ALLOW_UNVERIFIED=1 \
  MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
  MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
  NO_COLOR=1 \
  bash "$INSTALLER" >"$TMP/out.log" 2>&1) || rc13=$?
stop_server
if [ "$rc13" != 0 ] && [ -z "$(command ls -A "$cwd13")" ]; then
  printf '  ✓ literal tilde: refused, nothing written\n'
  pass=$((pass + 1))
else
  printf '  ✗ literal tilde: rc=%s, cwd holds: %s\n' "$rc13" "$(command ls -A "$cwd13")" >&2
  fail=$((fail + 1))
  failures+=("literal-tilde")
  sed 's/^/      /' "$TMP/out.log" >&2 || true
fi

# ── test 14: a relative INSTALL_DIR is resolved before the source build cds ─
printf '▸ relative INSTALL_DIR in a source build\n'
FAKE_REPO14="$TMP/fake-repo-14"
mkdir -p "$FAKE_REPO14/scripts" "$FAKE_REPO14/src" "$FAKE_REPO14/man"
cp scripts/install.sh "$FAKE_REPO14/scripts/install.sh"
printf '// build\n' >"$FAKE_REPO14/build.zig"
printf '// main\n' >"$FAKE_REPO14/src/main.zig"
printf '.TH MALT 1\n' >"$FAKE_REPO14/man/malt.1"
FAKE_BIN14="$TMP/fake-bin-14"
mkdir -p "$FAKE_BIN14"
cp "$FAKE_BIN7/zig" "$FAKE_BIN14/zig"
cwd14="$TMP/cwd_14"
mkdir -p "$cwd14" "$TMP/prefix_14"
rc14=0
(cd "$cwd14" && env -i \
  HOME="$HOME" \
  PATH="$NOSUDO:$FAKE_BIN14:/usr/bin:/bin:/usr/sbin:/sbin" \
  USER="$USER" \
  PREFIX="$TMP/prefix_14" \
  INSTALL_DIR="rel/bin" \
  NO_COLOR=1 \
  bash "$FAKE_REPO14/scripts/install.sh" >"$TMP/out.log" 2>&1) || rc14=$?
if [ "$rc14" = 0 ] && [ -x "$cwd14/rel/bin/malt" ] && [ ! -e "$FAKE_REPO14/rel" ]; then
  printf '  ✓ relative INSTALL_DIR: installed under the caller cwd\n'
  pass=$((pass + 1))
else
  printf '  ✗ relative INSTALL_DIR: rc=%s, binary not under the caller cwd\n' "$rc14" >&2
  fail=$((fail + 1))
  failures+=("relative-install-dir")
  sed 's/^/      /' "$TMP/out.log" >&2 || true
fi

# ── test 17: a ".." component in INSTALL_DIR is refused ──────────────
# A ".." component names a different dir than the path shows. The installer
# must refuse it before it writes anything.
printf '▸ ".." in INSTALL_DIR\n'
dd17="$TMP/dd_17"
mkdir -p "$dd17" "$TMP/prefix_17"
make_release_fixture "$TMP/releases17" "9.9.9"
start_server "$TMP/releases17"
rc17=0
env -i \
  HOME="$HOME" \
  PATH="$NOSUDO:/usr/bin:/bin:/usr/sbin:/sbin" \
  USER="$USER" \
  PREFIX="$TMP/prefix_17" \
  INSTALL_DIR="$dd17/a/../b" \
  MALT_ALLOW_UNVERIFIED=1 \
  MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
  MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
  NO_COLOR=1 \
  bash "$INSTALLER" >"$TMP/out.log" 2>&1 || rc17=$?
stop_server
if [ "$rc17" != 0 ] && [ -z "$(command ls -A "$dd17")" ]; then
  printf '  ✓ ".." in INSTALL_DIR: refused, nothing written\n'
  pass=$((pass + 1))
else
  printf '  ✗ ".." in INSTALL_DIR: rc=%s, dir holds: %s\n' "$rc17" "$(command ls -A "$dd17")" >&2
  fail=$((fail + 1))
  failures+=("dotdot-install-dir")
  sed 's/^/      /' "$TMP/out.log" >&2 || true
fi

# ── test 22: the source-build site creates PREFIX before the bin dir ──
printf '▸ source build under a PREFIX that needs root\n'
if [ "$(id -u)" = 0 ]; then
  printf '  - skipped: running as root\n'
else
  FAKE_REPO22="$TMP/fake-repo-22"
  mkdir -p "$FAKE_REPO22/scripts" "$FAKE_REPO22/src" "$FAKE_REPO22/man"
  cp scripts/install.sh "$FAKE_REPO22/scripts/install.sh"
  printf '// build\n' >"$FAKE_REPO22/build.zig"
  printf '// main\n' >"$FAKE_REPO22/src/main.zig"
  printf '.TH MALT 1\n' >"$FAKE_REPO22/man/malt.1"
  SHIM22="$TMP/shim_22"
  mkdir -p "$SHIM22" "$TMP/ro_22"
  chmod 555 "$TMP/ro_22"
  cp "$FAKE_BIN7/zig" "$SHIM22/zig"
  cat >"$SHIM22/sudo" <<SHIM
#!/bin/sh
echo "sudo called: \$*" >>"$TMP/sudo.log"
chmod 755 "$TMP/ro_22"
exec "\$@"
SHIM
  chmod +x "$SHIM22/sudo"
  : >"$TMP/sudo.log"
  pfx22="$TMP/ro_22/pfx"
  env -i \
    HOME="$HOME" \
    PATH="$SHIM22:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="$pfx22" \
    INSTALL_DIR="$pfx22/bin" \
    NO_COLOR=1 \
    bash "$FAKE_REPO22/scripts/install.sh" >"$TMP/out.log" 2>&1 || true
  check_user_created_bin_dir "source build: bin dir created by the user" "source-build-bin-dir" "$pfx22/bin"
fi

# ── test 31: INSTALL_DIR takes only plain paths ─────────────────────
# The installer prints this value in lines the user pastes into any shell. The
# allowlist is what keeps those lines safe, so each shape below holds one
# refused byte class and the rest of the path is plain.
printf '▸ INSTALL_DIR allowlist\n'
ID_RULE='INSTALL_DIR may hold only letters, digits and . _ + - / with no empty or "." component'
ID_REL_HINT='A relative INSTALL_DIR includes the current directory, which must obey the same rule'
mkdir -p "$TMP/w31" "$TMP/w31_pfx" "$TMP/home_31"
make_release_fixture "$TMP/releases31" "9.9.9"
start_server "$TMP/releases31"
sudo -k 2>/dev/null || true

# $1 = INSTALL_DIR, $2 = cwd, $3 = locale or empty, $4 = PREFIX, $5 = login
# shell, $6 = runner. The redirect is on the subshell: a failed cd then leaves
# an empty log, not the log of the previous row.
id_run() {
  (cd "$2" && env -i \
    HOME="$TMP/home_31" \
    PATH="$NOSUDO:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    SHELL="${5:-/bin/zsh}" \
    PREFIX="$4" \
    INSTALL_DIR="$1" \
    ${3:+"LC_ALL=$3"} \
    MALT_ALLOW_UNVERIFIED=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    NO_COLOR=1 \
    "${6:-bash}" "$INSTALLER") >"$TMP/out.log" 2>&1 </dev/null
}
# A refusal prints only its own text. Any byte other than printable ASCII and
# the refusal glyph came from the value, and could drive the terminal.
log_has_raw_bytes() {
  [ -n "$(LC_ALL=C sed 's/✗//g' "$TMP/out.log" | LC_ALL=C tr -d '\n\040-\176')" ]
}
# $4 = watched dir, $5 = locale or empty, $6 = refusal text, $7 = cwd
check_id_refused() {
  local label="$1" tag="$2" dir="$3" watch="$4" locale="$5" expect="$6" cwd="${7:-$4}" rc=0
  # One PREFIX per row: a row that installs must not turn the next ones red.
  local pfx="$TMP/w31_pfx/$tag"
  id_run "$dir" "$cwd" "$locale" "$pfx" || rc=$?
  if [ "$rc" = 1 ] && [ -z "$(command ls -A "$watch")" ] && [ ! -e "$pfx" ] &&
    grep -qF -- "$expect" "$TMP/out.log" && ! log_has_raw_bytes; then
    printf '  ✓ %s: refused, nothing written, no value echoed\n' "$label"
    pass=$((pass + 1))
  else
    prefix_fail "$label" "$tag" "rc=$rc, dir holds: $(command ls -A "$watch"), wanted message: $expect"
  fi
}
id_row() { # $1 = tag, $2 = path below a watched dir, $3 = locale or empty
  local w="$TMP/w31/$1${3:+_$3}"
  mkdir -p "$w"
  check_id_refused "INSTALL_DIR $1${3:+ under $3}" "id-$1${3:+-$3}" "$w/$2" "$w" "$3" "$ID_RULE"
}
for loc in "" en_US.UTF-8; do
  id_row colon 'a:b' "$loc"
  id_row space 'a b' "$loc"
  id_row quote "a'b" "$loc"
  id_row backslash 'a\b' "$loc"
  # shellcheck disable=SC2016 # the literal $(...) is the input under test
  id_row subst 'a$(id)b' "$loc"
  # shellcheck disable=SC2016 # the literal backticks are the input under test
  id_row backtick 'a`id`b' "$loc"
  id_row bang 'a!b' "$loc"
  id_row newline $'a\nb' "$loc"
  id_row trailing-newline $'a\n' "$loc"
  id_row esc $'a\033b' "$loc"
  id_row del $'a\177b' "$loc"
  id_row utf8-c1 $'a\302\235b' "$loc"
  id_row raw-c1 $'a\233b' "$loc"
  id_row non-ascii 'malté' "$loc"
  id_row equals 'a=b' "$loc"
  id_row empty-component 'a//b' "$loc"
  id_row dot-component 'a/./b' "$loc"
done
# A slash-only value strips to empty, which prints an empty PATH entry: the
# current directory.
mkdir -p "$TMP/w31/root" "$TMP/w31/root2"
check_id_refused 'INSTALL_DIR bare /' id-root / "$TMP/w31/root" "" "$ID_RULE"
check_id_refused 'INSTALL_DIR //' id-root2 // "$TMP/w31/root2" "" "$ID_RULE"
# Legacy locales read the bytes as multibyte text, so a range or a class in the
# check would follow the locale. A skip here proves nothing for that locale.
for loc in ko_KR.eucKR ja_JP.SJIS; do
  if locale -a 2>/dev/null | grep -x "$loc" >/dev/null; then
    id_row esc $'a\033b' "$loc"
    id_row clean-non-ascii '人z' "$loc"
  else
    printf '  - skipped: %s not installed\n' "$loc"
  fi
done
# Under bash 3.2 in this locale the strip turns <dir>/<A1> into <dir>, a plain
# path that names another directory. Only a check before the strip refuses it.
if locale -a 2>/dev/null | grep -x ko_KR.eucKR >/dev/null; then
  id_row strip-cut $'\241' ko_KR.eucKR
else
  printf '  - skipped: ko_KR.eucKR not installed\n'
fi
# The check must read the pinned path, or a cwd with a colon reaches PATH.
colon_cwd="$TMP/w31/colon:cwd"
mkdir -p "$colon_cwd"
check_id_refused 'relative INSTALL_DIR under a colon cwd' id-rel-colon rel/bin "$colon_cwd" "" "$ID_RULE"
# A relative value can look plain, so the refusal must name the other input.
space_cwd="$TMP/w31/space cwd"
mkdir -p "$space_cwd"
check_id_refused 'relative INSTALL_DIR under a cwd with a space' id-rel-space rel/bin "$space_cwd" "" "$ID_REL_HINT"
# An absolute value does not use the cwd, so the refusal must not name it.
rc=0
id_run "$space_cwd/a b" "$space_cwd" "" "$TMP/w31_pfx/id-abs-no-hint" || rc=$?
if [ "$rc" = 1 ] && grep -qF -- "$ID_RULE" "$TMP/out.log" && ! grep -qF -- "$ID_REL_HINT" "$TMP/out.log"; then
  printf '  ✓ absolute INSTALL_DIR: refusal does not name the current directory\n'
  pass=$((pass + 1))
else
  prefix_fail 'absolute INSTALL_DIR refusal' id-abs-no-hint "rc=$rc, wanted the rule without: $ID_REL_HINT"
fi
# The ".." refusal runs first, so it must not echo the value either.
dd31="$TMP/w31/dotdot"
mkdir -p "$dd31"
check_id_refused '".." in INSTALL_DIR with ESC' id-dotdot-esc "$dd31/a"$'\033'"b/../c" "$dd31" "" 'must not contain a ".." component'

check_refused_quietly() { # $1 = label, $2 = tag, $3 = prefix, $4 = watched dir, $5 = refusal text
  check_prefix_refused "$1" "$2" "$3" "$4" "$5"
  if log_has_raw_bytes; then
    prefix_fail "$1 echoed the value" "$2-echo" "raw bytes in the output"
  else
    printf '  ✓ %s: no value echoed\n' "$1"
    pass=$((pass + 1))
  fi
}
mkdir -p "$TMP/w31/pfx_dd" "$TMP/w31/pfx_esc"
check_refused_quietly '".." in PREFIX with ESC' prefix-dotdot-esc "$TMP/w31/pfx_dd/a"$'\033'"b/../c" "$TMP/w31/pfx_dd" 'must not contain a ".." component'
check_refused_quietly 'ESC in PREFIX' prefix-esc "$TMP/w31/pfx_esc/a"$'\033'"b" "$TMP/w31/pfx_esc" 'may hold only letters'

# ── test 32: the printed lines for a plain dir, as exact text ───────
printf '▸ printed setup lines\n'
check_text() { # $1 = label, $2 = tag, $3 = got, $4 = wanted
  if [ "$3" = "$4" ]; then
    printf '  ✓ %s\n' "$1"
    pass=$((pass + 1))
  else
    prefix_fail "$1" "$2" "got [$3], wanted [$4]"
  fi
}
lines_after() { LC_ALL=C awk -v m="$1" 'index($0, m) { getline; print }' "$TMP/out.log"; }
for runner in bash /bin/sh; do
  for login in zsh bash fish; do
    tag="$login-$(basename "$runner")"
    d32="$TMP/w31/plain_$tag/a+b.c-d_e"
    p32="$TMP/w31/pfx_$tag"
    rc=0
    id_run "$d32" "$TMP/w31" "" "$p32" "/x/$login" "$runner" || rc=$?
    check_text "$tag: install succeeds" "id-plain-rc-$tag" "$rc" 0
    # The hint is the first marker line; the profile step is the last.
    hint=$(lines_after 'Add this to your shell profile:' | head -n 1)
    profile=$(lines_after 'Add this to your shell profile:' | tail -n 1)
    apply=$(lines_after 'Then apply it to this shell:')
    posix="export MALT_PREFIX=$p32; eval \"\$($d32/malt shellenv)\""
    fishline="set -gx MALT_PREFIX $p32; $d32/malt shellenv fish | source"
    check_text "$tag: PATH hint" "id-hint-$tag" "$hint" "    export PATH=$d32:\"\$PATH\""
    case "$login" in
    zsh)
      check_text "$tag: apply line" "id-apply-$tag" "$apply" "    $posix"
      check_text "$tag: profile line" "id-profile-$tag" "$profile" "    printf '%s\\n' '$posix' >> ~/.zprofile"
      ;;
    bash)
      check_text "$tag: apply line" "id-apply-$tag" "$apply" "    $posix"
      check_text "$tag: profile line" "id-profile-$tag" "$profile" "    printf '%s\\n' '$posix' >> ~/.bash_profile"
      ;;
    fish)
      check_text "$tag: apply line" "id-apply-$tag" "$apply" "    $fishline"
      check_text "$tag: profile line" "id-profile-$tag" "$profile" "    $fishline    # in ~/.config/fish/config.fish"
      ;;
    esac
    hint_cmd="${hint#    }"
    check_text "$tag: hint pasted into bash" "id-paste-bash-$tag" \
      "$(env -i HOME="$TMP/home_31" PATH=/E /bin/bash --noprofile --norc -c "$hint_cmd; printf '%s' \"\$PATH\"")" "$d32:/E"
    check_text "$tag: hint pasted into zsh" "id-paste-zsh-$tag" \
      "$(env -i HOME="$TMP/home_31" PATH=/E /bin/zsh -f -c "$hint_cmd; printf '%s' \"\$PATH\"")" "$d32:/E"
  done
done
# Trailing slashes still work, and never reach PATH or the printed lines.
d32s="$TMP/w31/slashes/bin"
rc=0
id_run "$d32s///" "$TMP/w31" "" "$TMP/w31/pfx_slashes" || rc=$?
check_text 'trailing slashes: install succeeds' id-slashes-rc "$rc" 0
check_text 'trailing slashes: binary installed' id-slashes-bin "$([ -x "$d32s/malt" ] && echo yes)" yes
check_text 'trailing slashes: stripped from the hint' id-slashes-hint \
  "$(lines_after 'Add this to your shell profile:' | head -n 1)" "    export PATH=$d32s:\"\$PATH\""
# From cwd / a plain relative value must not pin to //rel, an empty component.
d32r="$TMP/w31/from_root/bin"
rc=0
id_run "${d32r#/}" / "" "$TMP/w31/pfx_from_root" || rc=$?
check_text 'relative INSTALL_DIR from cwd /: install succeeds' id-from-root-rc "$rc" 0
check_text 'relative INSTALL_DIR from cwd /: binary installed' id-from-root-bin "$([ -x "$d32r/malt" ] && echo yes)" yes
check_text 'relative INSTALL_DIR from cwd /: hint' id-from-root-hint \
  "$(lines_after 'Add this to your shell profile:' | head -n 1)" "    export PATH=$d32r:\"\$PATH\""
stop_server

printf '\n── summary ──\n'
printf 'pass: %d\n' "$pass"
printf 'fail: %d\n' "$fail"
if [ "$fail" -gt 0 ]; then
  printf 'failures: %s\n' "${failures[*]}" >&2
  exit 1
fi
