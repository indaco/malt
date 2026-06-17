#!/usr/bin/env bash
# Gate the doctor "SSL CA bundle" row on its precondition: the bundle is
# only worth verifying once ca-certificates is installed.
#
# Before the fix the check always drew a row and, when cert.pem was absent,
# rendered a contradictory green check with a "HTTPS verification fails"
# detail — noise on every prefix that simply hadn't installed
# ca-certificates.
#
# Pinned behaviour (hermetic — MALT_OFFLINE short-circuits the network):
#   1. ca-certificates not installed → no SSL row at all (human + json).
#   2. installed but cert.pem unlinked → a warn row naming the fault, and a
#      json finding with severity "warn".
#   3. installed and cert.pem linked → a clean ok row, json severity "ok".
#
# Usage: scripts/regressions/doctor_ssl_ca_bundle_gating.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s — run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

export MALT_OFFLINE=1 NO_COLOR=1 MALT_NO_EMOJI=1

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

# Seed a scratch prefix with the expected layout. `$2` truthy links
# opt/ca-certificates (the "installed" signal); `$3` truthy lands the
# openssl@3 cert.pem.
seed() {
  local pfx="$1" with_ca="$2" with_cert="$3"
  mkdir -p "$pfx/store" "$pfx/Cellar" "$pfx/Caskroom" "$pfx/opt" \
    "$pfx/bin" "$pfx/lib" "$pfx/tmp" "$pfx/cache" "$pfx/db"
  if [[ -n "$with_ca" ]]; then
    mkdir -p "$pfx/opt/ca-certificates"
  fi
  if [[ -n "$with_cert" ]]; then
    mkdir -p "$pfx/etc/openssl@3"
    : >"$pfx/etc/openssl@3/cert.pem"
  fi
}

# Run both views of doctor against $1; populate the globals HUMAN / JSON.
run_doctor() {
  export MALT_PREFIX="$1"
  HUMAN=$("$MALT_BIN" doctor 2>&1 1>/dev/null || true)
  JSON=$("$MALT_BIN" doctor --json 2>/dev/null || true)
}

# ── 1. not installed → fully silent on the SSL dimension ────────────────
PFX=$(mktemp -d -t mt_doctor_ssl_none.XXXXXX)
trap 'rm -rf "$PFX"' EXIT
seed "$PFX" "" ""
run_doctor "$PFX"
if printf '%s' "$HUMAN" | grep -q 'SSL CA bundle'; then
  fail 'uninstalled ca-certificates still drew an SSL row on stderr'
fi
if printf '%s' "$JSON" | grep -q '"id":"ssl_ca_bundle"'; then
  fail 'uninstalled ca-certificates still emitted an ssl_ca_bundle json finding'
fi
rm -rf "$PFX"

# ── 2. installed but unlinked → a warn naming the fault ─────────────────
PFX=$(mktemp -d -t mt_doctor_ssl_unlinked.XXXXXX)
trap 'rm -rf "$PFX"' EXIT
seed "$PFX" 1 ""
run_doctor "$PFX"
printf '%s' "$HUMAN" | grep -q "SSL CA bundle .* isn't linked" ||
  fail 'installed-but-unlinked bundle did not warn about the unlinked cert'
printf '%s' "$JSON" | grep -q '"id":"ssl_ca_bundle","severity":"warn"' ||
  fail 'installed-but-unlinked bundle did not serialize a warn json finding'
rm -rf "$PFX"

# ── 3. installed and linked → a clean ok row ───────────────────────────
PFX=$(mktemp -d -t mt_doctor_ssl_linked.XXXXXX)
trap 'rm -rf "$PFX"' EXIT
seed "$PFX" 1 1
run_doctor "$PFX"
printf '%s' "$HUMAN" | grep -q 'SSL CA bundle' ||
  fail 'a healthy bundle dropped its confirming SSL row'
if printf '%s' "$HUMAN" | grep -q "isn't linked"; then
  fail 'a healthy bundle still rendered the unlinked-cert warning'
fi
printf '%s' "$JSON" | grep -q '"id":"ssl_ca_bundle","severity":"ok"' ||
  fail 'a healthy bundle did not serialize an ok json finding'
rm -rf "$PFX"

trap - EXIT
printf 'PASS: doctor SSL CA bundle row is gated on ca-certificates being installed\n'
