#!/usr/bin/env bash
# Regression: with INSTALL_DIR under a PREFIX that needs root, the installer
# must create PREFIX first, so the user creates <prefix>/bin. Pre-fix, root
# created the bin dir and a hand-back guess (taken from one `sudo test`)
# skipped the chown when the first sudo prompt failed.
#
# The sudo shim runs the command as the user, so the proof is in the argv
# log: no sudo call may name the bin dir. The first `test` call fails to
# model a failed first prompt.
#
# Usage: scripts/regressions/install-bin-dir-user-owned-install-sh-bin-dir-hand-back-guesses-ownership.sh
# Requirements: python3, curl. Loopback network only.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
command -v python3 >/dev/null 2>&1 || {
  echo "python3 required" >&2
  exit 2
}
if [ "$(id -u)" = 0 ]; then
  echo "skipped: root never uses sudo"
  exit 0
fi

T=$(mktemp -d /tmp/mt_binown.XXXXXX)
srv=""
cleanup() {
  chmod 755 "$T/ro" 2>/dev/null || true
  if [ -n "$srv" ]; then
    disown "$srv" 2>/dev/null || true
    kill "$srv" 2>/dev/null || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT

# Minimal release: a tarball with an executable `malt` and its checksum.
rel="$T/rel/v9.9.9"
mkdir -p "$rel" "$T/stage" "$T/ro" "$T/shim"
printf '#!/bin/sh\nexit 0\n' >"$T/stage/malt"
chmod +x "$T/stage/malt"
tar -C "$T/stage" -czf "$rel/malt_9.9.9_darwin_all.tar.gz" .
hash=$(/usr/bin/openssl dgst -sha256 "$rel/malt_9.9.9_darwin_all.tar.gz" | awk '{print $NF}')
printf '%s  %s\n' "$hash" malt_9.9.9_darwin_all.tar.gz >"$rel/checksums.txt"
printf '{"tag_name": "v9.9.9", "name": "9.9.9"}\n' >"$T/rel/latest.json"

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("",0));print(s.getsockname()[1]);s.close()')
python3 -m http.server --directory "$T/rel" --bind 127.0.0.1 "$PORT" >/dev/null 2>&1 &
srv=$!
for _ in $(seq 1 50); do
  curl -fsS "http://127.0.0.1:${PORT}/" >/dev/null 2>&1 && break
  sleep 0.05
done

# The read-only parent makes PREFIX need root; the shim opens it first.
chmod 555 "$T/ro"
cat >"$T/shim/sudo" <<SHIM
#!/bin/sh
echo "sudo called: \$*" >>"$T/sudo.log"
if [ "\$1" = test ] && [ ! -e "$T/first" ]; then : >"$T/first"; exit 1; fi
chmod 755 "$T/ro"
exec "\$@"
SHIM
chmod +x "$T/shim/sudo"
: >"$T/sudo.log"

# A copy outside the repo, or the installer takes the source-build branch.
cp "$ROOT/scripts/install.sh" "$T/install.sh"
pfx="$T/ro/pfx"
rc=0
env -i HOME="$HOME" USER="$USER" PATH="$T/shim:/usr/bin:/bin:/usr/sbin:/sbin" \
  PREFIX="$pfx" INSTALL_DIR="$pfx/bin" MALT_ALLOW_UNVERIFIED=1 NO_COLOR=1 \
  MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
  MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
  bash "$T/install.sh" >"$T/out.log" 2>&1 || rc=$?

if [ "$rc" != 0 ] || [ ! -x "$pfx/bin/malt" ]; then
  echo "FAIL: installer rc=$rc, binary missing"
  cat "$T/out.log"
  exit 1
fi
if grep -qF "$pfx/bin" "$T/sudo.log"; then
  echo "FAIL: sudo touched <prefix>/bin:"
  grep -F "$pfx/bin" "$T/sudo.log"
  exit 1
fi
echo "ok: <prefix>/bin is created by the user"
