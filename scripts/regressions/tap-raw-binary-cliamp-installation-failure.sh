#!/usr/bin/env bash
# Regression for tap formulas whose `url` is a bare release binary.
#
# The tap install path classified the archive by URL suffix before
# fetching anything, and only knew .tar.gz/.tgz/.tar.xz/.zip. A
# GoReleaser-style asset (`.../cliamp-darwin-arm64`) matched nothing, so
# the install aborted with "Unsupported archive format" before a byte
# was downloaded — an entire class of single-file taps was unreachable.
# The fix lets an unrecognised suffix take a raw-binary path, sniffs the
# staged bytes for Mach-O magic, and copies the asset straight to
# `bin/<name>` (the `bin.install <asset> => <name>` rename).
#
# Both halves matter: the bare binary must install, AND a compressed
# body arriving on the same path must still be refused — the fallback
# is a sniff, not a blanket accept.
#
# The 30 MB release asset is never fetched: the warm-cache branch is
# keyed purely on `<sha>.<ext>` and re-verifies nothing, so seeding
# `<prefix>/cache/Tap/<sha>.bin` leaves only the tap resolve and one
# raw `.rb` fetch on the network.
#
# Usage: scripts/regressions/tap-raw-binary-cliamp-installation-failure.sh
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, macOS
# (the sniff is Mach-O), network access to raw.githubusercontent.com.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

[[ "$(uname -s)" == "Darwin" ]] || {
  printf '  - not macOS; the raw-binary sniff is Mach-O only\n'
  exit 0
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX=$(mktemp -d /tmp/mt.XXX)
trap 'rm -rf "$PREFIX"' EXIT
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
export MALT_GITHUB_TOKEN="${MALT_GITHUB_TOKEN:-$(gh auth token 2>/dev/null || true)}"
mkdir -p "$PREFIX/cache/Tap"

pass() { printf '  ✓ %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

TAP_RB="https://raw.githubusercontent.com/bjarneo/homebrew-cliamp/main/Formula/cliamp.rb"
RB=$(curl -fsSL "$TAP_RB" 2>/dev/null) || {
  skip "upstream tap unreachable; nothing to assert"
  exit 0
}

VERSION=$(printf '%s\n' "$RB" | sed -n 's/^[[:space:]]*version "\([^"]*\)".*/\1/p' | head -1)
[[ -n "$VERSION" ]] || fail "could not read version from the upstream formula"

# The formula pairs one url/sha256 per platform block; pick the pair
# matching this host so the seeded cache filename is the one malt looks up.
case "$(uname -m)" in
arm64) ASSET="darwin-arm64" ;;
x86_64) ASSET="darwin-amd64" ;;
*) fail "unsupported host architecture: $(uname -m)" ;;
esac
SHA=$(printf '%s\n' "$RB" |
  awk -v want="$ASSET" '
    $0 ~ "url .*" want "\"" { armed = 1; next }
    armed && /sha256 "/ { gsub(/^.*sha256 "|".*$/, ""); print; exit }
  ')
[[ ${#SHA} -eq 64 ]] || fail "could not read the $ASSET sha256 from the upstream formula"

CACHED="$PREFIX/cache/Tap/$SHA.bin"
DEST="$PREFIX/Cellar/cliamp/$VERSION/bin/cliamp"

# ── Positive half: a bare-binary url installs ───────────────────────────
#
# /usr/bin/true is a real, tiny, code-signed Mach-O — it stands in for the
# release asset and doubles as the byte-for-byte comparison source: the
# install must not mutate the bytes (any edit voids the adhoc signature).
cp /usr/bin/true "$CACHED"
LOG="$PREFIX/install.log"
"$BIN" install bjarneo/cliamp/cliamp >"$LOG" 2>&1 || true

if grep -q "Unsupported archive format" "$LOG"; then
  tail -20 "$LOG" >&2
  fail "regression — bare-binary tap url still rejected at the format gate"
fi

# Tolerate an upstream/network failure that never reached the gate.
if grep -qE "Tap formula/cask not found|Failed to resolve|rate limit" "$LOG"; then
  skip "tap resolve reported a non-regression failure; continuing"
  exit 0
fi

[[ -f "$DEST" ]] || {
  tail -20 "$LOG" >&2
  fail "expected the asset at $DEST"
}
[[ -x "$DEST" ]] || fail "$DEST is not executable"
cmp -s /usr/bin/true "$DEST" || fail "installed bytes differ from the staged asset"
pass "bare-binary tap url installs to bin/<name> byte-for-byte"

# ── Negative half: a compressed body must still be refused ──────────────
rm -rf "${PREFIX:?}/Cellar" "${PREFIX:?}/db" "${PREFIX:?}/bin"
printf 'BZh9' >"$CACHED"
LOG2="$PREFIX/install_bz2.log"
if "$BIN" install bjarneo/cliamp/cliamp >"$LOG2" 2>&1; then
  tail -20 "$LOG2" >&2
  fail "a bzip2 body on the raw-binary path was accepted"
fi
grep -q "Unsupported archive format" "$LOG2" || {
  tail -20 "$LOG2" >&2
  fail "expected the unsupported-format refusal for a non-Mach-O body"
}
[[ ! -e "$PREFIX/Cellar/cliamp" ]] || fail "refused install left a keg behind"
pass "non-Mach-O body on the same path is still refused"

printf '\n✔ tap raw-binary install regression passed\n'
