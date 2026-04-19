#!/usr/bin/env bash
# DSL coverage backlog — "dashboard" over a slice of homebrew-core.
#
# Runs `mt install --debug` against a configurable formula list and
# aggregates every `[unknown_method]` / `[unsupported_node]` diagnostic
# into a ranked frequency table. The output is the prioritization source
# for future DSL work: whichever entry appears most often across real
# formulas is the next builtin worth adding.
#
# Unlike `scripts/regressions/dsl_corpus_coverage.sh` this script does
# NOT fail on regressions — it's an exploration tool that always exits 0
# (unless the binary itself is missing) so you can let it run against a
# large corpus and read the report.
#
# Usage:
#   scripts/tools/dsl_backlog.sh [--limit N]
#   TARGETS="a b c" scripts/tools/dsl_backlog.sh
#
# Output: a summary table to stdout plus `/tmp/mt_backlog/report.txt`
# with the full breakdown for sharing in issue reports.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

LIMIT="${LIMIT:-0}"
if [[ "${1:-}" == "--limit" ]]; then
  LIMIT="${2:-20}"
fi

# A broad default corpus — picked to hit every post_install shape
# we've seen in the wild. Keep `tree`/`jq`/`ripgrep` so silent-DSL
# firing is exposed. Override with TARGETS="…" to focus the run.
TARGETS="${TARGETS:-ca-certificates gnupg openssl@3 libidn2 tree jq ripgrep curl wget nginx sqlite}"

REPORT_DIR="/tmp/mt_backlog"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$REPORT_DIR"
mkdir -p "$REPORT_DIR"

# Aggregated counters: `reason:detail` keyed lines so `sort | uniq -c`
# produces the ranked backlog directly.
counter_file="$REPORT_DIR/entries.raw"
: >"$counter_file"

total=0
for target in $TARGETS; do
  if [[ "$LIMIT" -gt 0 && "$total" -ge "$LIMIT" ]]; then
    break
  fi
  total=$((total + 1))

  # Isolate each install under a short prefix (Mach-O patching needs
  # ≤13 bytes). Keep sequential so bottle cache reuse is possible.
  prefix="/tmp/mt_bl${total}"
  rm -rf "$prefix"
  mkdir -p "$prefix"
  export MALT_PREFIX="$prefix"

  log="$REPORT_DIR/${target//[@.\/]/_}.log"
  printf '▸ [%d/%s] %s\n' "$total" "$(printf '%s' "$TARGETS" | wc -w | tr -d ' ')" "$target"
  if ! "$BIN" install --debug "$target" >"$log" 2>&1; then
    printf '    ⚠ install exited non-zero — diagnostics still collected\n' >&2
  fi

  # Extract `[reason] detail` from every diagnostic line — the format
  # is produced by flog.printFatal / printUnknown and is stable.
  grep -oE "\[(unknown_method|unsupported_node)\] [^$(printf '\t')]+" "$log" 2>/dev/null |
    sort -u |
    sed "s|^|$target |" \
      >>"$counter_file" || true

  rm -rf "$prefix"
done

# Produce the ranked report. Each line in counter_file looks like
# `<target> [reason] detail`. Collapse to `[reason] detail` keys and
# count occurrences (= formulas hitting that diagnostic).
report="$REPORT_DIR/report.txt"
{
  printf '# DSL coverage backlog\n'
  printf '# generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '# targets:   %d\n\n' "$total"
  printf '## Ranked (formulas hitting each diagnostic)\n\n'
  awk '{ $1=""; sub(/^ /, ""); print }' "$counter_file" |
    sort | uniq -c | sort -rn
  printf '\n## Per-target raw (sorted)\n\n'
  sort "$counter_file"
} >"$report"

printf '\n── Top backlog entries ──\n'
head -20 "$report" | tail -15
printf '\n✔ full report: %s\n' "$report"
