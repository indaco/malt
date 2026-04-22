#!/usr/bin/env bash
# scripts/local-smoke-install.sh — heavy install regression guard
#
# Runs real installs against an isolated MALT_PREFIX/MALT_CACHE to catch
# regressions in the bottle download → SHA verify → extract pipeline that
# CI's smoke_test.sh skips for time and bandwidth reasons. Designed for
# pre-push gating (path-aware, in justfile) and pre-release validation.
#
# Cases (each from a fresh sandbox state, so failures isolate cleanly):
#   • mt install node           — large dependency graph (24 packages),
#                                 exercises parallel download + post_install.
#   • mt install zig            — formula bottle path with intra-bundle
#                                 relative symlinks (.xctoolchain layout).
#   • mt install rust           — sibling-formula symlinks (rust -> llvm)
#                                 plus ca-certificates as a dep — pins the
#                                 dispatcher post_install path end-to-end.
#   • mt install go             — classic large-bottle formula, no post_install.
#   • mt install --cask raycast — cask DMG path + /Applications artifact.
#                                 Exercises headResolved redirect-follow
#                                 + DMG mount/install.
#   • mt install --cask copilot-cli — cask `binary` artifact (symlinks a CLI
#                                 into $PREFIX/bin). Exercises the
#                                 non-/Applications cask codepath.
#   • mt install python@3.14 (long prefix) — install_name_tool overflow
#                                 fallback. python@3.14 has the tightest
#                                 @@HOMEBREW_CELLAR@@ slots in homebrew/core;
#                                 under any prefix > 12 bytes the in-place
#                                 patcher overflows by one byte and the
#                                 fallback grows the slot via subprocess.
#                                 The case verifies otool sees the long
#                                 path AND python3.14 actually loads at
#                                 runtime under the long prefix.
#
# Time/bandwidth: ~20-30 min, ~3.5 GB downloaded fresh.
#
# Cleanup: on success (FAIL=0), every cask installed by this run is
# `mt uninstall`-ed and every formula too — so /Applications and any
# other system-touching state malt knows about is reverted before the
# EXIT trap wipes the temp PREFIX/CACHE/LOGDIR. On failure, artifacts
# stay around for triage (matches scripts/local-bench.sh behavior).
#
# App casks are SKIPPED when the target /Applications/<App>.app
# already exists — we never trample the user's pre-existing apps.
# Binary casks land under $MALT_PREFIX/bin so they never need that guard.
#
# Usage:
#   ./scripts/local-smoke-install.sh
#   MT_BIN=./zig-out/bin/mt ./scripts/local-smoke-install.sh

set -uo pipefail

MT_BIN="${MT_BIN:-./zig-out/bin/malt}"

if [[ ! -x "$MT_BIN" ]]; then
  echo "smoke-install: $MT_BIN not found or not executable" >&2
  echo "smoke-install: run 'zig build' first (or set MT_BIN)" >&2
  exit 2
fi
MT_BIN="$(cd "$(dirname "$MT_BIN")" && pwd)/$(basename "$MT_BIN")"

# Short prefix for the main loop. Most bottles' load-command slots fit
# any reasonable prefix in-place; using 11 bytes keeps the fast path
# in scope for the bulk of the run. The python@3.14 case below uses
# its own 13-byte prefix to actively exercise the install_name_tool
# overflow fallback.
PREFIX=$(mktemp -d /tmp/mt.XXX)
CACHE=$(mktemp -d /tmp/mc.XXX)
LOGDIR=$(mktemp -d /tmp/ml.XXX)
trap 'rm -rf "$PREFIX" "$CACHE" "$LOGDIR"' EXIT

export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$CACHE"
# Deterministic, machine-parseable output.
export NO_COLOR=1
export MALT_NO_EMOJI=1

PASS=0
FAIL=0
SKIP=0
FAILURES=()
SKIPS=()
INSTALLED_FORMULAS=()
INSTALLED_CASKS=()

# Run a command; log to LOGDIR; print PASS/FAIL; return its exit status
# so callers can branch on success (e.g. to track what was installed).
run() {
  local tag="$1"
  shift
  local log
  log="$LOGDIR/$(printf '%s' "$tag" | tr -c 'A-Za-z0-9' _).log"
  printf '  RUN   [%s] %s\n' "$tag" "$*"
  if "$@" >"$log" 2>&1; then
    printf '  PASS  [%s]\n' "$tag"
    PASS=$((PASS + 1))
    return 0
  fi
  local rc=$?
  printf '  FAIL  [%s] rc=%s log=%s\n' "$tag" "$rc" "$log"
  sed -n '1,30p' "$log" | sed 's/^/        | /'
  printf '        --- tail ---\n'
  tail -30 "$log" | sed 's/^/        | /'
  FAIL=$((FAIL + 1))
  FAILURES+=("$tag")
  return "$rc"
}

# Install a formula and remember it for success-time cleanup.
install_formula() {
  local tag="$1" name="$2"
  if run "$tag" "$MT_BIN" install "$name"; then
    INSTALLED_FORMULAS+=("$name")
  fi
}

# Install a cask, but only if its /Applications/<App>.app slot is empty.
# Refusing to overwrite a pre-existing user install means uninstall on
# success can never remove something the user wants to keep.
install_cask() {
  local tag="$1" cask="$2" app_name="$3"
  local app_path="/Applications/$app_name"
  if [ -e "$app_path" ]; then
    printf '  SKIP  [%s] %s pre-exists; cask install would overwrite a user app\n' "$tag" "$app_path"
    SKIP=$((SKIP + 1))
    SKIPS+=("$tag")
    return
  fi
  if run "$tag" "$MT_BIN" install --cask "$cask"; then
    INSTALLED_CASKS+=("$cask")
  fi
}

# Install a cask whose only artifact is a `binary` (CLI tool) — no
# /Applications slot, so the app-pre-exists guard does not apply. The
# binary symlink lands under $MALT_PREFIX/bin, so it cannot collide
# with anything outside the sandbox.
install_binary_cask() {
  local tag="$1" cask="$2"
  if run "$tag" "$MT_BIN" install --cask "$cask"; then
    INSTALLED_CASKS+=("$cask")
  fi
}

# python@3.14 + a >12-byte MALT_PREFIX is the canonical install_name_tool
# overflow case: tight @@HOMEBREW_CELLAR@@ slots overflow by one byte
# and the in-place patcher hands them to install_name_tool. We pin both
# the patched-binary shape (otool sees the long path) and the runtime
# (python3.14 imports ssl, proving the rewritten LC_LOAD_DYLIBs resolve
# under dyld). Self-contained: own prefix/cache, own cleanup.
install_python_overflow_fallback() {
  local tag="smoke.install.python_overflow_fallback"
  local long_prefix=/tmp/mt_tahoe # 13 bytes — just over the placeholder
  local long_cache=/tmp/mc_tahoe
  rm -rf "$long_prefix" "$long_cache"
  trap 'rm -rf "$PREFIX" "$CACHE" "$LOGDIR" "$long_prefix" "$long_cache"' EXIT

  if MALT_PREFIX="$long_prefix" MALT_CACHE="$long_cache" \
    run "$tag" "$MT_BIN" install python@3.14; then
    local libpath
    libpath=$(find "$long_prefix/Cellar/python@3.14" -name 'libpython3.14.dylib' 2>/dev/null | head -1)
    if [[ -n "$libpath" ]] && otool -L "$libpath" 2>/dev/null | grep -q "$long_prefix"; then
      printf '  PASS  [%s.otool] long prefix in LC_LOAD_DYLIB\n' "$tag"
      PASS=$((PASS + 1))
    else
      printf '  FAIL  [%s.otool] %s missing from LC_LOAD_DYLIB\n' "$tag" "$long_prefix"
      FAIL=$((FAIL + 1))
      FAILURES+=("$tag.otool")
    fi
    if MALT_PREFIX="$long_prefix" "$long_prefix/bin/python3.14" \
      -c 'import ssl' >/dev/null 2>&1; then
      printf '  PASS  [%s.runtime] python3.14 imports ssl under long prefix\n' "$tag"
      PASS=$((PASS + 1))
    else
      printf '  FAIL  [%s.runtime] python3.14 dyld broken under long prefix\n' "$tag"
      FAIL=$((FAIL + 1))
      FAILURES+=("$tag.runtime")
    fi
    MALT_PREFIX="$long_prefix" "$MT_BIN" uninstall python@3.14 >/dev/null 2>&1 || true
  fi
  rm -rf "$long_prefix" "$long_cache"
}

# Reverse what we installed. Casks first because they touch /Applications;
# formulas second (they live entirely under MALT_PREFIX, but uninstalling
# also exercises the uninstall path). Best-effort: a stuck uninstall must
# not block the script from completing.
cleanup_installs() {
  printf '\n── Cleanup ───────────────────────────────────────\n'
  local item
  for item in "${INSTALLED_CASKS[@]}"; do
    printf '  uninstall cask %s\n' "$item"
    "$MT_BIN" uninstall --cask "$item" >/dev/null 2>&1 ||
      printf '  WARN: uninstall --cask %s exited non-zero (continuing)\n' "$item"
  done
  for item in "${INSTALLED_FORMULAS[@]}"; do
    printf '  uninstall formula %s\n' "$item"
    "$MT_BIN" uninstall "$item" >/dev/null 2>&1 ||
      printf '  WARN: uninstall %s exited non-zero (continuing)\n' "$item"
  done
}

printf '── Local install smoke ───────────────────────────\n'
printf '  PREFIX=%s (%d bytes)\n' "$PREFIX" "${#PREFIX}"
printf '  CACHE=%s\n' "$CACHE"
printf '  MT_BIN=%s\n\n' "$MT_BIN"

run smoke.update "$MT_BIN" update
install_formula smoke.install.node node
install_formula smoke.install.zig zig
install_formula smoke.install.rust rust
install_formula smoke.install.go go
install_cask smoke.install.cask.raycast raycast Raycast.app
install_binary_cask smoke.install.cask.copilot-cli copilot-cli
install_python_overflow_fallback

printf '\n── Summary ───────────────────────────────────────\n'
printf '  passed: %d\n' "$PASS"
printf '  failed: %d\n' "$FAIL"
printf '  skipped: %d\n' "$SKIP"
if ((SKIP > 0)); then
  printf '  skips: %s\n' "${SKIPS[*]}"
fi
if ((FAIL > 0)); then
  printf '  failures: %s\n' "${FAILURES[*]}"
  printf '\n  triage state preserved in:\n'
  printf '    PREFIX=%s\n' "$PREFIX"
  printf '    LOGDIR=%s\n' "$LOGDIR"
  # Drop the EXIT trap so artifacts survive for triage.
  trap - EXIT
  exit 1
fi

cleanup_installs
exit 0
