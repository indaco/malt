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
#   * mt install ca-certificates → <prefix>/etc/ca-certificates/cert.pem is a
#     symlink to the shipped cacert.pem and matches it by sha256.
#   * mt install openssl@3 → <prefix>/etc/openssl@3/cert.pem resolves (no
#     dangle) through to the same bundle and matches it by sha256.
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
[[ -L "$CA_CERT" ]] || fail "$CA_CERT is not a symlink"
[[ -e "$CA_CERT" ]] || fail "$CA_CERT dangles (target missing)"
pass "etc/ca-certificates/cert.pem is a symlink that resolves"

[[ "$(sha "$CA_CERT")" == "$(sha "$SHIPPED")" ]] ||
  fail "etc/ca-certificates/cert.pem does not match the shipped cacert.pem by sha256"
pass "etc/ca-certificates/cert.pem matches the shipped bundle by sha256"

# ── 2. openssl@3 links etc/openssl@3/cert.pem through the chain. ─────
printf '▸ malt install openssl@3\n'
"$BIN" install openssl@3 >"$PREFIX/ossl.log" 2>&1 || fail "install openssl@3 failed — see $PREFIX/ossl.log"
pass "installed openssl@3"

OSSL_CERT="$PREFIX/etc/openssl@3/cert.pem"
[[ -L "$OSSL_CERT" ]] || fail "$OSSL_CERT is not a symlink"
[[ -e "$OSSL_CERT" ]] || fail "$OSSL_CERT dangles — the cross-formula pkgetc chain is broken"
pass "etc/openssl@3/cert.pem is a symlink that resolves (no dangle)"

[[ "$(sha "$OSSL_CERT")" == "$(sha "$SHIPPED")" ]] ||
  fail "etc/openssl@3/cert.pem does not resolve to the shipped cacert.pem"
pass "etc/openssl@3/cert.pem reaches the shipped bundle (sha256 match)"

printf '\n✔ ssl ca-bundle provisioning regression passed\n'
