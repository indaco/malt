#!/usr/bin/env bash
# Regression: a bypass hint with the assignment before `curl` sets the
# variable for `curl` only. The `bash` that runs the installer never sees it,
# so the gate refuses again.
#
# This script only reads text. It never runs a hint. Each hint must be one
# `curl ... | VAR=1 bash` pipeline, or `VAR=1 bash /path/to/install.sh` for a local copy.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INSTALLER=${INSTALL_SH:-$ROOT/scripts/install.sh}
PIPE_MARKER='To bypass (not recommended): '
LOCAL_MARKER='Or, from a downloaded copy: '

fail=0
count=0
while IFS= read -r line; do
  count=$((count + 1))
  cmd=${line#*"$PIPE_MARKER"}
  cmd=${cmd%\"} # the last line of an error string ends with a quote
  var=$(grep -oE 'MALT_[A-Z_]+' <<<"$cmd" | head -1 || true)
  if [ -z "$var" ]; then
    echo "FAIL: no MALT_* variable in hint: $cmd" >&2
    fail=1
    continue
  fi
  # The installer must read the variable the hint names.
  if ! grep -qF "\${$var:-0}" "$INSTALLER"; then
    echo "FAIL: install.sh never reads $var" >&2
    fail=1
  fi
  # The assignment must follow the pipe, right before `bash`. The URL may use
  # ${REPO}, but no command separator, redirect or substitution.
  # shellcheck disable=SC2016 # the backtick and $ are literal here
  re='^curl [^|;&<>`()]*\| *'"$var"'=1 bash$'
  if ! [[ $cmd =~ $re ]]; then
    echo "FAIL: hint is not 'curl ... | $var=1 bash': $cmd" >&2
    fail=1
  fi
  # Each pipe hint needs a matching local-copy hint.
  if ! grep -qE "^ *${LOCAL_MARKER}${var}=1 bash /path/to/install\.sh\"?$" "$INSTALLER"; then
    echo "FAIL: no '${LOCAL_MARKER}${var}=1 bash /path/to/install.sh' hint for $var" >&2
    fail=1
  fi
done < <(grep -F "$PIPE_MARKER" "$INSTALLER")

if [ "$count" -lt 2 ]; then
  echo "FAIL: expected >=2 bypass hints in install.sh, found $count" >&2
  exit 1
fi
exit "$fail"
