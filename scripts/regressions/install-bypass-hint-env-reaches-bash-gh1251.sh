#!/usr/bin/env bash
# Regression: the installer's "To bypass" hints put the opt-out assignment
# before `curl`. In `VAR=1 curl ... | bash` only `curl` gets the variable, so
# the `bash` that runs the installer never sees it and the gate refuses again.
#
# Static over install.sh text plus a local pipeline: each hint is rebuilt with
# the download swapped for a probe that prints the variable as `bash` sees it.
# No network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INSTALLER="$ROOT/scripts/install.sh"

fail=0
count=0
while IFS= read -r line; do
  count=$((count + 1))
  cmd=${line#*: } # text after "To bypass (not recommended): "
  cmd=${cmd%\"}   # drop the closing quote of the error string
  var=$(grep -oE 'MALT_[A-Z_]+' <<<"$cmd" | head -1)
  # shellcheck disable=SC2016 # ${var} must reach the probe bash unexpanded
  probe="printf '%s\n' 'echo \${$var:-unset}'"
  runnable=$(sed -E "s#curl [^|]*\|#$probe |#" <<<"$cmd")
  got=$(env -u "$var" bash -c "$runnable")
  if [ "$got" != 1 ]; then
    echo "FAIL: hint does not pass $var to bash: $cmd (got '$got')" >&2
    fail=1
  fi
done < <(grep -F 'To bypass (not recommended):' "$INSTALLER")

if [ "$count" -lt 2 ]; then
  echo "FAIL: expected >=2 bypass hints in install.sh, found $count" >&2
  exit 1
fi
exit "$fail"
