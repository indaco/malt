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
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
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
  PATH="$FAKE_BIN5C:/usr/bin:/bin:/usr/sbin:/sbin" \
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
  PATH="$FAKE_BIN7:/usr/bin:/bin:/usr/sbin:/sbin" \
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
  printf '#!/bin/sh\necho "sudo called: $*" >&2\nexit 97\n' >"$SHIM11/sudo"
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

# ── tests 12, 15, 16: ownership of a bin dir under PREFIX ────────────
# Root creates a missing <prefix>/bin before the prefix step. The installer
# must hand back exactly that dir and the two files it wrote, or malt cannot
# link into it later. It must never chown a dir it did not create. The shim
# only logs and succeeds, so nothing is created under /usr.
run_logging_sudo() {
  local prefix="$1" install_dir="$2" n="$3" test_rc="${4:-}"
  make_release_fixture "$TMP/releases$n" "9.9.9"
  start_server "$TMP/releases$n"
  local shim="$TMP/shim_$n"
  mkdir -p "$shim"
  # `sudo test ! -e` stands in for root's view of the dir: it runs for real, or
  # returns $test_rc (0 = missing, 1 = exists or sudo failed) when the case
  # needs a view the user cannot have.
  local test_line='exec "$@"'
  [ -z "$test_rc" ] || test_line="exit $test_rc"
  # shellcheck disable=SC2016 # $1 and $* belong to the generated shim
  printf '#!/bin/sh\ncase "$1" in test) %s ;; esac\necho "sudo called: $*" >&2\n' "$test_line" >"$shim/sudo"
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

printf '▸ bin dir under a new PREFIX\n'
if [ "$(id -u)" = 0 ] || [ -w /usr ]; then
  printf '  - skipped: running as root, or /usr is writable here\n'
else
  d12="/usr/malt_test_nonexistent_12/bin"
  want12="sudo called: chown -h $USER $d12 $d12/malt $d12/mt"
  run_logging_sudo "/usr/malt_test_nonexistent_12" "$d12" 12
  if grep -qxF "$want12" "$TMP/out.log"; then
    printf '  ✓ bin dir under PREFIX: exact chown argv\n'
    pass=$((pass + 1))
  else
    printf '  ✗ bin dir under PREFIX: expected "%s"\n' "$want12" >&2
    fail=$((fail + 1))
    failures+=("bin-dir-under-prefix")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi

  # A trailing slash on PREFIX must not defeat the match.
  d15="/usr/malt_test_nonexistent_15/bin"
  run_logging_sudo "/usr/malt_test_nonexistent_15/" "$d15" 15
  if grep -qxF "sudo called: chown -h $USER $d15 $d15/malt $d15/mt" "$TMP/out.log"; then
    printf '  ✓ bin dir under PREFIX: trailing slash still matches\n'
    pass=$((pass + 1))
  else
    printf '  ✗ bin dir under PREFIX: trailing slash PREFIX skipped the chown\n' >&2
    fail=$((fail + 1))
    failures+=("bin-dir-prefix-slash")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi

  # An existing bin dir was not made by the installer: leave its owner alone.
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
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
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
  PATH="$FAKE_BIN14:/usr/bin:/bin:/usr/sbin:/sbin" \
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
# The prefix match in the ownership hand-back is a string match. A ".." can
# make a path look like it sits under PREFIX while it names another dir.
printf '▸ ".." in INSTALL_DIR\n'
dd17="$TMP/dd_17"
mkdir -p "$dd17" "$TMP/prefix_17"
make_release_fixture "$TMP/releases17" "9.9.9"
start_server "$TMP/releases17"
rc17=0
env -i \
  HOME="$HOME" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
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

# ── test 18: an existing bin dir behind an unsearchable parent is not new ─
# The user cannot see into the parent, so only root can say the dir exists.
# Root must not chown a dir it did not create. Root ignores modes, so this
# case cannot run as root.
printf '▸ existing bin dir behind a mode-000 parent\n'
if [ "$(id -u)" = 0 ]; then
  printf '  - skipped: running as root\n'
else
  pfx18="$TMP/pfx_18"
  mkdir -p "$pfx18/priv/bin"
  chmod 000 "$pfx18/priv"
  run_logging_sudo "$pfx18" "$pfx18/priv/bin" 18 1
  chmod 755 "$pfx18/priv"
  if ! grep -q 'sudo called: chown -h' "$TMP/out.log"; then
    printf '  ✓ mode-000 parent: existing bin dir not chowned\n'
    pass=$((pass + 1))
  else
    printf '  ✗ mode-000 parent: chown reached a dir the installer did not create\n' >&2
    fail=$((fail + 1))
    failures+=("unsearchable-parent-chown")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── test 19: a bin dir root really creates behind an unsearchable parent ─
# The user cannot see into the parent, but root can and finds the dir missing.
# The hand-back must still happen, or the new dir stays root-owned.
printf '▸ new bin dir behind a mode-000 parent\n'
if [ "$(id -u)" = 0 ]; then
  printf '  - skipped: running as root\n'
else
  pfx19="$TMP/pfx_19"
  mkdir -p "$pfx19/priv"
  chmod 000 "$pfx19/priv"
  run_logging_sudo "$pfx19" "$pfx19/priv/bin" 19 0
  chmod 755 "$pfx19/priv"
  if grep -qF "sudo called: chown -h $USER $pfx19/priv/bin " "$TMP/out.log"; then
    printf '  ✓ mode-000 parent: new bin dir handed back\n'
    pass=$((pass + 1))
  else
    printf '  ✗ mode-000 parent: new bin dir stayed root-owned\n' >&2
    fail=$((fail + 1))
    failures+=("unsearchable-parent-new")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── test 20: a failed `sudo test` fails closed ───────────────────────
# Bad passwords, a prompt timeout or a sudoers refusal make `sudo test` fail.
# That must read as "not new", or root chowns a dir it did not create.
printf '▸ failed sudo test on an existing bin dir\n'
if [ "$(id -u)" = 0 ] || [ -w /usr ]; then
  printf '  - skipped: running as root, or /usr is writable here\n'
else
  run_logging_sudo "/usr" "/usr/bin" 20 1
  if ! grep -Eq 'sudo called: chown .* /usr/bin( |$)' "$TMP/out.log"; then
    printf '  ✓ failed sudo test: no chown of the existing dir\n'
    pass=$((pass + 1))
  else
    printf '  ✗ failed sudo test: chown reached an existing dir\n' >&2
    fail=$((fail + 1))
    failures+=("failed-sudo-test-chown")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── test 21: a symlink through an unsearchable dir reaches an existing dir ─
# The user cannot follow the link, but root can. The dir exists, so there is
# nothing to hand back. The ln line proves the sudo path ran.
printf '▸ bin dir behind a symlink into a mode-000 dir\n'
if [ "$(id -u)" = 0 ]; then
  printf '  - skipped: running as root\n'
else
  pfx21="$TMP/pfx_21"
  hid21="$TMP/hid_21"
  mkdir -p "$pfx21" "$hid21/sub/bin"
  ln -s "$hid21/sub" "$pfx21/link"
  chmod 000 "$hid21"
  chmod 555 "$pfx21"
  run_logging_sudo "$pfx21" "$pfx21/link/bin" 21 1
  chmod 755 "$pfx21" "$hid21"
  if grep -q 'sudo called: ln -sfn' "$TMP/out.log" && ! grep -q 'sudo called: chown -h' "$TMP/out.log"; then
    printf '  ✓ symlink into mode-000 dir: existing dir not chowned\n'
    pass=$((pass + 1))
  else
    printf '  ✗ symlink into mode-000 dir: chown reached an existing dir\n' >&2
    fail=$((fail + 1))
    failures+=("symlink-unsearchable-chown")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

# ── test 22: the source-build site hands the new bin dir back too ────
printf '▸ source build hands back a new bin dir\n'
if [ "$(id -u)" = 0 ] || [ -w /usr ]; then
  printf '  - skipped: running as root, or /usr is writable here\n'
else
  FAKE_REPO22="$TMP/fake-repo-22"
  mkdir -p "$FAKE_REPO22/scripts" "$FAKE_REPO22/src" "$FAKE_REPO22/man"
  cp scripts/install.sh "$FAKE_REPO22/scripts/install.sh"
  printf '// build\n' >"$FAKE_REPO22/build.zig"
  printf '// main\n' >"$FAKE_REPO22/src/main.zig"
  printf '.TH MALT 1\n' >"$FAKE_REPO22/man/malt.1"
  SHIM22="$TMP/shim_22"
  mkdir -p "$SHIM22"
  cp "$FAKE_BIN7/zig" "$SHIM22/zig"
  # shellcheck disable=SC2016 # $1 and $* belong to the generated shim
  printf '#!/bin/sh\ncase "$1" in test) exec "$@" ;; esac\necho "sudo called: $*" >&2\n' >"$SHIM22/sudo"
  chmod +x "$SHIM22/sudo"
  d22="/usr/malt_test_nonexistent_22/bin"
  env -i \
    HOME="$HOME" \
    PATH="$SHIM22:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="/usr/malt_test_nonexistent_22" \
    INSTALL_DIR="$d22" \
    NO_COLOR=1 \
    bash "$FAKE_REPO22/scripts/install.sh" >"$TMP/out.log" 2>&1 || true
  if grep -qxF "sudo called: chown -h $USER $d22 $d22/malt $d22/mt" "$TMP/out.log"; then
    printf '  ✓ source build: new bin dir handed back\n'
    pass=$((pass + 1))
  else
    printf '  ✗ source build: expected the exact chown -h argv for %s\n' "$d22" >&2
    fail=$((fail + 1))
    failures+=("source-build-hand-back")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi

  # Same site, existing bin dir, `sudo test` failing: it must fail closed.
  # The ln line proves the sudo path ran.
  # shellcheck disable=SC2016 # $1 and $* belong to the generated shim
  printf '#!/bin/sh\ncase "$1" in test) exit 1 ;; esac\necho "sudo called: $*" >&2\n' >"$SHIM22/sudo"
  env -i \
    HOME="$HOME" \
    PATH="$SHIM22:/usr/bin:/bin:/usr/sbin:/sbin" \
    USER="$USER" \
    PREFIX="/usr" \
    INSTALL_DIR="/usr/bin" \
    NO_COLOR=1 \
    bash "$FAKE_REPO22/scripts/install.sh" >"$TMP/out.log" 2>&1 || true
  if grep -q 'sudo called: ln -sfn' "$TMP/out.log" && ! grep -Eq 'sudo called: chown .* /usr/bin( |$)' "$TMP/out.log"; then
    printf '  ✓ source build: failed sudo test fails closed\n'
    pass=$((pass + 1))
  else
    printf '  ✗ source build: a failed sudo test reached chown of an existing dir\n' >&2
    fail=$((fail + 1))
    failures+=("source-build-fail-closed")
    sed 's/^/      /' "$TMP/out.log" >&2 || true
  fi
fi

printf '\n── summary ──\n'
printf 'pass: %d\n' "$pass"
printf 'fail: %d\n' "$fail"
if [ "$fail" -gt 0 ]; then
  printf 'failures: %s\n' "${failures[*]}" >&2
  exit 1
fi
