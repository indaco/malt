#!/usr/bin/env bash
# Regression: CLI commands built their stdout writer in positional mode, so
# output went out at offset 0 of a regular file and clobbered bytes an earlier
# writer had already put there - under both `>` and `>>` on Darwin.
#
# Needs a built zig-out/bin/mt (run `zig build` first). Offline, no network.

set -euo pipefail

MT=${MT:-./zig-out/bin/mt}
P=$(mktemp -d)
trap 'rm -rf "$P"' EXIT
export MALT_PREFIX=$P MALT_CACHE=$P/c

S=SENTINEL_0123456789_0123456789_0123456789_0123456789
fail=0

# Only commands that print to stdout on an empty prefix: a silent command
# would pass vacuously.
CMDS=("uses x --json" "tap --json" "vulns --json" "services list --json" "search x --json")

check() { # file, args, mode
  if [[ $(head -n1 "$1") != "$S" ]]; then
    echo "FAIL: mt $2 ($3) clobbered earlier stdout bytes" >&2
    fail=1
  elif [[ $(wc -l <"$1") -lt 2 ]]; then
    echo "FAIL: mt $2 ($3) wrote nothing to stdout" >&2
    fail=1
  fi
}

for args in "${CMDS[@]}"; do
  # shellcheck disable=SC2086 # word-splitting the arg string is intended
  {
    echo "$S"
    "$MT" --offline $args 2>/dev/null || true
  } >"$P/a"
  check "$P/a" "$args" ">"
  echo "$S" >"$P/b"
  # shellcheck disable=SC2086
  "$MT" --offline $args >>"$P/b" 2>/dev/null || true
  check "$P/b" "$args" ">>"
done

exit $fail
