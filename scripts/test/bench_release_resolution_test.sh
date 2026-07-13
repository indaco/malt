#!/usr/bin/env bash
# scripts/test/bench_release_resolution_test.sh — unit tests for the pure
# helpers behind scripts/bench.sh's latest-release pinning and cold-install
# anomaly guard. bench.sh is sourced with BENCH_LIB=1 so the functions load
# without running the benchmark.
#
# Covers:
#   1. pick_latest_tag — version-sorts real `git ls-remote` output, drops
#      pre-release and non-vX.Y.Z refs, and returns the highest release
#      (v0.1.201 must win over v0.1.99 — plain lexical sort gets this wrong).
#   2. over_threshold — the guard predicate: a peer tool's cold median above
#      the ceiling trips; FAIL/empty medians and a disabled (0) ceiling never
#      trip, so a legitimately slow-but-fine number is never hidden by mistake.
#
# Usage:
#   ./scripts/test/bench_release_resolution_test.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

# shellcheck source=/dev/null
BENCH_LIB=1 source "$ROOT/scripts/bench.sh"

fail=0
check() {
  # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s: expected [%s] got [%s]\n' "$1" "$2" "$3" >&2
    fail=1
  fi
}

# check_pred <description> <expected 0|1> <cmd...>
check_pred() {
  local desc="$1" want="$2"
  shift 2
  local got=0
  "$@" || got=$?
  # normalise any non-zero to 1
  [ "$got" -eq 0 ] || got=1
  check "$desc" "$want" "$got"
}

echo "pick_latest_tag:"
# Real ls-remote shape: "<sha>\trefs/tags/<tag>" plus peeled "^{}" entries.
lsremote=$(
  cat <<'EOF'
1111111111111111111111111111111111111111	refs/tags/v0.1.9
2222222222222222222222222222222222222222	refs/tags/v0.1.99
3333333333333333333333333333333333333333	refs/tags/v0.1.201
3333333333333333333333333333333333333333	refs/tags/v0.1.201^{}
4444444444444444444444444444444444444444	refs/tags/v0.1.201-rc1
5555555555555555555555555555555555555555	refs/tags/nightly
EOF
)
check "highest release wins over lexical" "v0.1.201" "$(printf '%s\n' "$lsremote" | pick_latest_tag)"
check "bare tag list" "v0.3.2" "$(printf 'v0.2.1\nv0.3.0\nv0.3.2\nv0.2.9\n' | pick_latest_tag)"
check "empty input yields empty" "" "$(printf '' | pick_latest_tag)"
check "no stable tags yields empty" "" "$(printf 'v1.0.0-rc1\nmain\n' | pick_latest_tag)"

echo "pick_latest_release_branch:"
# Real ls-remote --heads shape for the release/N.M branch line.
heads=$(
  cat <<'EOF'
1111111111111111111111111111111111111111	refs/heads/main
2222222222222222222222222222222222222222	refs/heads/release/0.9
3333333333333333333333333333333333333333	refs/heads/release/0.19
4444444444444444444444444444444444444444	refs/heads/release/0.20
5555555555555555555555555555555555555555	refs/heads/feature/release-notes
EOF
)
check "highest minor wins (0.20 > 0.19 > 0.9)" "release/0.20" "$(printf '%s\n' "$heads" | pick_latest_release_branch)"
check "bare ref list" "release/0.20" "$(printf 'release/0.18\nrelease/0.20\nrelease/0.19\n' | pick_latest_release_branch)"
check "empty input yields empty" "" "$(printf '' | pick_latest_release_branch)"
check "non-release refs ignored" "" "$(printf 'main\nfeature/release/0.20\n' | pick_latest_release_branch)"

echo "over_threshold:"
check_pred "130.802 over 30 trips" 0 over_threshold "130.802" "30"
check_pred "2.9 under 30 does not trip" 1 over_threshold "2.933" "30"
check_pred "exactly 30 does not trip" 1 over_threshold "30" "30"
check_pred "FAIL never trips" 1 over_threshold "FAIL" "30"
check_pred "empty median never trips" 1 over_threshold "" "30"
check_pred "disabled ceiling (0) off" 1 over_threshold "999" "0"

if [ "$fail" -ne 0 ]; then
  echo "bench release-resolution tests FAILED" >&2
  exit 1
fi
echo "bench release-resolution tests passed"
