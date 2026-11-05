#!/usr/bin/env bash
# Regression: the installer must not claim "malt is ready!" while
# <prefix>/bin is off PATH. Commands that `malt install` links would not
# resolve, and a system binary of the same name would run instead. With the
# prefix bin on PATH the banner stays. The printed profile line must also
# work when pasted: it is run here, in a throwaway HOME, and read back.
#
# The default prefix (/opt/malt) is not run: it would touch the live prefix.
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

# Minimal release. The stub records the MALT_PREFIX it sees on `shellenv`
# and prints no shell code, so a sourced profile line stays harmless.
rel="$T/rel/v9.9.9"
mkdir -p "$rel" "$T/stage" "$T/home"
cat >"$T/stage/malt" <<STUB
#!/bin/sh
if [ "\$1" = shellenv ]; then
  printf '%s' "\${MALT_PREFIX-unset}" >"$T/seen"
  exit 0
fi
echo malt 9.9.9
STUB
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

PFX="$T/pfx"
BIN="$T/bin"
# $1 = PATH head, $2 = login shell
run() {
  env -i HOME="$T/home" USER="$USER" SHELL="${2:-/bin/zsh}" \
    PATH="$1/usr/bin:/bin:/usr/sbin:/sbin" \
    PREFIX="$PFX" INSTALL_DIR="$BIN" MALT_ALLOW_UNVERIFIED=1 NO_COLOR=1 \
    MALT_TEST_RELEASES_URL="http://127.0.0.1:${PORT}" \
    MALT_TEST_API_URL="http://127.0.0.1:${PORT}/latest.json" \
    "${RUNNER:-bash}" "$T/install.sh" 2>&1
}

# The 4-space line after the last marker line, without its indent. The
# INSTALL_DIR warning prints the same marker first.
line_after() { # $1 = output, $2 = marker
  local l
  l=$(awk -v m="$2" '$0 ~ m { getline; l = $0 } END { print l }' <<<"$1")
  printf '%s' "${l#    }"
}

# Run the printed profile line in a fresh HOME, then source the file it
# wrote in a clean shell: the prefix the next malt call sees must be PFX.
paste_and_source() { # $1 = output, $2 = shell binary, $3 = profile file
  local h="$T/paste_$$_$RANDOM" line
  mkdir -p "$h"
  line=$(line_after "$1" 'Add this to your shell profile:')
  HOME="$h" "$2" -c "$line" || fail "$2 could not run the printed line: $line" "$1"
  [ -f "$h/$3" ] || fail "printed line did not write profile $3" "$1"
  [ "$(<"$h/$3")" = "$(line_after "$1" 'Then apply it to this shell:')" ] ||
    fail "profile $3 differs from the apply line" "$1"
  rm -f "$T/seen"
  env -i HOME="$h" PATH=/usr/bin:/bin "$2" -c ". '$h/$3'; printf '%s' \"\${MALT_PREFIX-unset}\" >'$T/exported'" ||
    fail "$2 could not source profile $3" "$1"
  [ "$(<"$T/seen")" = "$PFX" ] || fail "shellenv saw MALT_PREFIX=$(<"$T/seen"), not the install prefix" "$1"
  [ "$(<"$T/exported")" = "$PFX" ] || fail "MALT_PREFIX is not exported after sourcing profile $3" "$1"
}

# --- prefix bin off PATH, malt on PATH
outA=$(run "$BIN:")
grep -qF 'shellenv' <<<"$outA" || fail "no shellenv step when prefix bin is off PATH" "$outA"
! grep -qF 'malt is ready!' <<<"$outA" || fail "ready banner printed with prefix bin off PATH" "$outA"
grep -qF "export MALT_PREFIX=$PFX; eval" <<<"$outA" || fail "non-default prefix is not exported" "$outA"
[ -n "$(line_after "$outA" 'Then apply it to this shell:')" ] || fail "no apply line" "$outA"
paste_and_source "$outA" /bin/zsh .zprofile
outH=$(run "$BIN:" /bin/bash)
paste_and_source "$outH" /bin/bash .bash_profile

outF=$(run "$BIN:" /usr/local/bin/fish)
grep -qF "set -gx MALT_PREFIX $PFX; $BIN/malt shellenv fish | source" <<<"$outF" || fail "fish line missing" "$outF"

# --- a near-miss PATH entry is not the prefix bin
outN=$(run "$PFX/binx:$BIN:")
! grep -qF 'malt is ready!' <<<"$outN" || fail "ready banner printed for a near-miss PATH entry" "$outN"

# --- malt itself off PATH
outI=$(run "")
paste_and_source "$outI" /bin/zsh .zprofile
paste_and_source "$(run "" /bin/bash)" /bin/bash .bash_profile

# --- run as `sh install.sh`: macOS sh is bash in POSIX mode, whose echo expands
# the \n in the profile line unless the installer prints it with printf.
outP=$(RUNNER=/bin/sh run "")
paste_and_source "$outP" /bin/zsh .zprofile

# --- a dir that would need quoting is refused, so no such line is ever printed
BIN="$T/it's a\\n bin"
if outQ=$(run ""); then
  fail "dir that needs quoting was accepted" "$outQ"
fi
grep -qF 'INSTALL_DIR may hold only letters' <<<"$outQ" || fail "no refusal for a dir that needs quoting" "$outQ"
[ ! -e "$BIN" ] || fail "refused dir was created" "$outQ"
BIN="$T/bin"

# --- prefix bin on PATH, with and without a trailing slash on the entry
outB=$(run "$BIN:$PFX/bin/:")
grep -qF 'malt is ready!' <<<"$outB" || fail "ready banner missing with prefix bin on PATH" "$outB"

# --- a trailing slash on PREFIX is dropped
PFX_SAVED=$PFX
PFX="$PFX_SAVED/"
outS=$(run "$BIN:")
PFX=$PFX_SAVED
! grep -qF '//bin' <<<"$outS" || fail "trailing slash on PREFIX reached the output" "$outS"
grep -qF "$PFX/bin is not on your PATH" <<<"$outS" || fail "prefix bin not named in the warning" "$outS"

echo "ok: installer gates the ready banner on <prefix>/bin being on PATH"
