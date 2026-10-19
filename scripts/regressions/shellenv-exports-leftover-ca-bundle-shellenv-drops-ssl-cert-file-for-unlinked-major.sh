#!/usr/bin/env bash
# shellenv must keep exporting SSL_CERT_FILE when the installed OpenSSL
# major has no bundle but a leftover link to ca-certificates still
# resolves. Every major reads SSL_CERT_FILE, so a resolving bundle beats
# none. A copied file is not exported. doctor must still warn about the
# unlinked installed major.
#
# Hermetic: MALT_OFFLINE short-circuits the network.
#
# Usage: scripts/regressions/shellenv-exports-leftover-ca-bundle-shellenv-drops-ssl-cert-file-for-unlinked-major.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
export MALT_OFFLINE=1 NO_COLOR=1 MALT_NO_EMOJI=1

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ -x "$MALT_BIN" ]] || fail "malt binary not found at $MALT_BIN — run \"zig build\" first."

P=$(mktemp -d -t mt_shellenv_leftover.XXXXXX)
trap 'rm -rf "$P"' EXIT

# openssl@4 installed and unlinked; openssl@3 is gone but its link remains.
mkdir -p "$P"/{Cellar,db,opt/openssl@4,opt/ca-certificates,etc/ca-certificates,etc/openssl@3}
: >"$P/etc/ca-certificates/cert.pem"
ln -s ../ca-certificates/cert.pem "$P/etc/openssl@3/cert.pem"
export MALT_PREFIX=$P

for sh in bash fish; do
  out=$("$MALT_BIN" shellenv "$sh")
  grep -qF "SSL_CERT_FILE" <<<"$out" || fail "$sh: no SSL_CERT_FILE with a resolving leftover bundle"
  grep -qF "$P/etc/openssl@3/cert.pem" <<<"$out" || fail "$sh: SSL_CERT_FILE names the wrong bundle"
done

doc=$("$MALT_BIN" doctor 2>&1 1>/dev/null || true)
grep -q "openssl@4's cert.pem isn't linked" <<<"$doc" ||
  fail "doctor stopped warning about the unlinked openssl@4 bundle"

# A copied file can hold stale roots, so it must not be exported.
mv "$P/etc/openssl@3/cert.pem" "$P/etc/openssl@3/link.pem"
cp "$P/etc/ca-certificates/cert.pem" "$P/etc/openssl@3/cert.pem"
if "$MALT_BIN" shellenv bash | grep -q SSL_CERT_FILE; then
  fail "exported a plain-file leftover"
fi
rm "$P/etc/openssl@3/cert.pem"
mv "$P/etc/openssl@3/link.pem" "$P/etc/openssl@3/cert.pem"

# A dangling leftover must still export nothing.
rm "$P/etc/ca-certificates/cert.pem"
if "$MALT_BIN" shellenv bash | grep -q SSL_CERT_FILE; then
  fail "exported a dangling bundle"
fi

printf 'PASS: shellenv keeps a resolving leftover CA bundle\n'
