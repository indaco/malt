#!/usr/bin/env bash
# Guard the exit contract of `malt version update` when the self-binary
# swap fails.
#
# Every `replaceBinary` catch arm in `execute` that handles a
# `swap.SwapError` must return an error so the process exits non-zero.
# A bare `return;` there prints "Failed to replace ..." and exits 0, so
# `mt version update --yes && ...` keeps going on the old binary.
#
# The swap step sits behind a live GitHub API GET, an asset download and
# cosign verification, so it cannot be driven offline; the inline unit
# test covers the mapping at runtime and this script pins the call-site
# shape. No build, no network, no temp state.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FILE="$ROOT/src/cli/version_update.zig"

# Anchor on `execute`'s first arm: `RollbackFailed` also appears in the
# helper's switch. Fail loudly if it moves so this never silently passes.
start=$(grep -nm1 'error.StagingFailed, error.SwapFailed =>' "$FILE" | cut -d: -f1 || true)
if [ -z "$start" ]; then
  echo "FAIL: replace-failure switch arm not found in $FILE - guard needs updating" >&2
  exit 2
fi

# Scan each SwapError arm and reject a void return: a bare `return;` in a
# block arm or `=> return,` on a one-line arm. Braces are counted so a
# nested block inside the arm does not end the scan early.
# `return error.X;` / `return reportReplaceFailure(...)` pass.
for arm in 'error.StagingFailed, error.SwapFailed =>' 'error.RollbackFailed =>'; do
  body=$(awk -v a="$arm" -v s="$start" 'NR>=s && !f && index($0,a){f=1} f{print; d+=gsub(/\{/,"{")-gsub(/\}/,"}"); if(d<=0) exit}' "$FILE")
  if [ -z "$body" ]; then
    echo "FAIL: '$arm' arm not found after anchor - guard needs updating" >&2
    exit 2
  fi
  if grep -qE '^[[:space:]]*return;|=>[[:space:]]*return,' <<<"$body"; then
    echo "FAIL: '$arm' arm returns void - a failed self-update would exit 0" >&2
    exit 1
  fi
done

echo "OK: every self-replace failure arm exits non-zero"
