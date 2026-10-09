#!/usr/bin/env bash
# Regression: `reinstall` refuses every named package that is not installed,
# not only the first. A later missing name must never reach install, where
# --force would install it fresh.
#
# Offline throughout: nothing reaches the network, before or after the fix.
#
# Exits 0 when the bug is absent, non-zero (with a clear message) when present.

set -euo pipefail

B=${MALT_BIN:-./zig-out/bin/mt}
P=$(mktemp -d /tmp/mt_reinstall_extra.XXXXXX)
trap 'rm -rf "$P"' EXIT
export MALT_PREFIX=$P MALT_CACHE=$P/cache
mkdir -p "$P/db" "$P/cache" "$P/tmp"
"$B" --offline uses x >/dev/null 2>&1 || true
sqlite3 "$P/db/malt.db" "INSERT INTO kegs(name,full_name,version,store_sha256,cellar_path) VALUES('wget','wget','1.24','a','$P/Cellar/wget/1.24');
  INSERT INTO casks(token,name,version,url) VALUES('firefox','firefox','120.0','https://x.invalid/f.dmg');"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

check() { # $1 = expected stderr text, rest = argv
  local want=$1 rc=0 err
  shift
  err=$("$B" reinstall --dry-run --offline "$@" 2>&1 >/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "reinstall $* exited 0"
  grep -q "$want" <<<"$err" || fail "reinstall $*: want '$want', got: $err"
  ! grep -q 'not cached' <<<"$err" || fail "reinstall $* reached install: $err"
}

check 'zzz-not-installed is not installed' wget zzz-not-installed
check 'firefox is not installed' --formula wget firefox
check 'separately' wget firefox
check 'wget is not installed' --casks wget zzz-not-installed
echo PASS
