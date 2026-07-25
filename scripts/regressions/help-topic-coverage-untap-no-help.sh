#!/usr/bin/env bash
# Regression: every command name the dispatcher accepts must resolve to a real
# help topic. `helpFor` looks names up in a hand-maintained static map and falls
# back to an 18-byte "No help available." stub that still exits 0, so a command
# missing from the map degrades silently, in both help doors (`mt <cmd> -h` and
# `mt help <cmd>`) and with nothing in CI treating it as a failure. `untap`,
# `help` and the `remove`/`ls` aliases were all in that hole.
#
# The name list is derived from main.zig's `command_names` block, not hand
# written, so a command added tomorrow is covered the day it lands. The stub
# itself must survive for genuine typos; otherwise the check could be passed by
# deleting the fallback rather than filling the map.
#
# No network (-h short-circuits before any fetch), no DB writes, well under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "FAIL: malt binary not found at $BIN - run 'zig build' first." >&2
  exit 2
}

TMP=$(mktemp -d -t mt_helpcov.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export MALT_PREFIX="$TMP/prefix"
export NO_COLOR=1

STUB="No help available."

# `--help`, `-h` and `--version` are argv spellings main.zig consumes before any
# topic lookup, not topics of their own.
names=()
while IFS= read -r name; do
  names+=("$name")
done < <(
  rg -o '\.names = &\.\{[^}]*\}' "$ROOT/src/main.zig" |
    rg -o '"[^"]+"' | tr -d '"' |
    rg -v '^(--help|-h|--version)$' | sort -u
)

if ((${#names[@]} <= 25)); then
  echo "FAIL: command_names extractor found only ${#names[@]} names - parse drift?" >&2
  exit 1
fi

fails=()
for n in "${names[@]}"; do
  for door in "-h" "help"; do
    if [[ "$door" == "-h" ]]; then
      out=$("$BIN" "$n" -h 2>&1 || true)
      label="$n -h"
    else
      out=$("$BIN" help "$n" 2>&1 || true)
      label="help $n"
    fi
    [[ "$out" == *"$STUB"* ]] && fails+=("$label")
  done
done

# The stub is correct behaviour for a genuine typo; it must not be deleted.
if ! "$BIN" help not-a-real-command 2>&1 | rg -q "$STUB"; then
  echo "FAIL: unknown-topic fallback disappeared" >&2
  exit 1
fi

if ((${#fails[@]} > 0)); then
  echo "FAIL: no help topic for:" >&2
  printf '  mt %s\n' "${fails[@]}" >&2
  exit 1
fi

echo "PASS: every command name resolves to a real help topic (${#names[@]} names, both doors)"
