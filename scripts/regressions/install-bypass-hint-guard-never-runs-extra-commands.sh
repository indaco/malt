#!/usr/bin/env bash
# Regression: the bypass-hint guard must refuse a hint that is not one
# `curl ... | VAR=1 bash` pipeline, and it must never run a hint. Each case
# writes a scratch installer that is valid except for one hint. A bad hint
# creates a marker file when run; the guard must fail and leave it absent.
# Two good hints, one with a ${REPO} URL, prove the scratch installer is valid.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GUARD="$ROOT/scripts/regressions/install-bypass-hint-env-reaches-bash-gh1251.sh"
WORK=$(mktemp -d "/tmp/mt_hintguard_$$.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
MARKER="$WORK/ran"
URL=https://example.invalid/install.sh
VAR=MALT_ALLOW_UNVERIFIED
OTHER=MALT_ALLOW_UNVERIFIED_SOURCE

# Write a scratch installer with `$1` as the pipe hint for $VAR. `$2` is the
# local-copy line for $VAR: empty means the good line, "none" omits it.
write_installer() {
  local local_line=${2:-"Or, from a downloaded copy: $VAR=1 bash /path/to/install.sh\""}
  # shellcheck disable=SC2016 # ${var:-0} is scratch installer text, not shell
  {
    printf '  x ${%s:-0}\n  x ${%s:-0}\n' "$VAR" "$OTHER"
    printf '  To bypass (not recommended): %s\n' "$1"
    [ "$local_line" = none ] || printf '  %s\n' "$local_line"
    printf '  To bypass (not recommended): curl -fsSL %s | %s=1 bash\n' "$URL" "$OTHER"
    printf '  Or, from a downloaded copy: %s=1 bash /path/to/install.sh"\n' "$OTHER"
  } >"$WORK/install.sh"
}

fail=0
run_guard() {
  local rc=0
  rm -f "$MARKER"
  INSTALL_SH="$WORK/install.sh" bash "$GUARD" >/dev/null 2>&1 || rc=$?
  return "$rc"
}

refuse() {
  local name=$1 hint=$2 local_line=${3:-} rc=0
  write_installer "$hint" "$local_line"
  run_guard || rc=$?
  if [ "$rc" = 0 ]; then
    echo "FAIL: guard accepted: $name" >&2
    fail=1
  fi
  if [ -e "$MARKER" ]; then
    echo "FAIL: guard ran the hint: $name" >&2
    fail=1
  fi
}

accept() {
  local name=$1 hint=$2 rc=0
  write_installer "$hint"
  run_guard || rc=$?
  if [ "$rc" != 0 ]; then
    echo "FAIL: guard refused a good hint: $name" >&2
    fail=1
  fi
}

# shellcheck disable=SC2016 # ${REPO} and $( are scratch installer text
{
  accept "plain URL" "curl -fsSL $URL | $VAR=1 bash"
  accept "no spaces around the pipe" "curl -fsSL $URL|$VAR=1 bash"
  accept "REPO URL" 'curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | '"$VAR=1 bash"
  good="curl -fsSL $URL | $VAR=1 bash"
  refuse "local line missing" "$good" none
  refuse "local line names the other variable" "$good" \
    "Or, from a downloaded copy: $OTHER=1 bash /path/to/install.sh\""
  refuse "local line uses a relative path" "$good" \
    "Or, from a downloaded copy: $VAR=1 bash install.sh\""
  refuse "variable before curl" "$VAR=1 curl -fsSL $URL | bash"
  refuse "leading command" "touch $MARKER; curl -fsSL $URL | $VAR=1 bash"
  refuse "BASH_ENV before the variable" "curl -fsSL $URL | BASH_ENV=$WORK/env $VAR=1 bash"
  refuse "bash -c" "curl -fsSL $URL | $VAR=1 bash -c 'touch $MARKER'"
  refuse "bash file" "curl -fsSL $URL | $VAR=1 bash $WORK/payload"
  refuse "tee" "curl -fsSL $URL | tee $MARKER | $VAR=1 bash"
  refuse "process substitution" "curl -fsSL $URL | $VAR=1 bash <(touch $MARKER)"
  refuse "command substitution" "curl -fsSL \$(touch $MARKER) | $VAR=1 bash"
  refuse "no curl pipeline" "$VAR=1 bash <(touch $MARKER; curl -fsSL $URL)"
}
exit "$fail"
