#!/usr/bin/env bash
# Regression: a tap or `--local` formula's `service do ... end` block must
# register a launchd service on install, exactly like a core formula's
# API `service` object does.
#
# The bug: the Ruby-DSL install path parsed only version/url/sha256 and
# committed the keg without ever reaching the def -> ServiceSpec bridge,
# so `mt services list` never showed the keg and `mt services start`
# failed with ServiceNotFound. The upgrade path re-runs the same install
# tail, so it inherited the gap.
#
# Offline: a one-file tarball is planted at the sha-keyed tap-cache path
# so the install skips the download. Registration only writes the plist
# and the services row (plus a read-only `launchctl list` probe); nothing
# is bootstrapped, since the script never runs `services start`.
#
# The behavioural half drives `--local`; the tap path converges on the
# same materialise tail but cannot be reached without a live forge, so
# its hook is pinned statically: the tap resolver must lift the block
# into the payload the tail registers from.

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

PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1
export MALT_NO_EMOJI=1
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

LOCAL_SRC="$ROOT/src/cli/install/local.zig"
TAP_FN=$(awk '/^fn installTapRb\(/,/^}/' "$LOCAL_SRC")
grep -q 'ParsedService.parse(&svc_buf, resp.body)' <<<"$TAP_FN" ||
  fail "the tap resolver no longer lifts the service block from the fetched .rb"
grep -q '\.service = svc.block,' <<<"$TAP_FN" ||
  fail "the tap resolver no longer hands the service block to the install tail"
pass "tap resolver still lifts and forwards the service block"

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db" "$PREFIX/tmp" "$MALT_CACHE/Tap" "$PREFIX/stage/bin"

printf '#!/bin/sh\nexec sleep 3600\n' >"$PREFIX/stage/bin/svcd"
chmod +x "$PREFIX/stage/bin/svcd"
tar -czf "$PREFIX/svcd-1.0.tar.gz" -C "$PREFIX/stage" bin
SHA=$(shasum -a 256 "$PREFIX/svcd-1.0.tar.gz" | cut -d' ' -f1)
cp "$PREFIX/svcd-1.0.tar.gz" "$MALT_CACHE/Tap/$SHA.tar.gz"

cat >"$PREFIX/svcd.rb" <<EOF
class Svcd < Formula
  url "https://example.invalid/svcd-1.0.tar.gz"
  version "1.0"
  sha256 "$SHA"
  service do
    run [opt_bin/"svcd", "--foreground"]
    keep_alive true
    log_path var/"log/svcd.log"
  end
end
EOF
pass "warm tap cache seeded for a local formula with a service block"

"$BIN" install --local "$PREFIX/svcd.rb" >"$PREFIX/install.log" 2>&1 || {
  tail -20 "$PREFIX/install.log" >&2
  fail "install failed"
}
pass "svcd installed"

ROW=$(sqlite3 "$DB" "SELECT keg_name FROM services WHERE name='com.malt.svcd';")
[[ "$ROW" == "svcd" ]] ||
  fail "no services row for svcd after a local install with a service block"
pass "services row registered"

PLIST="$PREFIX/var/malt/services/com.malt.svcd/service.plist"
[[ -f "$PLIST" ]] || fail "plist missing at $PLIST"
grep -q "<string>$PREFIX/opt/svcd/bin/svcd</string>" "$PLIST" ||
  fail "opt_bin/\"svcd\" was not translated to the malt prefix"
grep -q "<string>--foreground</string>" "$PLIST" ||
  fail "literal argv token dropped from ProgramArguments"
pass "plist written with the argv translated to the malt prefix"

echo "PASS: tap/local formula service registered on install"
