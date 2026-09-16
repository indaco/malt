#!/usr/bin/env bash
# Regression: malt reads MALT_PREFIX, MALT_CACHE, PATH and tokens from the
# environment before doing anything. A setuid/setgid copy of the binary would
# let an unprivileged caller drive all of that as the prefix owner. `main` now
# refuses to start when the real and effective ids differ, before any env read.
#
# Needs root to mint the setuid copy; skips cleanly otherwise so the suite
# stays green in CI. Run as: sudo scripts/regressions/refuse-setuid-wrapper.sh
# No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

if [[ $EUID -ne 0 || -z ${SUDO_USER:-} || $SUDO_USER == root ]]; then
  echo "SKIP: needs 'sudo' from a normal user to mint a setuid copy"
  exit 0
fi

# Root's default mktemp dir sits under a 700 /var/folders path the caller
# cannot traverse; /tmp is world-searchable and not mounted nosuid. Hand the
# dir to the caller at 700 so no other local user can reach the setuid copy.
TMP=$(mktemp -d /tmp/malt-setuid.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
chown "$SUDO_USER" "$TMP"
chmod 700 "$TMP"

cp "$BIN" "$TMP/mt"
chown root "$TMP/mt"
chmod u+s "$TMP/mt"

# Control: the same binary without the setuid bit still runs as the caller.
cp "$BIN" "$TMP/mt-plain"
chown "$SUDO_USER" "$TMP/mt-plain"
chmod 755 "$TMP/mt-plain"
sudo -u "$SUDO_USER" "$TMP/mt-plain" --version >/dev/null || {
  echo "FAIL: control copy without setuid does not run as $SUDO_USER" >&2
  exit 1
}

set +e
ERR=$(sudo -u "$SUDO_USER" "$TMP/mt" --version 2>&1 >/dev/null)
RC=$?
set -e

if [[ $RC -ne 78 ]]; then
  echo "FAIL: setuid copy exited $RC, expected 78 (EX_CONFIG)" >&2
  echo "$ERR" >&2
  exit 1
fi
if [[ $ERR != *"refusing to run with mismatched real/effective uid or gid"* ]]; then
  echo "FAIL: setuid copy exited 78 but without the refusal line:" >&2
  echo "$ERR" >&2
  exit 1
fi

echo "PASS: setuid copy refused with exit 78 and the refusal line on stderr"
