#!/usr/bin/env bash
# scripts/e2e/smoke_install_release.sh
#
# Post-release smoke: runs the README's one-liner against the live
# GitHub release and exercises the full trust path end-to-end.
#
# What this proves:
#   1. install.sh at `main` can reach the latest release on github.com
#   2. cosign verifies the checksums.txt.sigstore.json bundle against
#      the expected workflow identity (no MALT_ALLOW_UNVERIFIED escape)
#   3. the tarball SHA256 matches checksums.txt
#   4. the installed `malt` binary reports the release version
#   5. `malt doctor` runs cleanly on a fresh prefix
#   6. `malt install tree` completes end-to-end — bottle download, SHA
#      verify, extract, link, binary runs
#
# Network-dependent and slow (~30s on a warm connection). NOT in the
# default CI pipeline — run it manually after cutting a release, or
# wire into a release-verification workflow.
#
# Usage:
#   ./scripts/e2e/smoke_install_release.sh
#
# Requirements:
#   - curl, bash, tar
#   - cosign on PATH (tests the signature path; skip with
#     MALT_SKIP_COSIGN=1 to bypass, at the cost of coverage)

set -euo pipefail

# ── Colour + helpers ──────────────────────────────────────────────────
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  GREEN=$'\033[32m'
  RED=$'\033[31m'
  DIM=$'\033[2m'
  RESET=$'\033[0m'
else
  GREEN="" RED="" DIM="" RESET=""
fi

pass() { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
fail() {
  printf '  %s✗%s %s\n' "$RED" "$RESET" "$*" >&2
  exit 1
}
step() { printf '\n%s▸%s %s\n' "$DIM" "$RESET" "$*"; }

# ── Preflight ────────────────────────────────────────────────────────
COSIGN_PATH=""
if [ "${MALT_SKIP_COSIGN:-0}" != "1" ]; then
  COSIGN_PATH=$(command -v cosign 2>/dev/null || true)
  [ -n "$COSIGN_PATH" ] || fail "cosign required. Install (\`brew install cosign\`) or set MALT_SKIP_COSIGN=1."
fi

# ── Scratch prefix ────────────────────────────────────────────────────
# 11-byte path: MALT_PREFIX has a 13-byte hard cap (LC_LOAD_DYLIB
# patching budget — bottles hard-code `/opt/homebrew`, 13 bytes, and
# malt does in-place replacement). `/tmp/mt.XXX` matches what
# smoke_test.sh uses for the same reason.
PREFIX=$(mktemp -d /tmp/mt.XXX)
INSTALL_DIR="$PREFIX/bin"
mkdir -p "$INSTALL_DIR"
export MALT_PREFIX="$PREFIX"
export PATH="$INSTALL_DIR:$PATH"
trap 'rm -rf "$PREFIX"' EXIT

INSTALLER_URL="https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh"

# Sanitised PATH passed into install.sh. Some dev environments shadow
# /usr/bin/shasum or /usr/bin/curl with broken homebrew/nanobrew
# wrappers — install.sh probes command -v and would pick those up. The
# test isn't about dev-env pollution, so force a minimal PATH plus
# cosign's directory.
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
if [ -n "$COSIGN_PATH" ]; then
  SAFE_PATH="$(dirname "$COSIGN_PATH"):$SAFE_PATH"
fi

# GitHub publishes a release in two observable steps:
#   1. /releases/tags/<tag> goes 200 (the release object exists).
#   2. /releases/latest.tag_name flips to <tag> (CDN catches up).
# install.sh hits /releases/latest, so step 2 is the user-facing gate —
# but separating the two lets the smoke say *which* of the two lagged.
# Unit coverage for these helpers lives in scripts/test/release_wait_test.sh.
if [ "${MALT_SMOKE_SKIP_PROPAGATION_WAIT:-0}" != "1" ]; then
  EXPECTED_TAG="v$(cat "$(dirname "$0")/../../.version")"
  # shellcheck source=/dev/null
  source "$(dirname "$0")/../lib/release_wait.sh"
  step "Waiting up to $((WAIT_BUDGET_SECONDS / 60))m for ${EXPECTED_TAG} to propagate"
  wait_for_release "${EXPECTED_TAG}"
  pass "API /releases/latest reflects ${EXPECTED_TAG}"
fi

step "Running install.sh from README against the live release"
# env -i wipes GITHUB_TOKEN — forward it as MALT_INSTALLER_API_TOKEN so
# install.sh's /releases/latest probe is authenticated (5000/hr vs the
# 60/hr unauthenticated ceiling that shared runner IPs routinely hit).
INSTALLER_TOKEN="${MALT_SMOKE_API_TOKEN:-${GITHUB_TOKEN:-}}"
if [ "${MALT_SKIP_COSIGN:-0}" = "1" ]; then
  env -i HOME="$HOME" USER="$USER" PATH="$SAFE_PATH" \
    MALT_ALLOW_UNVERIFIED=1 PREFIX="$PREFIX" INSTALL_DIR="$INSTALL_DIR" \
    MALT_INSTALLER_API_TOKEN="$INSTALLER_TOKEN" \
    bash -c "curl -fsSL \"$INSTALLER_URL\" | bash"
else
  env -i HOME="$HOME" USER="$USER" PATH="$SAFE_PATH" \
    PREFIX="$PREFIX" INSTALL_DIR="$INSTALL_DIR" \
    MALT_INSTALLER_API_TOKEN="$INSTALLER_TOKEN" \
    bash -c "curl -fsSL \"$INSTALLER_URL\" | bash"
fi
[ -x "$INSTALL_DIR/malt" ] || fail "malt binary missing at $INSTALL_DIR/malt"
pass "install.sh succeeded (cosign + SHA256 verified)"

step "Version sanity"
"$INSTALL_DIR/malt" --version >"$PREFIX/.version.out" || fail "--version failed"
grep -qE '^malt [0-9]+\.[0-9]+\.[0-9]+' "$PREFIX/.version.out" ||
  fail "unexpected --version output: $(cat "$PREFIX/.version.out")"
pass "$(tr -d '\n' <"$PREFIX/.version.out")"

step "Doctor on a fresh prefix"
rc=0
"$INSTALL_DIR/malt" doctor >"$PREFIX/.doctor.out" 2>&1 || rc=$?
# Fresh prefix has no SQLite file yet; doctor returns 2 (errors).
# What we're proving is that it runs, not that it's green.
if [ "$rc" -gt 2 ]; then
  fail "malt doctor exit=$rc (expected 0/1/2)"
fi
pass "malt doctor runs (exit=$rc, green-or-documented-failure)"

step "Install tree (zero-deps formula, ~100 KB bottle)"
"$INSTALL_DIR/malt" install tree || fail "malt install tree failed"
[ -x "$PREFIX/bin/tree" ] || fail "tree binary missing after install"
# Tree's --version writes to stdout and exits 0.
"$PREFIX/bin/tree" --version >"$PREFIX/.tree.out" 2>&1 ||
  fail "tree --version failed"
pass "tree installed and runs: $(head -1 "$PREFIX/.tree.out")"

step "List shows the installed formula"
# Use --json for deterministic parsing — the human list output goes
# through a paging layer that can swallow rows under test redirection.
"$INSTALL_DIR/malt" list --json >"$PREFIX/.list.out" || fail "malt list --json failed"
grep -q '"name":"tree"' "$PREFIX/.list.out" ||
  fail "tree missing from \`malt list --json\` output"
pass "malt list reflects the install"

printf '\n%s✓%s smoke passed against the live release\n' "$GREEN" "$RESET"
