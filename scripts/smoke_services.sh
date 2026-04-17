#!/usr/bin/env bash
# Smoke test for `malt services` against real launchd.
#
# Exercises register → start → status → logs → stop → unregister against a
# trivial throwaway service. Uses an isolated MALT_PREFIX so it does not
# touch the real installation. Safe to run on a developer machine; do not
# run in CI (touches the user's launchd domain).
#
# Usage: scripts/smoke_services.sh
# Requirements: built `malt` binary in zig-out/bin, macOS.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "smoke test requires macOS" >&2
  exit 2
fi

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/zig-out/bin/malt"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX=$(mktemp -d -t malt_smoke_XXXXXX)
export MALT_PREFIX="$PREFIX"
trap 'echo "cleaning up $PREFIX"; "$BIN" services stop smoke-echo 2>/dev/null || true; rm -rf "$PREFIX"' EXIT

mkdir -p "$PREFIX/db" "$PREFIX/var/malt/services" "$PREFIX/var/log"

# Hand-roll a service row + plist that prints a heartbeat every 2 seconds.
sqlite3 "$PREFIX/db/malt.db" <<'SQL'
CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY, applied TEXT);
CREATE TABLE IF NOT EXISTS services (
  name TEXT PRIMARY KEY, keg_name TEXT NOT NULL, plist_path TEXT NOT NULL,
  auto_start INTEGER NOT NULL DEFAULT 0, last_started_at INTEGER, last_status TEXT
);
INSERT OR IGNORE INTO schema_version VALUES (2, datetime('now'));
SQL

mkdir -p "$PREFIX/var/malt/services/smoke-echo"
PLIST="$PREFIX/var/malt/services/smoke-echo/service.plist"
cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>smoke-echo</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>while true; do echo "tick \$(date)"; sleep 2; done</string>
    </array>
    <key>StandardOutPath</key>
    <string>$PREFIX/var/malt/services/smoke-echo/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>$PREFIX/var/malt/services/smoke-echo/stderr.log</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
</dict>
</plist>
EOF

sqlite3 "$PREFIX/db/malt.db" <<SQL
INSERT INTO services(name, keg_name, plist_path, auto_start, last_status)
VALUES ('smoke-echo', 'smoke-echo', '$PLIST', 0, 'registered');
SQL

echo "=== list (expect smoke-echo, not-loaded)"
"$BIN" services list

echo "=== start"
"$BIN" services start smoke-echo

echo "=== sleep 5 then logs --tail 5"
sleep 5
"$BIN" services logs smoke-echo --tail 5

echo "=== status"
"$BIN" services status smoke-echo

echo "=== stop"
"$BIN" services stop smoke-echo

echo "=== final list (expect status=not-loaded after bootout)"
"$BIN" services list

echo
echo "OK — smoke test passed"
