#!/usr/bin/env bash
# scripts/clean.sh — remove Zig build artifacts and test scratch dirs.
#
# Clears `.zig-cache`, `zig-out`, and `coverage/`, plus any leftover
# test / e2e / smoke / bench directories under `/tmp`. Covers every
# variant used by the project:
#   malt_* / malt-*            Zig test scratch + bench work dir
#   mt_* / mt-* / mt.*         CLI test dirs, bench prefix, smoke PREFIX
#   ml_* / ml.*                LOGDIR (smoke + e2e security)
#   mc_* / mc.*                CACHE  (smoke + e2e security)
# and the bench peer-tool prefixes (/tmp/nb, /tmp/zb, /tmp/malt-bench),
# honouring BENCH_WORK_DIR / MALT_BENCH_PREFIX / NB_BENCH_PREFIX /
# ZB_BENCH_PREFIX env overrides so tweaked paths still get cleaned.
#
# Some integration tests mint read-only Cellar/<pkg>/1.0/bin fixtures
# that defeat a plain `rm -rf`; this script chmods everything writable
# first.
#
# Usage:
#   scripts/clean.sh

set -euo pipefail

cd "$(dirname "$0")/.."

# Cap each filesystem walk so a stuck target (stale automount, held
# resource, multi-GB tree) surfaces as a warning instead of hanging the
# whole clean. macOS ships no `timeout`; prefer it, fall back to
# `gtimeout`, else run uncapped. CLEAN_TIMEOUT overrides the cap (seconds).
timeout_secs=${CLEAN_TIMEOUT:-120}
if command -v timeout >/dev/null 2>&1; then
  timeout_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
  timeout_bin=gtimeout
else
  timeout_bin=
fi

# Run a command under the cap when one is available, else run it bare.
# String var (not array) keeps this working under macOS bash 3.2.
capped() {
  if [ -n "$timeout_bin" ]; then
    "$timeout_bin" "$timeout_secs" "$@"
  else
    "$@"
  fi
}

human() {
  local k=$1
  if [ "$k" -ge 1048576 ]; then
    awk -v k="$k" 'BEGIN { printf "%.1fG", k/1048576 }'
  elif [ "$k" -ge 1024 ]; then
    awk -v k="$k" 'BEGIN { printf "%.1fM", k/1024 }'
  else
    printf "%dK" "$k"
  fi
}

total_kb=0
remove_tree() {
  local path="$1"
  [ -e "$path" ] || return 0
  # Announce before the walks so a slow or stuck target is visible
  # rather than a silent hang under the section header.
  printf "  removing %s ...\n" "$path"
  # Test fixtures can land with restricted perms that block rm -rf.
  # Make directories writable and traversable before deleting.
  capped find "$path" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  local kb
  kb=$(capped du -sk "$path" 2>/dev/null | awk '{print $1}') || true
  kb=${kb:-0}
  if ! capped rm -rf "$path"; then
    printf "  ⚠ skipped %s — exceeded %ss cap (stale mount or held resource?)\n" \
      "$path" "$timeout_secs" >&2
    return 0
  fi
  total_kb=$((total_kb + kb))
  printf "  removed %-44s %7s\n" "$path" "$(human "$kb")"
}

echo "▸ Build artifacts"
remove_tree .zig-cache
remove_tree zig-out
remove_tree coverage

echo "▸ Test scratch under /tmp"
# Patterns cover every mktemp/fixture prefix across tests + e2e + smoke +
# bench. The underscore / dot / hyphen variants are intentional - smoke
# uses `mktemp -d /tmp/mt.XXX`, e2e security uses `mt_sec.XXX`, bench
# uses `/tmp/malt-bench`. Missing one variant leaks multi-GB Cellar or
# cache dirs on every crashed run.
for pattern in \
  '/tmp/malt_*' \
  '/tmp/malt-*' \
  '/tmp/mt_*' \
  '/tmp/mt-*' \
  '/tmp/mt.*' \
  '/tmp/ml_*' \
  '/tmp/ml.*' \
  '/tmp/mc_*' \
  '/tmp/mc.*'; do
  # Unquoted on purpose so the shell glob-expands the pattern.
  # shellcheck disable=SC2086
  for path in $pattern; do
    [ -e "$path" ] || continue
    remove_tree "$path"
  done
done

# The sandbox fence tests cannot root their scratch under /tmp: the macOS
# profile grants blanket write there, so the fence would pass without
# proving anything. They use ~/.cache instead, which the loop above misses.
if [ -n "${HOME:-}" ]; then
  echo "▸ Fence scratch under \$HOME/.cache"
  for path in "$HOME"/.cache/malt_fence_*; do
    [ -e "$path" ] || continue
    remove_tree "$path"
  done
fi

echo "▸ Bench peer-tool prefixes"
# Mirror bench.sh defaults; honour env overrides so user-tweaked paths
# still get cleaned.
for path in \
  "${BENCH_WORK_DIR:-/tmp/malt-bench}" \
  "${MALT_BENCH_PREFIX:-/tmp/mt-b}" \
  "${NB_BENCH_PREFIX:-/tmp/nb}" \
  "${ZB_BENCH_PREFIX:-/tmp/zb}"; do
  case "$path" in
  /tmp/*) [ -e "$path" ] && remove_tree "$path" ;;
  *) printf "  ⚠ refusing to wipe path outside /tmp: %s\n" "$path" ;;
  esac
done

echo "Done. Freed ~$(human "$total_kb")."
