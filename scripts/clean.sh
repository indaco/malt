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
  # Test fixtures can land with restricted perms that block rm -rf.
  # Make directories writable and traversable before deleting.
  find "$path" -type d -exec chmod u+rwx {} + 2>/dev/null || true
  local kb
  kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
  kb=${kb:-0}
  rm -rf "$path"
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
