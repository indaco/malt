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
#   * mt install openssl@3, then openssl@4 → each <prefix>/etc/<keg>/cert.pem
#     resolves (no dangle) through to that bundle byte for byte, and
#     mt shellenv exports it as SSL_CERT_FILE; mt doctor then finds both
#     bundles linked.
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
PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
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

# ── 2. each openssl major links etc/<keg>/cert.pem through the chain. ─
# Homebrew moves dependents from openssl@3 to openssl@4, so both must work.
# openssl@4 goes second: shellenv prefers it once both are present.
for KEG in openssl@3 openssl@4; do
  printf '▸ malt install %s\n' "$KEG"
  "$BIN" install "$KEG" >"$PREFIX/$KEG.log" 2>&1 || fail "install $KEG failed — see $PREFIX/$KEG.log"
  pass "installed $KEG"

  OSSL_CERT="$PREFIX/etc/$KEG/cert.pem"
  [[ -L "$OSSL_CERT" ]] || fail "$OSSL_CERT is not a symlink"
  [[ -e "$OSSL_CERT" ]] || fail "$OSSL_CERT dangles — the cross-formula pkgetc chain is broken"
  pass "etc/$KEG/cert.pem is a symlink that resolves (no dangle)"

  [[ "$(sha "$OSSL_CERT")" == "$(sha "$CA_CERT")" ]] ||
    fail "etc/$KEG/cert.pem does not resolve to the ca-certificates bundle"
  pass "etc/$KEG/cert.pem reaches the ca-certificates bundle (sha256 match)"

  # The user-facing contract: shellenv hands this keg's bundle to the shell.
  "$BIN" shellenv bash | grep -qF "export SSL_CERT_FILE=\"$OSSL_CERT\";" ||
    fail "mt shellenv did not export SSL_CERT_FILE=$OSSL_CERT"
  pass "mt shellenv exports SSL_CERT_FILE → etc/$KEG/cert.pem"
done

# ── 3. with both majors installed, doctor finds every bundle linked. ──
# doctor exits 1 on a warn row; under pipefail a piped grep would then
# never fire, so capture the output first.
DOCTOR=$("$BIN" doctor 2>&1 || true)
# A crash or a missing row would also show no warning, so require the row.
grep -q 'SSL CA bundle' <<<"$DOCTOR" || fail "mt doctor drew no SSL CA bundle row"
if grep -q "isn't linked" <<<"$DOCTOR"; then
  fail "mt doctor reports an unlinked CA bundle with openssl@3 and openssl@4 installed"
fi
pass "mt doctor finds the bundle of both openssl majors"

printf '\n✔ ssl ca-bundle provisioning regression passed\n'
