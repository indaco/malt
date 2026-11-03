#!/usr/bin/env bash
# Regression: the installer must not claim "malt is ready!" while
# <prefix>/bin is off PATH. Commands that `malt install` links would not
# resolve, and a system binary of the same name would run instead. With the
# prefix bin on PATH the banner stays.
#
# Usage: scripts/regressions/install-sh-ready-without-prefix-on-path-gh1258.sh
# Requirements: python3, curl. Loopback network only.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
command -v python3 >/dev/null 2>&1 || {
  echo "python3 required" >&2
  exit 2
}

T=$(mktemp -d /tmp/mt_readypath.XXXXXX)
srv=""
cleanup() {
  if [ -n "$srv" ]; then
    disown "$srv" 2>/dev/null || true
    kill "$srv" 2>/dev/null || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1"
  echo "--- installer output ---"
  echo "$2"
  exit 1
}

# Minimal release: a tarball with an executable `malt` and its checksum.
rel="$T/rel/v9.9.9"
mkdir -p "$rel" "$T/stage" "$T/home"
printf '#!/bin/sh\necho malt 9.9.9\n' >"$T/stage/malt"
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

# A copy outside the repo, or the installer takes the source-build branch.
cp "$ROOT/scripts/install.sh" "$T/install.sh"

run() { # $1 = PATH head
  env -i HOME="$T/home" USER="$USER" SHELL=/bin/zsh \
    PATH="$1/usr/bin:/bin:/usr/sbin:/sbin" \
    PREFIX="$T/pfx" INSTALL_DIR="$T/bin" MALT_ALLOW_UNVERIFIED=1 NO_COLOR=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    bash "$T/install.sh" 2>&1
}

outA=$(run "$T/bin:")
grep -qF 'shellenv' <<<"$outA" || fail "no shellenv step when prefix bin is off PATH" "$outA"
! grep -qF 'malt is ready!' <<<"$outA" || fail "ready banner printed with prefix bin off PATH" "$outA"
grep -qF "MALT_PREFIX=$T/pfx" <<<"$outA" || fail "non-default prefix missing from the shellenv line" "$outA"

# A trailing slash on the PATH entry still counts as on PATH.
outB=$(run "$T/bin:$T/pfx/bin/:")
grep -qF 'malt is ready!' <<<"$outB" || fail "ready banner missing with prefix bin on PATH" "$outB"

echo "ok: installer gates the ready banner on <prefix>/bin being on PATH"
