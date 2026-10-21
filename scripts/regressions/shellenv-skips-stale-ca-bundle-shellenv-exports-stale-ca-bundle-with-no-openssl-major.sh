#!/usr/bin/env bash
# With no OpenSSL major installed, shellenv must export SSL_CERT_FILE only
# for a leftover link into an installed ca-certificates. An orphaned link
# or a plain copy holds a frozen root set and must not be exported.
#
# Hermetic: local fixtures only, MALT_OFFLINE short-circuits the network.
#
# Usage: scripts/regressions/shellenv-skips-stale-ca-bundle-shellenv-exports-stale-ca-bundle-with-no-openssl-major.sh

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

P=$(mktemp -d -t mt_shellenv_nomajor.XXXXXX)
trap 'rm -rf "$P"' EXIT
export MALT_PREFIX=$P

mkdir -p "$P"/{Cellar,db,etc/ca-certificates,etc/openssl@3}
: >"$P/etc/ca-certificates/cert.pem"
ln -s ../ca-certificates/cert.pem "$P/etc/openssl@3/cert.pem"

# ca-certificates uninstalled: the link is orphaned.
for sh in bash fish; do
  if "$MALT_BIN" shellenv "$sh" | grep -qF SSL_CERT_FILE; then
    fail "$sh: exported an orphaned bundle"
  fi
done

# ca-certificates installed: the link is live and must still export.
mkdir -p "$P/opt/ca-certificates"
for sh in bash fish; do
  "$MALT_BIN" shellenv "$sh" | grep -qF "$P/etc/openssl@3/cert.pem" ||
    fail "$sh: dropped a live leftover link"
done

# A plain copy can hold stale roots, whatever is installed.
rm "$P/etc/openssl@3/cert.pem"
: >"$P/etc/openssl@3/cert.pem"
if "$MALT_BIN" shellenv bash | grep -qF SSL_CERT_FILE; then
  fail "exported a plain-file copy with no major installed"
fi

printf 'PASS: shellenv skips stale CA bundles when no OpenSSL major is installed\n'
