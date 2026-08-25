#!/usr/bin/env bash
# Regression: malt builds ca-certificates' merged trust bundle natively instead
# of running the shipped script, which forks openssl and security once per
# certificate (~800 processes, several seconds on every cold install whose
# closure reaches openssl@3).
#
# Substituting an implementation for a trust store is only safe while the two
# agree on WHICH certificates to trust, so that is what this asserts, against
# the real script on the real machine. It also pins the recognition digest,
# because malt only substitutes for a script it recognises byte-for-byte - if
# upstream edits the script the digest must miss, so the slow-but-correct path
# runs until equivalence is re-established here.
#
# Byte layout is deliberately not asserted. macOS ships LibreSSL as
# /usr/bin/openssl, and its -checkend misreads a validity encoded as
# GeneralizedTime, so the script drops such a certificate from the keychain
# pass and recovers it from the Mozilla bundle further down. Same set,
# different order. A byte difference is reported, not failed.
#
# Needs the ca-certificates keg, so it installs into a throwaway prefix.
# Never point MALT_PREFIX at a real install.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
# MALT_BIN mirrors scripts/bench.sh's knob so CI can point at whichever build
# it wants checked.
BIN="${MALT_BIN:-$ROOT/zig-out/bin/mt}"
[[ -x "$BIN" ]] || {
  echo "FAIL: $BIN not built - run 'zig build' first" >&2
  exit 1
}

if [[ -z "${MALT_GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  MALT_GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
  export MALT_GITHUB_TOKEN
fi

PREFIX=/tmp/mt_cab
WORK=$(mktemp -d)
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1 MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX" "$WORK"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

"$BIN" install ca-certificates >"$WORK/install.log" 2>&1 ||
  fail "installing ca-certificates: $(tail -3 "$WORK/install.log")"

KEG=$(echo "$PREFIX"/Cellar/ca-certificates/*)
SCRIPT="$KEG/libexec/post-install"
SOURCE="$KEG/share/ca-certificates/cacert.pem"
[[ -f "$SCRIPT" && -f "$SOURCE" ]] || fail "keg is missing the post-install script or its source bundle"

# ── the recognition digest still matches the shipped script ───────────
want=$(grep -oE '"[0-9a-f]{64}"' "$ROOT/src/core/ca_bundle.zig" | head -1 | tr -d '"')
got=$(shasum -a 256 "$SCRIPT" | cut -d' ' -f1)
if [[ "$want" != "$got" ]]; then
  echo "  upstream script digest: $got" >&2
  echo "  digest in ca_bundle.zig: $want" >&2
  fail "the shipped script changed - re-verify equivalence and update the digest"
fi

# ── malt's bundle, written by the install above ───────────────────────
NATIVE="$PREFIX/etc/ca-certificates/cert.pem"
[[ -s "$NATIVE" ]] || fail "install left no bundle at $NATIVE"

# ── the native path must actually have been used ───────────────────────
# Comparing the bundle against the script cannot show this: when the native
# path declines, the script produced the bundle, so the two agree perfectly
# and every other check here passes while the optimisation is silently gone.
# The decline note is the only evidence, so its absence is the assertion.
if grep -q "native trust-store build declined" "$WORK/install.log"; then
  grep "native trust-store build declined" "$WORK/install.log" | sed 's/^/  /' >&2
  fail "the native builder declined; the shipped script did the work"
fi

# ── the bundle must stay world-readable, as the script's chmod makes it ──
# open(2) masks the mode with the caller's umask, so a native write that only
# requests 0644 lands 0600 under a restrictive one - unreadable to every other
# user and service on the machine.
mode=$(stat -f '%Lp' "$NATIVE")
[[ "$mode" == "644" ]] ||
  fail "bundle mode is $mode, expected 644 (the script chmods it)"

# ── upstream's bundle, from the script itself ─────────────────────────
bash "$SCRIPT" "$SOURCE" "$WORK/upstream.pem" >"$WORK/script.log" 2>&1 ||
  fail "upstream script failed: $(tail -3 "$WORK/script.log")"

n_native=$(grep -c 'BEGIN CERTIFICATE' "$NATIVE")
n_upstream=$(grep -c 'BEGIN CERTIFICATE' "$WORK/upstream.pem")
[[ "$n_native" == "$n_upstream" ]] ||
  fail "certificate count differs: native $n_native, upstream $n_upstream"

# ── the trusted set must match exactly ───────────────────────────────
der_fingerprints() {
  awk -v p="$2" '/-----BEGIN CERTIFICATE-----/{n++; blk=""}
                 {blk = blk $0 "\n"}
                 /-----END CERTIFICATE-----/{printf "%s", blk > (p "." n); close(p "." n)}' "$1"
  for f in "$2".*; do openssl x509 -in "$f" -outform der 2>/dev/null | shasum -a 256 | cut -d' ' -f1; done | sort
  rm -f "$2".*
}
der_fingerprints "$NATIVE" "$WORK/a" >"$WORK/native.der"
der_fingerprints "$WORK/upstream.pem" "$WORK/b" >"$WORK/upstream.der"

if ! cmp -s "$WORK/native.der" "$WORK/upstream.der"; then
  echo "  only upstream trusts:" >&2
  comm -23 "$WORK/upstream.der" "$WORK/native.der" | head -5 >&2
  echo "  only malt trusts:" >&2
  comm -13 "$WORK/upstream.der" "$WORK/native.der" | head -5 >&2
  fail "the two bundles trust different certificates"
fi

if cmp -s "$NATIVE" "$WORK/upstream.pem"; then
  echo "PASS: native bundle is byte-identical to upstream's script ($n_native certificates)"
else
  echo "PASS: native bundle trusts the same $n_native certificates as upstream's script"
  echo "      (byte layout differs - expected where LibreSSL misreads a GeneralizedTime validity)"
fi
