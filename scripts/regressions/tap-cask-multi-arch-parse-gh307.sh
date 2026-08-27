#!/usr/bin/env bash
# Regression guard for tap-style casks that use the modern Homebrew
# DSL multi-arch shape:
#
#   on_macos do
#     arch   arm: "-aarch64", intel: ""
#     sha256 arm:   "<hash>",
#            intel: "<hash>"
#     url    "https://.../rebased#{arch}.dmg"
#   end
#
# Before the fix, `parseRubyFormula` only recognised `Hardware::CPU.*`
# and standalone `on_arm`/`on_intel` blocks each carrying their own
# url/sha256 lines. The keyword-arg form (sha256 arm:/intel:, plus the
# `arch` directive that drives `#{arch}` in the URL) walked past every
# section gate and the parser bailed with "Cannot parse … formula".
#
# This script writes a fixture matching the offending shape, drives a
# built `mt` through the local-install dry-run path, and asserts:
#
#   1. Neither parse-failure phrase ("Cannot parse tap formula" /
#      "Cannot parse local formula") appears.
#   2. The dry-run breadcrumb fires — proving the parser reached the
#      materialise stage with version + url + sha256 in hand.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/mt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX=$(mktemp -d /tmp/mt.XXX)
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$PREFIX"' EXIT
mkdir -p "$PREFIX"

cat >"$TMP/rebased.rb" <<'RB'
cask "rebased" do
  version "1.0.12"
  on_macos do
    arch arm: "-aarch64", intel: ""
    sha256 arm:   "3ef9aace106128e78e94777c7fe64228cfa1df816e7cc15b8b1bc054b7df9e9c",
           intel: "93bc02e6c7ba06e907cfa540ed22d9eae0a7e3408810bf3bf07cd18a8bef6cdc"
    url "https://github.com/DetachHead/rebased/releases/download/#{version}/rebased#{arch}.dmg"
  end
  app "Rebased.app"
end
RB

pass() { printf '  ✓ %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# ── Property 1: hermetic --local --dry-run on the offending fixture ──
#
# This is the deterministic core of the regression — no network, no DB
# writes, no archive fetch. If this leg fails the parser still rejects
# the keyword-arg DSL.
LOG="$TMP/install.log"
"$BIN" install --local --dry-run "$TMP/rebased.rb" >"$LOG" 2>&1 || true

if grep -qiE 'Cannot parse (tap|local) formula' "$LOG"; then
  sed 's/^/  | /' "$LOG" >&2
  fail "parser still rejects cask DSL multi-arch shape"
fi

if ! grep -q 'Dry run: would install' "$LOG"; then
  sed 's/^/  | /' "$LOG" >&2
  fail "dry-run breadcrumb missing — parser did not reach materialise"
fi
pass "multi-arch cask DSL parses and routes to materialise (hermetic)"

# ── Property 2: real third-party casks that rely on the same shape ───
#
# These are live tap fetches, so the leg is best-effort: an upstream
# 404 / rate limit / SHA drift skips a candidate; the regression only
# fires if the parser refuses a real cask whose Ruby file uses the
# multi-arch keyword-arg DSL. At least one candidate must reach
# `materializeTapCask` (signalled by the cask install banner) for the
# leg to count as covered, otherwise the leg is skipped.
#
# Each spec is `<tap-slug>:<expected-binary-or-app>` where the
# observable is either `$PREFIX/bin/<bin>` (binary cask) or
# `$PREFIX/Caskroom/<token>/<version>/<App>.app` (app cask). Pure
# parse-failure regressions trip the fail() inside the loop;
# everything else (download, sha, unsupported artifact) is treated
# as a transient skip so flaky upstreams do not poison the signal.
declare -a CANDIDATES=(
  "detachhead/tap/rebased:Rebased.app"
)

if [[ "${MALT_REGRESSION_OFFLINE:-0}" == "1" ]]; then
  skip "MALT_REGRESSION_OFFLINE=1 — skipping live tap-cask install legs"
else
  any_covered=0
  for spec in "${CANDIDATES[@]}"; do
    slug="${spec%:*}"
    expected="${spec##*:}"
    token="${slug##*/}"
    LOG="$TMP/install_${token}.log"
    printf '▸ malt install %s (logs → %s)\n' "$slug" "$LOG"
    "$BIN" install "$slug" >"$LOG" 2>&1 || true

    if grep -qiE 'Cannot parse (tap|local) formula' "$LOG"; then
      sed 's/^/  | /' "$LOG" >&2
      fail "${slug}: parser refused the cask DSL — regression"
    fi

    # The cask installer prints "Installing cask <token> <version>"
    # only after the parser, materializeTapCask, and the artifact
    # fetcher all succeeded. Use that as the proof point — it shows
    # parsing got past the keyword-arg sha256 + arch directives.
    if grep -qE "Installing cask ${token}|installed$| installed " "$LOG"; then
      any_covered=1
      app_link="$PREFIX/Caskroom/${token}"
      bin_link="$PREFIX/bin/${expected}"
      if [[ -d "$app_link" ]] || [[ -L "$bin_link" ]]; then
        pass "${slug}: installed via multi-arch DSL parse"
      else
        skip "${slug}: install reported success but no observable artifact (treating as best-effort)"
      fi
    elif grep -qE "Sha256Mismatch|DownloadFailed|Failed to install|Tap formula/cask not found|rate limit|Network failure" "$LOG"; then
      skip "${slug}: non-regression failure (${LOG##*/}); continuing"
    else
      sed 's/^/  | /' "$LOG" >&2
      fail "${slug}: unclassified outcome — investigate before landing"
    fi
  done

  if ((any_covered == 0)); then
    skip "no live cask exercised the multi-arch DSL (all upstreams were unreachable); hermetic leg still covers the parser"
  fi
fi

printf '\n✔ tap-cask multi-arch DSL regression passed\n'
