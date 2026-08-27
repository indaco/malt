#!/usr/bin/env bash
# Regression: the tar pre-scan's inline guards must actually reach the code
# they are named for, and no fixture may squat a shared /tmp path.
#
# `preScanTarGz` short-circuits at `scan.hard_links == 0`, so any archive
# fixture without a `'1'` entry never reaches the raw 512-byte walk. Three
# tests were written to cover walk behaviour while building hard-link-free
# archives: each passed on the iterator pass alone and stayed green with the
# walk's logic removed. A fixture edit can silently reintroduce that.
#
# The second half guards the fixed `/tmp` prefixes: concurrent sessions running
# the same regression `rm -rf` each other's fixture mid-run. Every script that
# declares the Mach-O in-place patching budget is checked, so a new one inherits
# the guard instead of having to be listed here.
#
# Static guard: no build, no network, no temp state, well under a second.
# Exits 0 when both properties hold, non-zero (with a clear message) otherwise.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ARCHIVE="$ROOT/src/fs/archive.zig"
BUDGET=13 # len("/opt/homebrew")

fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# 1. every test that claims to cover the raw walk must force the walk to run.
for name in \
  'extractTarGz refuses an archive whose pax size hides an entry from the scan' \
  'extractTarGz lets an old-style file entry consume a GNU long link' \
  'extractTarGz lets a directory entry consume a GNU long name'; do
  body=$(awk -v t="test \"$name\" {" 'index($0, t) == 1 {p = 1} p; p && /^}/ {exit}' "$ARCHIVE")
  [[ -n "$body" ]] || fail "test not found, so this guard checks nothing: $name"
  grep -qE "t\\.entry\\([^)]*'1'," <<<"$body" ||
    fail "no hard link in \"$name\": preScanTarGz returns at scan.hard_links == 0,
        the raw walk never runs, and the test credits the iterator pass instead"
done

# 2. no budget-bound script may share a fixed prefix with a concurrent session.
scripts=$(grep -rl 'Mach-O in-place patching budget' "$ROOT/scripts/regressions" |
  grep -v "$(basename "$0")" || true)
[[ -n "$scripts" ]] || fail "no script declares the patching budget; the guard found nothing to check"
while IFS= read -r s; do
  pfx=$(grep -E '^(PREFIX|PREFIX_ROOT)=' "$s" | head -1 | cut -d= -f2- | tr -d '"')
  [[ -n "$pfx" ]] || fail "$(basename "$s") declares the budget but sets no prefix"
  # mktemp is the repo's idiom: unguessable, created 0700, and short enough
  # here because the template pins the path to /tmp.
  tmpl=$(sed -nE 's/^\$\(mktemp -d ([^ )]+)\)$/\1/p' <<<"$pfx")
  [[ -n "$tmpl" ]] ||
    fail "$(basename "$s"): prefix $pfx is not from mktemp, so concurrent sessions collide"
  ((${#tmpl} <= BUDGET)) ||
    fail "$(basename "$s"): template $tmpl is ${#tmpl} bytes, over the ${BUDGET}-byte Mach-O budget"
done <<<"$scripts"

# 3. and no regression may pin ANY fixture path to a fixed /tmp literal - a
# unique prefix is no use while the cache or scratch dir beside it still
# collides.
fixed=$(grep -rnE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=("|'"'"')?/tmp/[^"'"'"'$]*("|'"'"')?[[:space:]]*(#.*)?$' \
  "$ROOT/scripts/regressions" | grep -v mktemp || true)
[[ -z "$fixed" ]] ||
  fail "fixed fixture paths, which concurrent sessions rm -rf out from under each other:
${fixed//$'\n'/$'\n'        }"

# 4. a fixture root is only reclaimable if `just clean` sweeps its namespace,
# and the corpus logs only survive CI if the artifact glob matches the root.
mapfile -t swept < <(grep -oE "'/tmp/[^']+'" "$ROOT/scripts/clean.sh" | tr -d "'")
((${#swept[@]} > 0)) || fail "no /tmp patterns found in clean.sh; this check is inert"
while IFS= read -r tmpl; do
  [[ -n "$tmpl" ]] || continue
  sample=${tmpl//X/a}
  hit=""
  for pat in "${swept[@]}"; do
    # shellcheck disable=SC2053 # glob match against clean.sh's own pattern
    [[ "$sample" == $pat ]] && {
      hit=1
      break
    }
  done
  [[ -n "$hit" ]] ||
    fail "template $tmpl is outside the namespaces scripts/clean.sh sweeps, so a
        killed run leaks it with no way to reclaim it"
done < <(grep -rhoE 'mktemp -d /tmp/[A-Za-z._-]+X+' "$ROOT/scripts/regressions" |
  sed -E 's|^mktemp -d ||' | sort -u)

corpus_root=$(sed -nE 's/^PREFIX_ROOT=\$\(mktemp -d ([^ )]+)\)$/\1/p' \
  "$ROOT/scripts/regressions/dsl_corpus_coverage.sh")
glob=$(sed -nE 's|^[[:space:]]*path: (/tmp/.*)$|\1|p' "$ROOT/.github/workflows/dsl-corpus.yml" | head -1)
[[ -n "$corpus_root" && -n "$glob" ]] ||
  fail "cannot read the corpus root or its artifact glob; this check is inert"
# shellcheck disable=SC2053 # glob match against the workflow's own pattern
[[ "${corpus_root//X/a}/logs" == $glob ]] ||
  fail "corpus logs land in ${corpus_root}/logs but CI uploads $glob, so a failed
        run silently discards the only diagnostics it produces"

printf '  ✓ tar pre-scan follow-up guards hold\n'
