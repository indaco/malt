#!/usr/bin/env bash
# Regression: the TUI and the version notifier must not read an inherited
# cache. A test build resolves its cache through the shared guard only.
#
# Usage: scripts/regressions/cache-readers-use-shared-resolver-the-tui-and-the-update-notifier.sh
# Requirements: zig, rg, fd. No network access required.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

rg -q 'test builds drop a notifier cache path outside /tmp' tests/version_notify_test.zig ||
  {
    echo "FAIL: notifier guard test missing"
    exit 1
  }
if rg -n '"MALT_CACHE"' src/tui/; then
  echo "FAIL: src/tui/ resolves MALT_CACHE by hand again"
  exit 1
fi

zig build test-bin >/dev/null
BIN=zig-out/test-bin/version_notify_test
[[ -x "$BIN" ]] || {
  echo "FAIL: $BIN not built"
  exit 1
}

# Outside /tmp on purpose: a test build must not honour it.
SENT=$(mktemp -d "$HOME/.mt_notify_guard.XXXXXX")
trap 'rm -rf "$SENT"' EXIT
mkdir -p "$SENT/home"

env -u MALT_PREFIX -u XDG_CACHE_HOME -u CI MALT_CACHE="$SENT/cache" HOME="$SENT/home" "$BIN" ||
  {
    echo "FAIL: version_notify_test failed with an inherited cache"
    exit 1
  }

if [[ -n "$(fd -H -t f . "$SENT")" ]]; then
  echo "FAIL: notifier tests wrote under the inherited cache: $(fd -H -t f . "$SENT")"
  exit 1
fi
echo "OK: cache readers stay off an inherited cache"
