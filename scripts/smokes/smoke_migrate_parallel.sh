#!/usr/bin/env bash
# Pre-release smoke test for `malt migrate --parallel`.
#
# Uses the developer's real Homebrew installation as the migration
# source and an isolated MALT_PREFIX as the destination, so the run
# never touches the real malt install on this machine. Captures stdout
# (final --json summary) and stderr (per-keg diagnostics) and writes a
# human report listing each successful migration, each failure with
# the relevant log lines, a `--help` usability check on every migrated
# CLI, and a second `--output-format=ndjson` pass that asserts workers
# actually fanned out (events from distinct kegs interleave).
#
# Working dirs live under /tmp/mt_mp / /tmp/mt_mp2 / /tmp/mt-mp-work so
# `just clean` (clean.sh /tmp/mt_* + /tmp/mt-* globs) reaps them.
#
# Usage:
#   scripts/smokes/smoke_migrate_parallel.sh
#   MALT_BIN=zig-out/bin/malt scripts/smokes/smoke_migrate_parallel.sh
#   MIGRATE_KEGS="hello jq tree" scripts/smokes/smoke_migrate_parallel.sh
#   MALT_MIGRATE_PARALLEL_WORKERS=8 scripts/smokes/smoke_migrate_parallel.sh
#   SKIP_NDJSON_PASS=1 scripts/smokes/smoke_migrate_parallel.sh
#
# Requires: built malt binary, jq, network access to formulae.brew.sh
# and ghcr.io. Not for CI - touches the user's brew Cellar (read-only)
# and downloads bottles for every keg in scope.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# Always invoke `zig build` so a smoke run after a code edit picks up
# the latest binary - the previous "skip if exists" gate left stale
# binaries in place across iterations. zig's incremental cache keeps
# the no-op cost <1s when nothing changed.
if [[ -z "${MALT_BIN:-}" ]]; then
  echo "▸ zig build (auto)" >&2
  if ! (cd "$ROOT" && zig build) >&2; then
    echo "zig build failed - aborting smoke" >&2
    exit 2
  fi
fi
if [[ ! -x "$BIN" ]]; then
  echo "build did not produce $BIN" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || {
  echo "jq is required to parse --json output" >&2
  exit 2
}

# MALT_PREFIX must be <= 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_mp"
PREFIX_NDJSON="/tmp/mt_mp2"
WORKDIR="/tmp/mt-mp-work"
REPORT="$WORKDIR/migrate_parallel_report.txt"
STDOUT_LOG="$WORKDIR/migrate.stdout.json"
# `migrate --json` emits a JSONL stream: one line per per-keg
# `post_install` event followed by the final summary blob. Naive
# `jq -r '...' file` over a multi-doc stream runs the expression
# once per document. We extract the final summary into a separate
# file up-front so every downstream consumer sees one document.
SUMMARY_JSON="$WORKDIR/migrate.summary.json"
STDERR_LOG="$WORKDIR/migrate.stderr.log"
NDJSON_LOG="$WORKDIR/migrate.ndjson"
NDJSON_STDERR="$WORKDIR/migrate.ndjson.stderr.log"

rm -rf "$PREFIX" "$PREFIX_NDJSON" "$WORKDIR"
mkdir -p "$PREFIX" "$PREFIX_NDJSON" "$WORKDIR"

export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1

# Bound any single binary invocation. macOS lacks `timeout` by default;
# perl is on every system. `alarm 0` is a no-op so the wrapper is safe
# for shells without alarm support.
run_with_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# Source-of-truth Cellar. Default = the developer's real brew install
# (malt auto-detects). With MIGRATE_KEGS=..., we build a scratch Cellar
# of empty named directories: malt resolves every keg via the brew API
# on name alone and never reads inside the Cellar dir, so empty dirs
# drive a real migration without needing those kegs locally. Symlinks
# would NOT work - malt's scanner skips entries whose kind != .directory.
SOURCE_CELLAR=""
if [[ -n "${MIGRATE_KEGS:-}" ]]; then
  read -r -a SUBSET <<<"$MIGRATE_KEGS"
  SCRATCH_BREW="$WORKDIR/brew"
  mkdir -p "$SCRATCH_BREW/Cellar"
  for k in "${SUBSET[@]}"; do
    mkdir -p "$SCRATCH_BREW/Cellar/$k"
  done
  export HOMEBREW_PREFIX="$SCRATCH_BREW"
  SOURCE_CELLAR="$SCRATCH_BREW/Cellar (subset: ${SUBSET[*]})"
else
  if command -v brew >/dev/null 2>&1; then
    SOURCE_CELLAR="$(brew --prefix)/Cellar"
  else
    SOURCE_CELLAR="(malt auto-detect)"
  fi
fi

printf '▸ migrate --parallel smoke\n'
printf '  source:        %s\n' "$SOURCE_CELLAR"
printf '  destination:   %s\n' "$PREFIX"
printf '  workdir:       %s\n' "$WORKDIR"
printf '  workers (env): %s\n' "${MALT_MIGRATE_PARALLEL_WORKERS:-default}"
printf '\n'

# ── Main pass: --parallel --json ─────────────────────────────────────
EXIT=0
"$BIN" migrate --parallel --json >"$STDOUT_LOG" 2>"$STDERR_LOG" || EXIT=$?

# Reduce the JSONL stream to its terminal summary doc. Migrate emits a
# per-keg post_install event line (intentional protocol-stream channel)
# plus a final summary blob; downstream queries want the latter only.
# Fall back to the raw file when slurp fails so error reporting can
# still surface raw diagnostics.
if ! jq -s '.[-1]' "$STDOUT_LOG" >"$SUMMARY_JSON" 2>/dev/null; then
  cp "$STDOUT_LOG" "$SUMMARY_JSON"
fi

# ── Binary usability check ───────────────────────────────────────────
# For each migrated keg, find a candidate executable and try `--help`.
# Pass = exit 0 OR non-empty output (some CLIs print usage and exit !=0).
# Result file format: TSV `<status>\t<name>\t<bin>\t<flag>\t<detail>`.
USABILITY_TSV="$WORKDIR/usability.tsv"
: >"$USABILITY_TSV"

usability_check() {
  local migrated_names_file="$1"
  local name bin_dir candidate cellar_ver
  local -a candidates
  local flag rc out tried

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    candidates=()

    # 1. Linked symlink (the canonical path).
    if [[ -x "$PREFIX/bin/$name" ]]; then
      candidates+=("$PREFIX/bin/$name")
    fi

    # 2. Anything shipped under Cellar/<name>/<ver>/bin/. Picks up
    #    keg-only formulae and binaries whose name diverges from the
    #    keg name (e.g. coreutils gln/gls, pkg-config aliases).
    if [[ -d "$PREFIX/Cellar/$name" ]]; then
      cellar_ver=$(find "$PREFIX/Cellar/$name" -mindepth 1 -maxdepth 1 -type d |
        head -n 1)
      if [[ -n "$cellar_ver" ]]; then
        bin_dir="$cellar_ver/bin"
        if [[ -d "$bin_dir" ]]; then
          while IFS= read -r candidate; do
            candidates+=("$candidate")
          done < <(find "$bin_dir" -maxdepth 1 -type f -perm -u+x 2>/dev/null)
        fi
      fi
    fi

    if [[ "${#candidates[@]}" -eq 0 ]]; then
      printf 'NO_BINARY\t%s\t-\t-\tno bin/ directory under Cellar/%s\n' \
        "$name" "$name" >>"$USABILITY_TSV"
      continue
    fi

    tried=""
    for candidate in "${candidates[@]}"; do
      for flag in --help -h --version -V; do
        rc=0
        # </dev/null on the inner subshell: the outer `while ... done <file`
        # loop redirects FD 0 to the migrated-names file, and any binary
        # we exec inherits that FD. Some `--help` invocations briefly
        # read from stdin (banner-on-tty checks, terminal-size probes)
        # and consume lines from the names file - which silently truncates
        # the loop. Cutting stdin keeps the loop in charge of its own input.
        out=$(run_with_timeout 5 "$candidate" "$flag" </dev/null 2>&1) || rc=$?
        tried="$tried $candidate $flag (rc=$rc)"
        if [[ "$rc" -eq 0 ]] || [[ -n "$out" ]]; then
          printf 'USABLE\t%s\t%s\t%s\trc=%d, %d bytes output\n' \
            "$name" "$candidate" "$flag" "$rc" "${#out}" >>"$USABILITY_TSV"
          continue 3
        fi
      done
    done

    printf 'BIN_BROKEN\t%s\t%s\t-\tno --help/--version produced output;%s\n' \
      "$name" "${candidates[0]}" "$tried" >>"$USABILITY_TSV"
  done <"$migrated_names_file"
}

# ── NDJSON interleaving pass (concurrency assertion) ─────────────────
# Run a small subset migration through a fresh prefix with
# --output-format=ndjson and verify events from distinct kegs
# interleave. If they don't, the worker pool effectively ran
# sequentially and the --parallel path silently regressed.
NDJSON_RESULT="(skipped)"
NDJSON_DETAIL=""
ndjson_pass() {
  local probe_brew
  local -a picked

  if [[ "${SKIP_NDJSON_PASS:-0}" == "1" ]]; then
    NDJSON_RESULT="skipped (SKIP_NDJSON_PASS=1)"
    return
  fi

  # Fixed set of small, well-known formulae with bottles on every
  # supported arch. malt resolves each via the brew API on name only,
  # so empty named directories drive a real migration without needing
  # the host to have those kegs locally.
  picked=(jq tree hello xz)

  probe_brew="$WORKDIR/ndjson-brew"
  rm -rf "$probe_brew"
  mkdir -p "$probe_brew/Cellar"
  for c in "${picked[@]}"; do
    mkdir -p "$probe_brew/Cellar/$c"
  done

  local rc=0
  HOMEBREW_PREFIX="$probe_brew" MALT_PREFIX="$PREFIX_NDJSON" \
    "$BIN" migrate --parallel --output-format=ndjson \
    >"$NDJSON_LOG" 2>"$NDJSON_STDERR" || rc=$?

  # Collect the stable order in which event lines hit stdout. With one
  # worker, all events for keg A precede any event for keg B. With >=2
  # workers, A's last event lands after B's first - that's our signal.
  local interleave_check
  interleave_check=$(jq -r --slurp '
    [ .[]
      | select(.name != null and .name != "")
      | .name
    ] as $names
    | ($names | unique) as $unique
    | reduce $unique[] as $n (
        {names: $names, found: false};
        . as $st
        | ($st.names | length) as $L
        | (first(range($L) | select($st.names[.] == $n))) as $first
        | (last(range($L) | select($st.names[.] == $n))) as $last
        | if ($first == null or $last == null) then $st
          else
            $st + {found:
              ($st.found
               or any($st.names[($first+1):$last]; . != null and . != $n))
            }
          end
      )
    | .found
  ' "$NDJSON_LOG" 2>/dev/null || echo "false")

  local kegs_seen events_total
  kegs_seen=$(jq -r --slurp '
    [.[] | select(.name != null and .name != "") | .name] | unique | length
  ' "$NDJSON_LOG" 2>/dev/null || echo "0")
  events_total=$(wc -l <"$NDJSON_LOG" | tr -d ' ')

  if [[ "$rc" -ne 0 ]]; then
    NDJSON_RESULT="FAILED (exit $rc)"
    NDJSON_DETAIL="ndjson pass exited $rc; see $NDJSON_STDERR"
    return
  fi

  if [[ "$interleave_check" == "true" ]]; then
    NDJSON_RESULT="OK (interleaved)"
    NDJSON_DETAIL="kegs=${picked[*]} unique=$kegs_seen events=$events_total"
  else
    NDJSON_RESULT="WARN (no interleave detected)"
    NDJSON_DETAIL="kegs=${picked[*]} unique=$kegs_seen events=$events_total - workers may have run sequentially"
  fi
}

# ── Build the report ─────────────────────────────────────────────────
build_report() {
  printf '═══════════════════════════════════════════════════════════════\n'
  printf '  malt migrate --parallel - pre-release smoke report\n'
  printf '  generated: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  printf '  binary:    %s\n' "$BIN"
  printf '  source:    %s\n' "$SOURCE_CELLAR"
  printf '  prefix:    %s\n' "$PREFIX"
  printf '  exit:      %d\n' "$EXIT"
  printf '═══════════════════════════════════════════════════════════════\n\n'

  if ! jq . "$SUMMARY_JSON" >/dev/null 2>&1; then
    printf '⚠ malt did not produce parseable JSON. Raw stdout:\n'
    sed 's/^/  /' "$STDOUT_LOG"
    printf '\nstderr (last 60 lines):\n'
    tail -60 "$STDERR_LOG" | sed 's/^/  /'
    return
  fi

  # An empty source Cellar makes malt emit the dry-run shape (no
  # `.counts`); coalesce every count to 0 so the report stays readable.
  printf '── Summary ────────────────────────────────────────────────\n'
  jq -r '
    (.counts // {}) as $c
    | "  migrated:               \($c.migrated // 0)\n" +
      "  skipped (installed):    \($c.skipped_installed // 0)\n" +
      "  skipped (post_install): \($c.skipped_post_install // 0)\n" +
      "  skipped (no_bottle):    \($c.skipped_no_bottle // 0)\n" +
      "  failed:                 \($c.failed // 0)\n" +
      "  time_ms:                \(.time_ms // 0)"
  ' "$SUMMARY_JSON"
  printf '\n'

  printf '── Successful migrations ──────────────────────────────────\n'
  if [[ "$(jq -r '(.migrated // []) | length' "$SUMMARY_JSON")" -eq 0 ]]; then
    printf '  (none)\n'
  else
    jq -r '.migrated[] | "  ✓ " + .' "$SUMMARY_JSON"
  fi
  printf '\n'

  printf '── Skipped (post_install / no_bottle) ─────────────────────\n'
  local skipped
  skipped=$(jq -r '((.skipped_post_install // []) + (.skipped_no_bottle // [])) | .[]' "$SUMMARY_JSON")
  if [[ -z "$skipped" ]]; then
    printf '  (none)\n'
  else
    while IFS= read -r name; do
      printf '  - %s\n' "$name"
    done <<<"$skipped"
  fi
  printf '\n'

  printf '── Failures ───────────────────────────────────────────────\n'
  local failures
  failures=$(jq -r '(.failed // []) | .[]' "$SUMMARY_JSON")
  if [[ -z "$failures" ]]; then
    printf '  (none)\n'
  else
    while IFS= read -r name; do
      printf '  ✗ %s\n' "$name"
      # Word-ish boundary keeps `gettext` from dragging in `gettext-foo`.
      local hits
      hits=$(grep -E "(^|[^[:alnum:]_-])${name}([^[:alnum:]_-]|$)" "$STDERR_LOG" || true)
      if [[ -z "$hits" ]]; then
        printf '      (no diagnostic lines found in stderr)\n'
      else
        printf '%s\n' "$hits" | sed 's/^/      /'
      fi
      printf '\n'
    done <<<"$failures"
  fi

  printf '── Binary usability (--help / --version) ──────────────────\n'
  if [[ ! -s "$USABILITY_TSV" ]]; then
    printf '  (no migrated kegs to probe)\n'
  else
    local usable broken nobinary
    usable=$(grep -c '^USABLE' "$USABILITY_TSV" || true)
    broken=$(grep -c '^BIN_BROKEN' "$USABILITY_TSV" || true)
    nobinary=$(grep -c '^NO_BINARY' "$USABILITY_TSV" || true)
    printf '  usable: %s   no-binary (libs/headers): %s   broken: %s\n\n' \
      "$usable" "$nobinary" "$broken"

    awk -F'\t' '$1=="USABLE"   {printf "  ✓ %-30s %s %s\n", $2, $4, $3}' \
      "$USABILITY_TSV"
    awk -F'\t' '$1=="NO_BINARY"{printf "  - %-30s %s\n",     $2, $5}' \
      "$USABILITY_TSV"
    if [[ "$broken" -gt 0 ]]; then
      printf '\n'
      awk -F'\t' '$1=="BIN_BROKEN"{printf "  ✗ %-30s %s\n  attempts:%s\n", $2, $3, $5}' \
        "$USABILITY_TSV"
    fi
  fi
  printf '\n'

  printf '── Cross-check: mt list ───────────────────────────────────\n'
  local list_json missing
  list_json="$WORKDIR/list.json"
  if "$BIN" list --json >"$list_json" 2>/dev/null && jq . "$list_json" >/dev/null 2>&1; then
    missing=$(jq -r --slurpfile s "$SUMMARY_JSON" '
      ($s[0].migrated // []) as $want
      | (.formulae // [] | map(.name)) as $have
      | $want - $have | .[]
    ' "$list_json")
    if [[ -z "$missing" ]]; then
      printf '  every migrated keg appears in mt list ✓\n'
    else
      printf '  ⚠ migrated kegs missing from mt list:\n'
      printf '%s\n' "$missing" | sed 's/^/      - /'
    fi
  else
    printf '  ⚠ mt list --json did not produce parseable output\n'
  fi
  printf '\n'

  printf '── Concurrency (ndjson interleaving pass) ─────────────────\n'
  printf '  result: %s\n' "$NDJSON_RESULT"
  if [[ -n "$NDJSON_DETAIL" ]]; then
    printf '  detail: %s\n' "$NDJSON_DETAIL"
  fi
  printf '\n'

  printf '── Raw artifacts ──────────────────────────────────────────\n'
  printf '  json   : %s\n' "$STDOUT_LOG"
  printf '  summary: %s\n' "$SUMMARY_JSON"
  printf '  stderr : %s\n' "$STDERR_LOG"
  printf '  ndjson : %s\n' "$NDJSON_LOG"
  printf '  uses   : %s\n' "$USABILITY_TSV"
  printf '\n'
  printf 'Run "just clean" after review to wipe %s, %s, and %s.\n' \
    "$PREFIX" "$PREFIX_NDJSON" "$WORKDIR"
}

# Build the migrated-name list so the usability check has something to
# iterate, then run the ndjson pass before composing the report.
MIGRATED_NAMES_FILE="$WORKDIR/migrated.txt"
if jq . "$SUMMARY_JSON" >/dev/null 2>&1; then
  jq -r '.migrated[]?' "$SUMMARY_JSON" >"$MIGRATED_NAMES_FILE"
else
  : >"$MIGRATED_NAMES_FILE"
fi

usability_check "$MIGRATED_NAMES_FILE"
ndjson_pass

build_report >"$REPORT"
cat "$REPORT"

# ── Decide pass/fail ─────────────────────────────────────────────────
if ! jq . "$SUMMARY_JSON" >/dev/null 2>&1; then
  printf '\n✗ migrate did not emit parseable JSON (exit %d) - see %s\n' \
    "$EXIT" "$REPORT" >&2
  exit 1
fi

# `// 0` so an empty-Cellar JSON (no `.counts`) decodes as zeros instead
# of "null" strings, which would trip set -u inside arithmetic `[[ ]]`.
FAILED=$(jq -r '.counts.failed // 0' "$SUMMARY_JSON")
MIGRATED=$(jq -r '.counts.migrated // 0' "$SUMMARY_JSON")
SKIPPED_INSTALLED=$(jq -r '.counts.skipped_installed // 0' "$SUMMARY_JSON")
SKIPPED_POST=$(jq -r '.counts.skipped_post_install // 0' "$SUMMARY_JSON")
SKIPPED_NB=$(jq -r '.counts.skipped_no_bottle // 0' "$SUMMARY_JSON")
TOTAL=$((MIGRATED + SKIPPED_INSTALLED + SKIPPED_POST + SKIPPED_NB + FAILED))
# grep -c writes "0" to stdout on no-match AND exits 1, so `|| echo 0` would
# concatenate to "0\n0" and trip `[[ -gt 0 ]]`. Swallow the exit only and
# default to 0 when the file is missing entirely (no stdout at all).
BROKEN=$(grep -c '^BIN_BROKEN' "$USABILITY_TSV" 2>/dev/null || true)
BROKEN=${BROKEN:-0}

if [[ "$EXIT" -ne 0 ]]; then
  printf '\n✗ malt migrate --parallel exited %d - see %s\n' "$EXIT" "$REPORT" >&2
  exit "$EXIT"
fi

if [[ "$TOTAL" -eq 0 ]]; then
  printf '\n✗ no kegs in scope - empty Cellar at source\n' >&2
  exit 1
fi

if [[ "$FAILED" -gt 0 ]]; then
  printf '\n✗ %s keg(s) failed - see %s\n' "$FAILED" "$REPORT" >&2
  exit 1
fi

if [[ "$MIGRATED" -eq 0 ]]; then
  printf '\n✗ no migrations completed - every keg was skipped\n' >&2
  exit 1
fi

if [[ "$BROKEN" -gt 0 ]]; then
  printf '\n✗ %s migrated keg(s) failed the --help usability check - see %s\n' \
    "$BROKEN" "$REPORT" >&2
  exit 1
fi

printf '\n✔ migrate --parallel smoke passed (%s migrated, %s skipped; concurrency: %s)\n' \
  "$MIGRATED" "$((SKIPPED_INSTALLED + SKIPPED_POST + SKIPPED_NB))" "$NDJSON_RESULT"
