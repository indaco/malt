#!/usr/bin/env bash
# Regression: a `service do ... end` block that only `name`s a label means
# the formula installs `<keg>/<label>.plist` itself. malt used to refuse
# the block outright, so the daemon was installed but `services start`
# could never find it.
#
# Now the keg's plist is lifted into malt's own rendered service through
# the same validate -> register gate as a `run` block: the row is keyed
# `com.malt.<name>`, the rendered plist lives under `var/malt/services`,
# and the keg file is only ever read. A `Sockets` entry of the
# `SecureSocketWithKey` shape is carried across (launchd owns the socket
# path and exports it into the job's environment); any other launchd key
# refuses and names itself, and a declared plist that is not in the keg
# says so.
#
# Offline: four one-file tarballs are planted at the sha-keyed tap-cache
# path so every install skips the download.

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

DB="$PREFIX/db/malt.db"
mkdir -p "$PREFIX/db" "$PREFIX/tmp" "$MALT_CACHE/Tap"

# mkfix <name> <plist-body-or-empty>: stage bin/<name> plus, when given,
# homebrew.mxcl.<name>.plist at the archive root; tar it, seed the cache
# and write <name>.rb with a name-only service block.
mkfix() {
  local name=$1 body=$2 stage="$PREFIX/stage-$1"
  mkdir -p "$stage/bin"
  printf '#!/bin/sh\nexit 0\n' >"$stage/bin/$name"
  chmod +x "$stage/bin/$name"
  [[ -n "$body" ]] && printf '%s\n' "$body" >"$stage/homebrew.mxcl.$name.plist"
  tar -czf "$PREFIX/$name-1.0.tar.gz" -C "$stage" .
  local sha
  sha=$(shasum -a 256 "$PREFIX/$name-1.0.tar.gz" | cut -d' ' -f1)
  cp "$PREFIX/$name-1.0.tar.gz" "$MALT_CACHE/Tap/$sha.tar.gz"
  # bash 3.2 on the CI runner has no `${var^}`.
  local class
  class=$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')${name:1}
  cat >"$PREFIX/$name.rb" <<EOF
class $class < Formula
  url "https://example.invalid/$name-1.0.tar.gz"
  version "1.0"
  sha256 "$sha"
  service do
    name macos: "homebrew.mxcl.$name"
  end
end
EOF
}

# plist <name> <extra-xml>: a plain launchd plist for <name> with <extra-xml>
# spliced in before the closing dict, in the shape real formulas ship.
plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- shipped by the formula -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>homebrew.mxcl.$1</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PREFIX/opt/$1/bin/$1</string>
    <string>--fg</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FOO</key>
    <string>bar&amp;baz</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
$2
</dict>
</plist>
EOF
}

mkfix good "$(plist good '')"
mkfix sock "$(plist sock '  <key>Sockets</key>
  <dict>
    <key>unix_domain_listener</key>
    <dict>
      <key>SecureSocketWithKey</key>
      <string>SOCK_SOCKET</string>
    </dict>
  </dict>')"
mkfix mach "$(plist mach '  <key>MachServices</key>
  <dict>
    <key>com.example.mach</key>
    <true/>
  </dict>')"
mkfix none ""
pass "warm tap cache seeded for four local formulas that ship their own plist"

for f in good sock mach none; do
  "$BIN" install --local "$PREFIX/$f.rb" >"$PREFIX/$f.log" 2>&1 || {
    tail -20 "$PREFIX/$f.log" >&2
    fail "install $f failed (a shipped plist must never fail the keg)"
  }
done
pass "all four kegs installed"

[[ $(sqlite3 "$DB" "SELECT count(*) FROM services WHERE keg_name='good';") == 1 ]] ||
  fail "good: no service row lifted from the shipped plist"
P=$(sqlite3 "$DB" "SELECT plist_path FROM services WHERE keg_name='good';")
[[ "$P" == "$PREFIX/var/malt/services/com.malt.good/service.plist" ]] ||
  fail "good: plist_path points at $P, not malt's own render"
grep -q "<string>$PREFIX/opt/good/bin/good</string>" "$P" ||
  fail "good: rendered ProgramArguments[0] is not the keg's opt path"
grep -q '<key>FOO</key>' "$P" || fail "good: EnvironmentVariables not carried into the rendered plist"
grep -q '<string>bar&amp;baz</string>' "$P" || fail "good: entity in an environment value not decoded and re-escaped"
grep -q '<string>com.malt.good</string>' "$P" ||
  fail "good: rendered plist does not carry malt's own label"
cmp -s "$PREFIX/stage-good/homebrew.mxcl.good.plist" "$PREFIX/Cellar/good/1.0/homebrew.mxcl.good.plist" ||
  fail "good: the keg's plist was modified"
! grep -q 'could not register service for good' "$PREFIX/good.log" ||
  fail "good: install still refused the shipped plist"
pass "good: shipped plist lifted into a malt-rendered service, keg file untouched"

[[ $(sqlite3 "$DB" "SELECT count(*) FROM services WHERE keg_name='sock';") == 1 ]] ||
  fail "sock: a SecureSocketWithKey socket refused the whole plist"
SP=$(sqlite3 "$DB" "SELECT plist_path FROM services WHERE keg_name='sock';")
grep -q '<key>unix_domain_listener</key>' "$SP" || fail "sock: the socket was not carried into the rendered plist"
grep -q '<string>SOCK_SOCKET</string>' "$SP" || fail "sock: the socket's environment key was not carried"
pass "sock: SecureSocketWithKey socket carried across"

[[ $(sqlite3 "$DB" "SELECT count(*) FROM services WHERE keg_name IN ('mach','none');") == 0 ]] ||
  fail "a refused shipped plist registered a row"
grep -q 'could not register service for mach: .*MachServices' "$PREFIX/mach.log" ||
  fail "mach: refusal does not name the key"
grep -q 'could not register service for none: .*not in the keg' "$PREFIX/none.log" ||
  fail "none: a missing plist is not reported as missing"
pass "refusals name their cause and register nothing"

echo "PASS: a shipped launchd plist is lifted into a malt service, refusals name their cause"
