#!/usr/bin/env bash
# scripts/e2e/tui_too_new_schema_banner.sh
#
# A prefix DB migrated by a newer malt is refused by every `mt … --json` child
# the dashboard reads. The TUI discards child stderr by design, so the only way
# the reason reaches the user is the dedicated exit code mapped to a banner.
#
# Asserts (8 seeded kegs, schema_version bumped past what the binary supports):
#   - the TUI launches and quits 0 — no crash, no backtrace on the frame;
#   - both the background audit and a tab's blocking read banner the newer
#     database rather than an opaque "ChildFailed".
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/tui_too_new_schema_banner.sh
# Exit:    0 on pass, 1 on failure, 2 when the binary or pty tooling is missing.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# shellcheck source=scripts/lib/tui_pty.sh
# shellcheck disable=SC1091 # sourced lib resolved at runtime; absent when this file is linted alone
source "$ROOT/scripts/lib/tui_pty.sh"

tui_pty_guard
tui_pty_make_prefix
trap 'rm -rf "$TUI_PREFIX"' EXIT
tui_pty_seed_kegs 8
command -v sqlite3 >/dev/null || {
  echo "sqlite3 required" >&2
  exit 2
}
sqlite3 "$TUI_PREFIX/db/malt.db" 'INSERT INTO schema_version(version) VALUES (9999);'

fail() {
  echo "tui-too-new-schema-banner: FAIL — $*" >&2
  exit 1
}

CAP="$TUI_PREFIX/cap.bin"
# Launch on Search: the background outdated audit hits the refusal first; then
# enter Installed, whose blocking `list --json` read hits it on the other path.
out=$(
  tui_pty_drive "$CAP" 100 24 <<'ACT'
settle 0.8
send \t
settle 0.6
send q
quitwait 1.5
ACT
)

echo "$out" | grep -q "EXIT_STATUS=0" || fail "mt tui did not exit 0 on q ($out)"
grep -qa "error\." "$CAP" && fail "an error.* backtrace leaked into the frame"
grep -qa "ChildFailed" "$CAP" && fail "banner still says ChildFailed instead of naming the newer database"
grep -qa "newer" "$CAP" || fail "banner never named the newer database"

echo "tui-too-new-schema-banner: PASS"
