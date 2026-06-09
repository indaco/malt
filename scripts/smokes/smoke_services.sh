#!/usr/bin/env bash
# Smoke test for `malt services` against real launchd.
#
# Two phases, both against isolated throwaway prefixes so they never touch the
# real installation:
#   1. A real `malt install` of a service-providing formula, asserting the
#      parse → register path resolves `$HOMEBREW_PREFIX` and registers cleanly.
#      The hand-rolled phase below bypasses parsing entirely, so this is the
#      only phase that guards formula-sourced service definitions.
#   2. A hand-rolled echo service driving register → start → logs → stop →
#      backup → restore against real launchd.
#
# Safe to run on a developer machine; do not run in CI (touches the user's
# launchd domain).
#
# Usage: scripts/smokes/smoke_services.sh
# Requirements: built `malt` binary in zig-out/bin, macOS, network (phase 1).

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "smoke test requires macOS" >&2
  exit 2
fi

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="$ROOT/zig-out/bin/malt"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# ── Phase 1: a real install registers a formula's service definition ──────
# The Homebrew API renders service paths as `$HOMEBREW_PREFIX/…`; malt must
# resolve that token before validation or registration fails for every formula.
SVC_FORMULA="dnsmasq"
IPREFIX=$(mktemp -d -t malt_smoke_install_XXXXXX)
trap 'rm -rf "$IPREFIX"' EXIT
echo "=== install $SVC_FORMULA into a throwaway prefix (real network install)"
install_log=$(MALT_PREFIX="$IPREFIX" NO_COLOR=1 MALT_NO_EMOJI=1 "$BIN" install "$SVC_FORMULA" 2>&1) || {
  echo "$install_log"
  echo "FAIL: install $SVC_FORMULA exited non-zero"
  exit 1
}
echo "$install_log"

grep -q "could not register service" <<<"$install_log" && {
  echo "FAIL: service registration warned during install"
  exit 1
}
echo "  ✓ install registered the service without warning"

# The human table prints to stderr; stdout is reserved for `--json`.
MALT_PREFIX="$IPREFIX" "$BIN" services list 2>&1 | grep -q "$SVC_FORMULA" || {
  echo "FAIL: $SVC_FORMULA absent from services list after install"
  exit 1
}
echo "  ✓ services list shows $SVC_FORMULA"

IPLIST=$(sqlite3 "$IPREFIX/db/malt.db" "SELECT plist_path FROM services WHERE keg_name='$SVC_FORMULA';")
[[ -f "$IPLIST" ]] || {
  echo "FAIL: no plist registered for $SVC_FORMULA"
  exit 1
}
grep -q 'HOMEBREW_PREFIX' "$IPLIST" && {
  echo "FAIL: plist still carries an unexpanded \$HOMEBREW_PREFIX token"
  cat "$IPLIST"
  exit 1
}
grep -q "$IPREFIX" "$IPLIST" || {
  echo "FAIL: plist does not reference the malt prefix"
  cat "$IPLIST"
  exit 1
}
echo "  ✓ plist paths resolved to the malt prefix"
rm -rf "$IPREFIX"

# ── Phase 2: hand-rolled echo service exercises the launchd lifecycle ─────

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

# --- backup --services + restore round-trip ----------------------------
# Pins the plain-text half of the bundle/backup round-trip: the
# service must surface in the file, and restore must re-bootstrap it.

echo "=== mark smoke-echo as auto_start so backup picks it up"
sqlite3 "$PREFIX/db/malt.db" "UPDATE services SET auto_start = 1 WHERE name = 'smoke-echo';"

SNAP="$PREFIX/snap.txt"
echo "=== mt backup --services -o $SNAP"
"$BIN" backup --services -o "$SNAP"

grep -q '^service smoke-echo$' "$SNAP" || {
  echo "FAIL: expected 'service smoke-echo' line in $SNAP"
  cat "$SNAP"
  exit 1
}
echo "  ✓ backup carries 'service smoke-echo'"

echo "=== mt restore $SNAP (re-bootstrap via services dispatcher)"
"$BIN" restore "$SNAP"

# Re-bootstrap means launchd loaded the plist again — clean up so the
# trap's `services stop` is a no-op rather than a leak across runs.
echo "=== post-restore stop"
"$BIN" services stop smoke-echo

echo
echo "OK — smoke test passed"
