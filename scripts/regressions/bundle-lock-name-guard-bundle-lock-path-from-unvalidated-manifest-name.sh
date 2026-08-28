#!/usr/bin/env bash
# Regression: a Maltfile `name` is author-controlled text, so it must be
# screened before it is formatted into the bundle lock path.
#
# The bug: `run` interpolated the manifest name straight into
# "<prefix>/var/malt/bundles/<name>.lock" and handed that to the lock file,
# which creates the path and truncates it to zero bytes on release. A name
# carrying `..` therefore created — or clobbered — any `*.lock` on disk, and a
# name carrying `/` silently re-targeted the lock, voiding the mutual
# exclusion it exists to provide.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# `zig build test` never refreshes the CLI binary; build it so this exercises
# current source rather than a stale artefact.
if ! zig build >/dev/null 2>&1; then
  echo "FAIL: could not build the malt binary (zig build)" >&2
  exit 1
fi

MT="${MT:-$ROOT/zig-out/bin/mt}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/px/var/malt/bundles" "$TMP/out" "$TMP/wd"

# Canary outside the prefix; a truncating lock would leave it at 0 bytes.
printf 'CANARY\n' >"$TMP/out/victim.lock"

fail=0

# Empty `formulas` keeps this offline: the lock is taken before any member
# would be dispatched.
for name in "../../escape" "../../../../out/victim" "a/b" ".." "."; do
  printf '{"name": "%s", "version": 1, "formulas": []}\n' "$name" >"$TMP/wd/Maltfile.json"
  if (cd "$TMP/wd" && MALT_PREFIX="$TMP/px" "$MT" bundle install Maltfile.json >/dev/null 2>&1); then
    echo "FAIL: bundle install accepted hostile manifest name '$name'" >&2
    fail=1
  fi
done

# The refusal must name the cause, not leak an error tag.
printf '{"name": "../../escape", "version": 1, "formulas": []}\n' >"$TMP/wd/Maltfile.json"
msg=$(cd "$TMP/wd" && MALT_PREFIX="$TMP/px" "$MT" bundle install Maltfile.json 2>&1 || true)
if ! printf '%s' "$msg" | grep -Fq 'bundle name is not a valid path component'; then
  echo "FAIL: refusal did not explain why the bundle name was rejected" >&2
  fail=1
fi

stray=$(find "$TMP/px" "$TMP/out" -name '*.lock' \
  ! -path "$TMP/px/var/malt/bundles/*" ! -path "$TMP/out/victim.lock" || true)
if [[ -n "$stray" ]]; then
  echo "FAIL: lock created outside the bundles directory: $stray" >&2
  fail=1
fi

if [[ "$(wc -c <"$TMP/out/victim.lock" | tr -d ' ')" -ne 7 ]]; then
  echo "FAIL: a lock release truncated a file outside the bundles directory" >&2
  fail=1
fi

# A legitimate name, and the absent-name fallback, must still install.
for body in '{"name": "tiny", "version": 1, "formulas": []}' '{"version": 1, "formulas": []}'; do
  printf '%s\n' "$body" >"$TMP/wd/Maltfile.json"
  if ! (cd "$TMP/wd" && MALT_PREFIX="$TMP/px" "$MT" bundle install Maltfile.json >/dev/null 2>&1); then
    echo "FAIL: guard rejects a legitimate bundle: $body" >&2
    fail=1
  fi
done

if [[ "$fail" -ne 0 ]]; then
  exit 1
fi

echo "PASS: bundle lock path stays inside the bundles directory"
