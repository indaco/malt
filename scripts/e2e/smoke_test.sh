#!/usr/bin/env bash
# scripts/e2e/smoke_test.sh
#
# Comprehensive CLI smoke test for malt. Exercises every command and subcommand
# documented in README.md under an isolated MALT_PREFIX / MALT_CACHE, so the
# user's real /opt/malt is never touched.
#
# Tiers:
#   1. offline-only (help, version, completions, --help for every command)
#   2. api-only    (update, search, info, outdated, doctor, list on empty)
#   3. network     (install, uses, link/unlink, backup/restore, rollback,
#                   uninstall, purge, bundle, tap/untap)
#
# Each test prints a PASS/FAIL line with the exact command string; a final
# summary is emitted. Exit code 0 iff every test passes.
#
# Usage:
#   ./scripts/e2e/smoke_test.sh                      # full run
#   SMOKE_SKIP_NETWORK=1 ./scripts/e2e/smoke_test.sh # tiers 1+2 only
#   MT_BIN=./zig-out/bin/mt ./scripts/e2e/smoke_test.sh

set -uo pipefail

MT_BIN="${MT_BIN:-./zig-out/bin/malt}"
SKIP_NETWORK="${SMOKE_SKIP_NETWORK:-0}"

if [[ ! -x "$MT_BIN" ]]; then
  echo "smoke: $MT_BIN not found or not executable" >&2
  echo "smoke: run 'zig build' first (or set MT_BIN)" >&2
  exit 2
fi
MT_BIN="$(cd "$(dirname "$MT_BIN")" && pwd)/$(basename "$MT_BIN")"

PREFIX=$(mktemp -d /tmp/mt.XXX)
CACHE=$(mktemp -d /tmp/mc.XXX)
LOGDIR=$(mktemp -d /tmp/ml.XXX)
trap 'rm -rf "$PREFIX" "$CACHE" "$LOGDIR"' EXIT

export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$CACHE"
# Deterministic, machine-parseable output.
export NO_COLOR=1
export MALT_NO_EMOJI=1

PASS=0
FAIL=0
FAILURES=()

# ── Helpers ────────────────────────────────────────────────────────────────

# run <tag> <expected-exit> -- <cmd...>
#   Runs the command; passes if exit matches expected.
run() {
  local tag="$1" expected="$2"
  shift 2
  [[ "$1" == "--" ]] && shift
  local log
  log="$LOGDIR/$(printf '%s' "$tag" | tr -c 'A-Za-z0-9' _).log"
  "$@" >"$log" 2>&1
  local rc=$?
  if [[ "$rc" == "$expected" ]]; then
    printf '  PASS  [%s] %s\n' "$tag" "$*"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  [%s] expected exit=%s got=%s :: %s\n' "$tag" "$expected" "$rc" "$*"
    printf '        log: %s\n' "$log"
    sed -n '1,6p' "$log" | sed 's/^/        | /'
    FAIL=$((FAIL + 1))
    FAILURES+=("$tag")
  fi
}

# run_ok <tag> -- <cmd...>   (expects exit 0)
run_ok() {
  local t="$1"
  shift
  run "$t" 0 "$@"
}

# run_grep <tag> <regex> -- <cmd...>
#   Runs, expects exit 0 AND stdout/stderr match regex.
run_grep() {
  local tag="$1" pat="$2"
  shift 2
  [[ "$1" == "--" ]] && shift
  local log
  log="$LOGDIR/$(printf '%s' "$tag" | tr -c 'A-Za-z0-9' _).log"
  "$@" >"$log" 2>&1
  local rc=$?
  if [[ "$rc" == 0 ]] && grep -qE "$pat" "$log"; then
    printf '  PASS  [%s] %s\n' "$tag" "$*"
    PASS=$((PASS + 1))
  else
    printf '  FAIL  [%s] rc=%s, pattern /%s/ missing :: %s\n' "$tag" "$rc" "$pat" "$*"
    printf '        log: %s\n' "$log"
    sed -n '1,6p' "$log" | sed 's/^/        | /'
    FAIL=$((FAIL + 1))
    FAILURES+=("$tag")
  fi
}

section() { printf '\n── %s ───────────────────────────────────────\n' "$1"; }

# ── Tier 1: offline, no state ──────────────────────────────────────────────

section "Tier 1 — offline, no network, no state"

run_ok t1.version -- "$MT_BIN" version
run_ok t1.help.top -- "$MT_BIN" --help
run_ok t1.help.short -- "$MT_BIN" -h
run_ok t1.help.cmd -- "$MT_BIN" help
run_ok t1.completions.bash -- "$MT_BIN" completions bash
run_ok t1.completions.zsh -- "$MT_BIN" completions zsh
run_ok t1.completions.fish -- "$MT_BIN" completions fish

# Unknown shell should error non-zero (README: "exit non-zero with an error").
"$MT_BIN" completions tcsh >/dev/null 2>&1
rc=$?
if [[ "$rc" != 0 ]]; then
  printf '  PASS  [t1.completions.bad] exit=%s (non-zero)\n' "$rc"
  PASS=$((PASS + 1))
else
  printf '  FAIL  [t1.completions.bad] expected non-zero, got %s\n' "$rc"
  FAIL=$((FAIL + 1))
  FAILURES+=("t1.completions.bad")
fi

# Per-command --help on everything documented.
for cmd in install uninstall upgrade update outdated list info search uses \
  doctor purge tap untap migrate backup restore services bundle \
  rollback run link unlink version completions; do
  run_ok "t1.help.$cmd" -- "$MT_BIN" "$cmd" --help
done

# Alias dispatch (`mt` and `malt` both installed in zig-out/bin).
run_ok t1.alias.mt -- "$(dirname "$MT_BIN")/mt" version

# `purge` with no scope must error per README.
run t1.purge.no-scope 1 -- "$MT_BIN" purge

# Unknown command should trigger brew fallback OR clean error (documented).
run t1.unknown 1 -- "$MT_BIN" this-is-not-a-command

# ── Tier 2: hits Homebrew API, no install ──────────────────────────────────

section "Tier 2 — API-only (read commands, empty sandbox)"

run_ok t2.list.empty -- "$MT_BIN" list
run_ok t2.list.versions -- "$MT_BIN" list --versions
run_ok t2.list.json -- "$MT_BIN" list --json
run_grep t2.search.jq "jq" -- "$MT_BIN" search jq
run_ok t2.search.json -- "$MT_BIN" search jq --json
run_grep t2.info.jq "jq" -- "$MT_BIN" info jq
run_ok t2.info.json -- "$MT_BIN" info jq --json
run_ok t2.outdated -- "$MT_BIN" outdated
run_ok t2.outdated.json -- "$MT_BIN" outdated --json
run_ok t2.update -- "$MT_BIN" update
# --check must not touch the binary; guards the self-update path as it
# grows cosign verification.
run_ok t2.version.update.check -- "$MT_BIN" version update --check
run_ok t2.tap.list -- "$MT_BIN" tap

# doctor: README documents exit 0/1/2 as valid semantics — accept all three on a
# fresh sandbox (2 = "errors found" is the correct signal when the DB is absent).
"$MT_BIN" doctor >"$LOGDIR/t2.doctor.log" 2>&1
rc=$?
if [[ "$rc" == 0 || "$rc" == 1 || "$rc" == 2 ]]; then
  printf '  PASS  [t2.doctor] exit=%s (0/1/2 documented)\n' "$rc"
  PASS=$((PASS + 1))
else
  printf '  FAIL  [t2.doctor] unexpected exit=%s\n' "$rc"
  FAIL=$((FAIL + 1))
  FAILURES+=("t2.doctor")
fi

# Dry-run upgrade on empty prefix should succeed with nothing to do.
run_ok t2.upgrade.dry -- "$MT_BIN" upgrade --dry-run

# ── Tier 3: network installs (small, fast package: tree — 0 deps) ──────────

if [[ "$SKIP_NETWORK" == "1" ]]; then
  section "Tier 3 — SKIPPED (SMOKE_SKIP_NETWORK=1)"
else
  section "Tier 3 — network installs (sandboxed)"

  run_ok t3.install.dry -- "$MT_BIN" install --dry-run tree
  run_ok t3.install.tree -- "$MT_BIN" install tree
  run_grep t3.list.has-tree "tree" -- "$MT_BIN" list
  run_grep t3.info.tree "tree" -- "$MT_BIN" info tree
  run_ok t3.uses.tree -- "$MT_BIN" uses tree
  run_ok t3.uses.recursive -- "$MT_BIN" uses --recursive tree

  # link is already done by install; unlink + re-link exercises the code path.
  run_ok t3.unlink -- "$MT_BIN" unlink tree
  run_ok t3.link -- "$MT_BIN" link tree
  run_ok t3.link.overwrite -- "$MT_BIN" link tree --overwrite

  # backup / restore round-trip.
  run_ok t3.backup -- "$MT_BIN" backup --output "$LOGDIR/backup.txt"
  run_ok t3.backup.versions -- "$MT_BIN" backup --versions --output "$LOGDIR/backup-v.txt"
  run_ok t3.restore.dry -- "$MT_BIN" restore "$LOGDIR/backup.txt" --dry-run

  # bundle round-trip.
  run_ok t3.bundle.export -- "$MT_BIN" bundle export
  run_ok t3.bundle.create -- "$MT_BIN" bundle create --format json "$LOGDIR/Maltfile.json"
  run_ok t3.bundle.list -- "$MT_BIN" bundle list
  run_ok t3.bundle.install.dry -- "$MT_BIN" bundle install --dry-run "$LOGDIR/Maltfile.json"

  # run: already-installed path (no re-download).
  run_ok t3.run.tree -- "$MT_BIN" run tree -- --version

  # purge dry-runs only — never destructive here.
  run_ok t3.purge.store.dry -- "$MT_BIN" purge --store-orphans --dry-run
  run_ok t3.purge.house.dry -- "$MT_BIN" purge --housekeeping --dry-run
  run_ok t3.purge.cache.dry -- "$MT_BIN" purge --cache=7 --dry-run

  # uninstall — removes from sandbox.
  run_ok t3.uninstall -- "$MT_BIN" uninstall tree

  # After uninstall, rollback on an uninstalled package should fail cleanly.
  run t3.rollback.none 1 -- "$MT_BIN" rollback tree

  # Issue #85 regression: zig pulls llvm@21 whose post_install uses Ruby's
  # `&:sym` block-pass shorthand. If the DSL parser or fatal-classification
  # ever regresses, the install prints "post_install DSL failed for llvm@21"
  # — the grep below will catch it. Gated on SMOKE_INSTALL_HEAVY because the
  # llvm@21 bottle is ~350 MB and most CI runs shouldn't download it.
  if [[ "${SMOKE_INSTALL_HEAVY:-0}" == "1" ]]; then
    run_ok t3.install.zig -- "$MT_BIN" install zig
    run 't3.install.zig.no_post_install_fatal' 1 -- \
      grep -q "post_install DSL failed for llvm@21" "$LOGDIR/t3_install_zig.log"
    run_ok t3.uninstall.zig -- "$MT_BIN" uninstall zig
  fi
fi

# ── Summary ────────────────────────────────────────────────────────────────

section "Summary"
TOTAL=$((PASS + FAIL))
printf 'Ran %d tests — %d passed, %d failed.\n' "$TOTAL" "$PASS" "$FAIL"
if ((FAIL > 0)); then
  printf 'Failures:\n'
  for t in "${FAILURES[@]}"; do printf '  - %s\n' "$t"; done
  printf 'Logs in: %s (preserved on failure)\n' "$LOGDIR"
  trap - EXIT # keep logs for post-mortem
  exit 1
fi
exit 0
