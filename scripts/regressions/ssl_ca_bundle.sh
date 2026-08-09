#!/usr/bin/env bash
# Regression: a malt-only prefix provisions a complete OpenSSL CA bundle.
#
# Two gaps used to leave HTTPS broken in a fresh malt prefix:
#   1. ca-certificates' macOS post_install regenerates the trust store
#      from the system keychain — Ruby surface the native DSL can't run —
#      so it landed no cert.pem.
#   2. `Formula["ca-certificates"].pkgetc` resolved to <opt>/ca-certificates/etc
#      instead of <prefix>/etc/ca-certificates, so openssl@3's post_install
#      symlink dangled.
#
# This asserts the native fix end-to-end:
#   * mt install ca-certificates → <prefix>/etc/ca-certificates/cert.pem is the
#     bundle the keg's own helper builds: a real file holding the shipped store
#     *plus* the roots the system keychain trusts, not a copy of the store.
#   * mt install openssl@3 → <prefix>/etc/openssl@3/cert.pem resolves (no
#     dangle) through to that bundle byte for byte.
#
# The shipped `cacert.pem` is only an input to the helper. Asserting the
# installed bundle equals it would pin the state where the helper never ran.
#
# Usage: scripts/regressions/ssl_ca_bundle.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt,
# network access to ghcr.io / formulae.brew.sh.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_ca"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

sha() { shasum -a 256 "$1" | awk '{print $1}'; }

SHIPPED="$PREFIX/opt/ca-certificates/share/ca-certificates/cacert.pem"

# ── 1. ca-certificates provisions etc/ca-certificates/cert.pem. ──────
printf '▸ malt install ca-certificates\n'
"$BIN" install ca-certificates >"$PREFIX/ca.log" 2>&1 || fail "install ca-certificates failed — see $PREFIX/ca.log"
pass "installed ca-certificates"

[[ -e "$SHIPPED" ]] || fail "keg shipped no cacert.pem at $SHIPPED"

CA_CERT="$PREFIX/etc/ca-certificates/cert.pem"
[[ -e "$CA_CERT" ]] || fail "$CA_CERT was not provisioned"
pass "etc/ca-certificates/cert.pem exists"

certs() { grep -c 'BEGIN CERTIFICATE' "$1"; }
SHIPPED_N=$(certs "$SHIPPED")
CA_N=$(certs "$CA_CERT")
[[ "$CA_N" -ge "$SHIPPED_N" ]] ||
  fail "etc/ca-certificates/cert.pem holds $CA_N certs, fewer than the $SHIPPED_N shipped"
[[ "$(sha "$CA_CERT")" != "$(sha "$SHIPPED")" ]] ||
  fail "etc/ca-certificates/cert.pem is a copy of the shipped store — the keg's helper never ran"
pass "etc/ca-certificates/cert.pem is the helper's bundle ($CA_N certs vs $SHIPPED_N shipped)"

# ── 2. openssl@3 links etc/openssl@3/cert.pem through the chain. ─────
printf '▸ malt install openssl@3\n'
"$BIN" install openssl@3 >"$PREFIX/ossl.log" 2>&1 || fail "install openssl@3 failed — see $PREFIX/ossl.log"
pass "installed openssl@3"

OSSL_CERT="$PREFIX/etc/openssl@3/cert.pem"
[[ -L "$OSSL_CERT" ]] || fail "$OSSL_CERT is not a symlink"
[[ -e "$OSSL_CERT" ]] || fail "$OSSL_CERT dangles — the cross-formula pkgetc chain is broken"
pass "etc/openssl@3/cert.pem is a symlink that resolves (no dangle)"

[[ "$(sha "$OSSL_CERT")" == "$(sha "$CA_CERT")" ]] ||
  fail "etc/openssl@3/cert.pem does not resolve to the ca-certificates bundle"
pass "etc/openssl@3/cert.pem reaches the ca-certificates bundle (sha256 match)"

printf '\n✔ ssl ca-bundle provisioning regression passed\n'
