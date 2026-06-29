#!/usr/bin/env bash
# scripts/smokes/smoke_ssl_python.sh
#
# End-to-end TLS smoke for a malt-only prefix. Proves that the native
# CA-bundle provisioning makes real HTTPS verification succeed — not just
# that the cert.pem files exist on disk (the ssl_ca_bundle regression
# covers that), but that a fresh interpreter linked against the malt
# openssl@3 can actually verify a live certificate chain.
#
# Slower than the regression (downloads python@3.14 + openssl@3 +
# ca-certificates), so it lives under smokes/ rather than regressions/.
#
# Assertions:
#   1. <prefix>/bin/python3.14 present.
#   2. mt shellenv exports SSL_CERT_FILE (the provisioned bundle).
#   3. python3.14 urlopen("https://api.github.com/") completes the TLS
#      handshake — any HTTP status proves the chain verified; only a real
#      ssl.SSLError is a failure (a 403 rate-limit still proves the contract).
#
# Usage: scripts/smokes/smoke_ssl_python.sh
# Requirements: built `malt` binary, network to formulae.brew.sh + ghcr.io
# + api.github.com.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# Short prefix: python@3.14's Mach-O dependents are patched in place.
PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
cleanup() { [[ "$PREFIX" == /tmp/mt.* ]] && rm -rf "$PREFIX"; }
trap cleanup EXIT INT TERM

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

printf '▸ malt install python@3.14 ca-certificates (logs → %s)\n' "$PREFIX/install.log"
"$BIN" install python@3.14 ca-certificates >"$PREFIX/install.log" 2>&1 ||
  fail "install python@3.14 ca-certificates failed — see $PREFIX/install.log"
pass "installed python@3.14 + ca-certificates"

PY="$PREFIX/bin/python3.14"
[[ -x "$PY" ]] || fail "$PY not found / not executable"
pass "python3.14 present in PATH"

# The user-facing TLS contract: shellenv hands the interpreter a bundle.
eval "$("$BIN" shellenv bash)"
[[ -n "${SSL_CERT_FILE:-}" ]] || fail "mt shellenv did not export SSL_CERT_FILE"
[[ -e "$SSL_CERT_FILE" ]] || fail "SSL_CERT_FILE points at a missing bundle: $SSL_CERT_FILE"
pass "mt shellenv exports SSL_CERT_FILE → $SSL_CERT_FILE"

printf '▸ python3.14 urlopen https://api.github.com/\n'
# This smoke verifies the TLS *chain*, not GitHub auth. Any HTTP response —
# including an anonymous-rate-limit 403 — only arrives after the handshake and
# certificate verification have already succeeded, so it proves the contract.
# A genuine cert failure surfaces as an ssl.SSLError (the regression we guard);
# a non-TLS network error (DNS/offline) is unrelated and downgrades to a SKIP.
set +e
"$PY" - >"$PREFIX/py.out" 2>"$PREFIX/py.err" <<'PY'
import urllib.request, urllib.error, ssl, sys
try:
    r = urllib.request.urlopen("https://api.github.com/")
    print("HTTP %d" % r.status)
except urllib.error.HTTPError as e:
    print("HTTP %d" % e.code)
except urllib.error.URLError as e:
    if isinstance(e.reason, ssl.SSLError):
        print("ssl verification failed: %s" % e.reason, file=sys.stderr)
        sys.exit(1)
    print("network error: %s" % e.reason, file=sys.stderr)
    sys.exit(2)
PY
rc=$?
set -e
case "$rc" in
0) pass "python3.14 verified a live HTTPS chain ($(cat "$PREFIX/py.out"))" ;;
1)
  cat "$PREFIX/py.err" >&2
  fail "python TLS chain verification failed — CERTIFICATE_VERIFY_FAILED"
  ;;
*)
  cat "$PREFIX/py.err" >&2
  echo "SKIP: non-TLS network error reaching api.github.com (TLS not exercised)"
  exit 0
  ;;
esac

printf '\n✔ ssl python TLS smoke passed\n'
