#!/usr/bin/env bash
# scripts/clean.sh — remove Zig build artifacts and test scratch dirs.
#
# Clears `.zig-cache`, `zig-out`, and `coverage/`, plus any leftover
# test directories under `/tmp` matching the project's test prefixes
# (`malt_*`, `mt_*`, `mt-*`, `ml.*`, `mc_*`).
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
for pattern in \
  '/tmp/malt_*' \
  '/tmp/mt_*' \
  '/tmp/mt-*' \
  '/tmp/ml.*' \
  '/tmp/mc_*'; do
  # Unquoted on purpose so the shell glob-expands the pattern.
  # shellcheck disable=SC2086
  for path in $pattern; do
    [ -e "$path" ] || continue
    remove_tree "$path"
  done
done

echo "Done. Freed ~$(human "$total_kb")."
