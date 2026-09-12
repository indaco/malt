#!/usr/bin/env bash
# Regression: the install smoke must (1) classify an upstream artifact 404
# on a tap formula as SKIP, not FAIL, and (2) still uninstall the casks it
# installed when the run ends red. Casks are the only state that escapes
# MALT_PREFIX, so a red run that skips teardown strands an app in
# /Applications and makes every later run SKIP that case.
#
# Drives the real smoke with MT_BIN pointed at a stub malt: no network,
# a few seconds.
#
# Usage: scripts/regressions/install-smoke-red-run-reverts-casks-and-skips-upstream-outages-local-smoke-install.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SMOKE="$ROOT/scripts/smokes/local-smoke-install.sh"

T=$(mktemp -d)
MARK="$T/uninstalls"
trap 'rm -rf "$T"' EXIT

cat >"$T/malt" <<STUB
#!/usr/bin/env bash
case "\$*" in
  "install mongodb/brew/mongodb-community") echo "  x Download failed with status 404"; exit 1 ;;
  "install go") echo "  x boom: unclassified"; exit 1 ;;
  "uninstall --cask "*) echo "\$3" >>"$MARK"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$T/malt"

OUT=$(MT_BIN="$T/malt" bash "$SMOKE" 2>&1)
RC=$?

# The red path drops the smoke's own EXIT trap by design: sweep the
# PREFIX/CACHE/LOGDIR it printed so nothing is stranded under /tmp.
# shellcheck disable=SC2046
rm -rf $(grep -oE '/tmp/m[tcl]\.[[:alnum:]]{3}' <<<"$OUT" | sort -u) /tmp/mt_tahoe /tmp/mc_tahoe

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

[[ $RC -eq 1 ]] || fail "expected a red run (rc=1), got rc=$RC"
grep -q 'SKIP  \[smoke.install.tap.mongodb\]' <<<"$OUT" ||
  fail "upstream artifact 404 was not classified SKIP"
grep -qx copilot-cli "$MARK" 2>/dev/null ||
  fail "cask teardown did not run on the red path"

echo "PASS"
