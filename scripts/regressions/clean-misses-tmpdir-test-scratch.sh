#!/usr/bin/env bash
# Regression: `just clean` must sweep test scratch under $TMPDIR, not only /tmp.
#
# The bug: `mktemp -d -t <prefix>` resolves against $TMPDIR, which on macOS is
# a per-user dir under /var/folders. Around fifty shell-suite call sites use
# that form, so their scratch trees never landed in /tmp - and clean.sh globbed
# /tmp alone. Every crashed or killed run leaked its prefix, Cellar and cache
# there permanently, invisible to the one command meant to reclaim them.
#
# Static only, on purpose: clean.sh deletes /tmp scratch by design, so actually
# running it here would wipe the fixtures of any suite running alongside it.
# The behavioural proof belongs in a manual run, not in a shared CI worker.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLEAN="$ROOT/scripts/clean.sh"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# The sweep must derive a second root from $TMPDIR and loop over both. All
# three parts are pinned: dropping any one narrows the sweep back to /tmp
# without changing a single visible behaviour.
# The literal `$` is the point here - these match clean.sh's source, not values.
# shellcheck disable=SC2016
required=(
  'scratch_tmpdir=${TMPDIR:-}'
  'roots="$roots $scratch_tmpdir"'
  'for root in $roots; do'
)
for literal in "${required[@]}"; do
  grep -Fq -- "$literal" "$CLEAN" ||
    fail "clean.sh no longer sweeps \$TMPDIR - missing: $literal"
done

# Every prefix the suite mints must stay in the pattern list; a missing variant
# leaks a multi-GB Cellar or cache tree on each crashed run.
for pattern in 'malt_\*' 'malt-\*' 'mt_\*' 'mt-\*' 'mt\.\*' 'ml_\*' 'ml\.\*' \
  'mc_\*' 'mc\.\*' 'probe-budget\.\*'; do
  grep -qE "^patterns=.*${pattern}" "$CLEAN" ||
    fail "clean.sh dropped the '${pattern}' scratch prefix"
done

echo "PASS: clean sweeps test scratch under both /tmp and \$TMPDIR"
