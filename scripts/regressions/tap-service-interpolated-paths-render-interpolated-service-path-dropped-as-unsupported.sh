#!/usr/bin/env bash
# Regression: a tap or `--local` formula whose `service do` block
# interpolates a prefix root inside a quoted string (`"#{etc}/x.conf"`)
# must register the service with the root rendered, not drop it.
#
# The bug: the Ruby-block translator refused any token containing `#{`,
# so the common `"--config=#{etc}/..."` idiom installed with "unsupported
# service block" and no service, although the same roots were already
# rendered as bare tokens.
#
# Offline: a one-file tarball is planted at the sha-keyed tap-cache path
# so the install skips the download. Nothing is bootstrapped.

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
# Keeps the developer's own service .env files out of the plist asserts.
export XDG_CONFIG_HOME="$PREFIX/xdg"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1
export MALT_NO_EMOJI=1
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  \xe2\x9c\x93 %s\n' "$*"; }
fail() {
  printf '  \xe2\x9c\x97 %s\n' "$*" >&2
  exit 1
}

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db" "$PREFIX/tmp" "$MALT_CACHE/Tap" "$PREFIX/stage/bin"

printf '#!/bin/sh\nexec sleep 3600\n' >"$PREFIX/stage/bin/svc"
chmod +x "$PREFIX/stage/bin/svc"
tar -czf "$PREFIX/svc-1.0.tar.gz" -C "$PREFIX/stage" bin
SHA=$(shasum -a 256 "$PREFIX/svc-1.0.tar.gz" | cut -d' ' -f1)
cp "$PREFIX/svc-1.0.tar.gz" "$MALT_CACHE/Tap/$SHA.tar.gz"

# Unquoted heredoc for $SHA; `#{` is not special to bash here.
cat >"$PREFIX/svc.rb" <<EOF
class Svc < Formula
  url "https://example.invalid/svc-1.0.tar.gz"
  version "1.0"
  sha256 "$SHA"
  service do
    run [opt_bin/"svc", "--config=#{etc}/svc.conf"]
    log_path "#{var}/log/svc.log"
  end
end
EOF
pass "warm tap cache seeded for a local formula with an interpolating service block"

"$BIN" install --local "$PREFIX/svc.rb" >"$PREFIX/install.log" 2>&1 || {
  tail -20 "$PREFIX/install.log" >&2
  fail "install failed"
}
if grep -q 'unsupported service block' "$PREFIX/install.log"; then
  cat "$PREFIX/install.log" >&2
  fail "service with interpolated paths was dropped"
fi
pass "svc installed without an unsupported-block warning"

ROW=$(sqlite3 "$DB" "SELECT keg_name FROM services WHERE name='com.malt.svc';")
[[ "$ROW" == "svc" ]] || fail "no services row for svc"
pass "services row registered"

PLIST="$PREFIX/var/malt/services/com.malt.svc/service.plist"
[[ -f "$PLIST" ]] || fail "plist missing at $PLIST"
grep -qF -- "<string>--config=$PREFIX/etc/svc.conf</string>" "$PLIST" ||
  fail "#{etc} in an argv element was not rendered to the malt prefix"
grep -qF -- "<string>$PREFIX/var/log/svc.log</string>" "$PLIST" ||
  fail "#{var} in log_path was not rendered to the malt prefix"
pass "plist written with interpolated roots rendered"

echo "PASS: interpolated service paths render on install"
