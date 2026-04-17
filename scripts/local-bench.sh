#!/usr/bin/env bash
# scripts/local-bench.sh — run the benchmark workflow locally
#
# Mirrors .github/workflows/benchmark.yml step-for-step so you can see
# what CI will publish before it publishes. Useful for:
#   - validating bench.sh changes before merging to main
#   - sanity-checking numbers against a freshly built malt
#   - reproducing a suspect CI result on a known-good laptop
#
# Runs four phases in order (first failure aborts the rest):
#   1. bench tree   — rebuilds malt + clones/updates nanobrew/zerobrew
#   2. bench wget   — reuses the tree build (SKIP_BUILD=1)
#   3. bench ffmpeg — reuses the tree build
#   4. stress ffmpeg ×20 — malt-only cold-install race detector
#
# If you only want to iterate on part of the bench, call scripts/bench.sh directly.
#
# Usage:
#   scripts/local-bench.sh           # run the full 1:1 CI simulation
#   scripts/local-bench.sh --clean   # same, then wipe /tmp bench state
#
# Env overrides (same defaults as CI — override to differ):
#   BENCH_TRUE_COLD  (default 1)  wipe /tmp prefixes before each cold install
#   BENCH_FAIL_FAST  (default 1)  abort on first non-zero install exit
#
# --clean runs *after* a successful bench and removes:
#   - $BENCH_WORK_DIR      (default /tmp/malt-bench) — peer clones + builds
#   - $MALT_BENCH_PREFIX   (default /tmp/mt-b)       — malt install prefix
#   - $NB_BENCH_PREFIX     (default /tmp/nb)         — nanobrew install prefix
#   - $ZB_BENCH_PREFIX     (default /tmp/zb)         — zerobrew install prefix
#   - /tmp/malt-bench.out                            — last install log
#
# Cleanup refuses to touch anything outside /tmp (same safety rule
# bench.sh's BENCH_TRUE_COLD uses). Bench failures skip cleanup so the
# artifacts stay around for triage.

set -euo pipefail

CLEAN=0
for arg in "$@"; do
  case "$arg" in
  --clean) CLEAN=1 ;;
  -h | --help)
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *)
    printf 'unknown argument: %s\n' "$arg" >&2
    printf 'try: %s --help\n' "$0" >&2
    exit 2
    ;;
  esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

export BENCH_TRUE_COLD="${BENCH_TRUE_COLD:-1}"
export BENCH_FAIL_FAST="${BENCH_FAIL_FAST:-1}"

./scripts/bench.sh tree
SKIP_BUILD=1 ./scripts/bench.sh wget
SKIP_BUILD=1 ./scripts/bench.sh ffmpeg
BENCH_STRESS=20 SKIP_BUILD=1 SKIP_OTHERS=1 SKIP_BREW=1 ./scripts/bench.sh ffmpeg

if [ "$CLEAN" = "1" ]; then
  printf '\n▸ cleaning /tmp bench state\n' >&2

  # Resolve paths using the same defaults bench.sh uses, so user env
  # overrides (BENCH_WORK_DIR, *_BENCH_PREFIX) are honored.
  WORK_DIR="${BENCH_WORK_DIR:-/tmp/malt-bench}"
  MALT_BENCH_PREFIX="${MALT_BENCH_PREFIX:-/tmp/mt-b}"
  NB_BENCH_PREFIX="${NB_BENCH_PREFIX:-/tmp/nb}"
  ZB_BENCH_PREFIX="${ZB_BENCH_PREFIX:-/tmp/zb}"

  wipe_tmp() {
    local p="$1"
    case "$p" in
    /tmp/*)
      if [ -e "$p" ]; then
        rm -rf "$p" && printf '  ✓ rm -rf %s\n' "$p" >&2
      fi
      ;;
    *)
      printf '  ⚠ refusing to wipe path outside /tmp: %s\n' "$p" >&2
      ;;
    esac
  }

  wipe_tmp "$WORK_DIR"
  wipe_tmp "$MALT_BENCH_PREFIX"
  wipe_tmp "$NB_BENCH_PREFIX"
  wipe_tmp "$ZB_BENCH_PREFIX"
  wipe_tmp /tmp/malt-bench.out
fi
