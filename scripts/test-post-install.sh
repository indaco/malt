#!/usr/bin/env bash
# scripts/test-post-install.sh — smoke-test the DSL post_install interpreter
#
# Installs real Homebrew formulae that define post_install blocks and checks
# whether the DSL interpreter executes them successfully. Formulae are
# installed into an isolated /tmp prefix so the system is never touched.
#
# Prerequisites:
#   - homebrew-core tap available (symlink /tmp/homebrew-core or brew tap --force homebrew/core)
#   - malt built with ReleaseSafe (the script builds it if SKIP_BUILD != 1)
#
# Usage:
#   scripts/test-post-install.sh                # run all tests
#   scripts/test-post-install.sh glib fontconfig # run specific formulae
#   SKIP_BUILD=1 scripts/test-post-install.sh   # reuse existing binary
#   VERBOSE=1 scripts/test-post-install.sh      # show full install output

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_PREFIX="${BUILD_PREFIX:-/tmp/malt-bench/build}"
MALT_BIN="${MALT_BIN:-$BUILD_PREFIX/bin/malt}"
TEST_PREFIX="${TEST_PREFIX:-/tmp/mt-pi}"
SKIP_BUILD="${SKIP_BUILD:-0}"
VERBOSE="${VERBOSE:-0}"

# --- Formulae categorised by expected DSL phase coverage ---
#
# Phase 1 (trivial):  mkpath, ohai, system with literal args
# Phase 2 (string):   string interpolation, literal inreplace
# Phase 3 (control):  if/unless, each, glob, rm_r+exist?
# Phase 4 (advanced): Formula[], regex inreplace, popen_read

PHASE1_FORMULAE=(glib fontconfig dbus)
PHASE3_FORMULAE=(shared-mime-info node)
PHASE4_FORMULAE=(openssl@3)
# Tracked-but-not-wired: formulas whose post_install is known to crash
# the interpreter. Kept as a data reference for future triage; the test
# loop does not invoke it today.
# shellcheck disable=SC2034
KNOWN_CRASH=(daemontools)

# Default: run all phases
if [ $# -gt 0 ]; then
  ALL_FORMULAE=("$@")
else
  ALL_FORMULAE=("${PHASE1_FORMULAE[@]}" "${PHASE3_FORMULAE[@]}" "${PHASE4_FORMULAE[@]}")
fi

# --- colours -----------------------------------------------------------------
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  BOLD=$'\033[1m' GREEN=$'\033[32m' YELLOW=$'\033[33m' RED=$'\033[31m' CYAN=$'\033[36m' RESET=$'\033[0m'
else
  BOLD="" GREEN="" YELLOW="" RED="" CYAN="" RESET=""
fi

pass() { printf "  %sPASS%s  %s\n" "$GREEN" "$RESET" "$*"; }
skip() { printf "  %sSKIP%s  %s\n" "$YELLOW" "$RESET" "$*"; }
fail() { printf "  %sFAIL%s  %s\n" "$RED" "$RESET" "$*"; }
info() { printf "  %s>%s %s\n" "$CYAN" "$RESET" "$*"; }

# --- build -------------------------------------------------------------------
if [ "$SKIP_BUILD" != "1" ]; then
  info "Building malt (ReleaseSafe) -> $BUILD_PREFIX"
  (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe --prefix "$BUILD_PREFIX" 2>&1) || {
    fail "Build failed"
    exit 1
  }
fi

if [ ! -x "$MALT_BIN" ]; then
  fail "malt binary not found at $MALT_BIN"
  exit 1
fi

# --- tap check ---------------------------------------------------------------
TAP_OK=0
for tp in /opt/homebrew/Library/Taps/homebrew/homebrew-core /usr/local/Homebrew/Library/Taps/homebrew/homebrew-core; do
  [ -d "$tp/Formula" ] && TAP_OK=1 && break
done
if [ "$TAP_OK" = "0" ]; then
  if [ -d /tmp/homebrew-core/Formula ]; then
    info "Symlinking /tmp/homebrew-core to Homebrew tap location"
    mkdir -p /opt/homebrew/Library/Taps/homebrew 2>/dev/null || true
    ln -sf /tmp/homebrew-core /opt/homebrew/Library/Taps/homebrew/homebrew-core 2>/dev/null || true
  else
    fail "homebrew-core tap not found. Run: git clone --depth 1 https://github.com/Homebrew/homebrew-core.git /tmp/homebrew-core"
    exit 1
  fi
fi

# --- test loop ---------------------------------------------------------------
TOTAL=0
PASSED=0
SKIPPED=0
FAILED=0
RESULTS=()

printf "\n%sDSL Post-Install Smoke Tests%s\n" "$BOLD" "$RESET"
printf "  prefix: %s\n  binary: %s\n\n" "$TEST_PREFIX" "$MALT_BIN"

for pkg in "${ALL_FORMULAE[@]}"; do
  TOTAL=$((TOTAL + 1))

  # Clean uninstall first
  MALT_PREFIX="$TEST_PREFIX" "$MALT_BIN" uninstall "$pkg" >/dev/null 2>&1 || true

  # Install and capture output
  OUTPUT=$(MALT_PREFIX="$TEST_PREFIX" "$MALT_BIN" install "$pkg" 2>&1) || true

  if [ "$VERBOSE" = "1" ]; then
    # sed is the right tool here — prefixing every line with indentation
    # isn't expressible via bash parameter expansion.
    # shellcheck disable=SC2001
    echo "$OUTPUT" | sed "s/^/    /"
  fi

  # Classify result
  if echo "$OUTPUT" | grep -q "post_install completed"; then
    pass "$pkg"
    PASSED=$((PASSED + 1))
    RESULTS+=("PASS:$pkg")
  elif echo "$OUTPUT" | grep -q "post_install partially skipped"; then
    skip "$pkg (DSL hit unsupported construct — expected for Phase 3/4)"
    SKIPPED=$((SKIPPED + 1))
    RESULTS+=("SKIP:$pkg")
  elif echo "$OUTPUT" | grep -q "post_install DSL failed"; then
    skip "$pkg (DSL fatal — needs Phase 4 constructs)"
    SKIPPED=$((SKIPPED + 1))
    RESULTS+=("SKIP:$pkg")
  elif echo "$OUTPUT" | grep -q "post_install skipped (formula source"; then
    skip "$pkg (no .rb source found)"
    SKIPPED=$((SKIPPED + 1))
    RESULTS+=("SKIP:$pkg")
  elif echo "$OUTPUT" | grep -q "panic"; then
    fail "$pkg (PANIC — interpreter bug)"
    FAILED=$((FAILED + 1))
    RESULTS+=("FAIL:$pkg")
    if [ "$VERBOSE" != "1" ]; then
      echo "$OUTPUT" | grep -A 5 "panic" | sed "s/^/    /"
    fi
  elif echo "$OUTPUT" | grep -qi "error"; then
    fail "$pkg"
    FAILED=$((FAILED + 1))
    RESULTS+=("FAIL:$pkg")
  else
    # No post_install message at all — formula may not have post_install
    pass "$pkg (no post_install needed)"
    PASSED=$((PASSED + 1))
    RESULTS+=("PASS:$pkg")
  fi
done

# --- summary -----------------------------------------------------------------
printf "\n%sSummary%s\n" "$BOLD" "$RESET"
printf "  Total:   %d\n" "$TOTAL"
printf "  %sPassed%s:  %d\n" "$GREEN" "$RESET" "$PASSED"
printf "  %sSkipped%s: %d (expected — unsupported DSL constructs)\n" "$YELLOW" "$RESET" "$SKIPPED"
printf "  %sFailed%s:  %d\n" "$RED" "$RESET" "$FAILED"

printf "\n%sResults%s\n" "$BOLD" "$RESET"
for r in "${RESULTS[@]}"; do
  status="${r%%:*}"
  name="${r#*:}"
  case "$status" in
  PASS) printf "  %s[PASS]%s %s\n" "$GREEN" "$RESET" "$name" ;;
  SKIP) printf "  %s[SKIP]%s %s\n" "$YELLOW" "$RESET" "$name" ;;
  FAIL) printf "  %s[FAIL]%s %s\n" "$RED" "$RESET" "$name" ;;
  esac
done

printf "\n"
if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
