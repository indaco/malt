#!/usr/bin/env bash
# scripts/e2e/smoke_security.sh
#
# End-to-end smoke coverage for malt's security-critical surfaces.
# Each check is a thin exercise of one protection added in the
# 2026-04-17 audit remediation. Kept separate from smoke_test.sh so
# "did anything regress on the security story?" has a single, fail-
# loud entry point.
#
# Tiers:
#   1. CLI flag surface      (--use-system-ruby scoping, help text)
#   2. Static guards         (argv-only lint, pins_manifest shape)
#   3. Integration harness   (install.sh fail-closed regression suite)
#
# Safe to run anywhere — no network, no real installs, no launchd.
# Cleans up its tmp prefix on exit.
#
# Usage:
#   ./scripts/e2e/smoke_security.sh
#   MT_BIN=./zig-out/bin/mt ./scripts/e2e/smoke_security.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT" || exit 2

MT_BIN="${MT_BIN:-./zig-out/bin/malt}"
if [[ ! -x "$MT_BIN" ]]; then
  echo "smoke-security: $MT_BIN not found — run 'zig build' first" >&2
  exit 2
fi
MT_BIN="$(cd "$(dirname "$MT_BIN")" && pwd)/$(basename "$MT_BIN")"

PREFIX=$(mktemp -d /tmp/mt_sec.XXX)
CACHE=$(mktemp -d /tmp/mc_sec.XXX)
LOGDIR=$(mktemp -d /tmp/ml_sec.XXX)
trap 'rm -rf "$PREFIX" "$CACHE" "$LOGDIR"' EXIT

export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$CACHE"
export NO_COLOR=1
export MALT_NO_EMOJI=1

PASS=0
FAIL=0
FAILURES=()

# ── Helpers (same shape as smoke_test.sh so the two read alike) ────────

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
    sed -n '1,10p' "$log" | sed 's/^/        | /'
    FAIL=$((FAIL + 1))
    FAILURES+=("$tag")
  fi
}

run_ok() {
  local t="$1"
  shift
  run "$t" 0 "$@"
}

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
    printf '  FAIL  [%s] rc=%s, /%s/ missing :: %s\n' "$tag" "$rc" "$pat" "$*"
    printf '        log: %s\n' "$log"
    sed -n '1,10p' "$log" | sed 's/^/        | /'
    FAIL=$((FAIL + 1))
    FAILURES+=("$tag")
  fi
}

manual_pass() {
  printf '  PASS  [%s] %s\n' "$1" "$2"
  PASS=$((PASS + 1))
}
manual_fail() {
  printf '  FAIL  [%s] %s\n' "$1" "$2" >&2
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
}

section() { printf '\n── %s ───────────────────────────────────────\n' "$1"; }

# ── Tier 1 — CLI flag surface ──────────────────────────────────────────

section "Tier 1 — --use-system-ruby scope enforcement + help text"

# The audit (Finding #2) asked us to scope --use-system-ruby per-formula
# so a DSL parse failure on one package can't auto-widen the trust
# boundary for all the others. These three exit-code probes lock that in.

# Bare flag with multiple packages is ambiguous → refuse.
run s1.install.ambiguous 1 -- \
  "$MT_BIN" install --use-system-ruby fake-pkg-a fake-pkg-b

# Bare flag on migrate is never allowed — would apply to every keg the
# Homebrew Cellar happens to carry.
run s1.migrate.bare-rejected 1 -- "$MT_BIN" migrate --use-system-ruby

# Help text must mention the scoped form so users find it.
run_grep s1.help.install "use-system-ruby" -- "$MT_BIN" install --help
run_grep s1.help.migrate "use-system-ruby=" -- "$MT_BIN" migrate --help

# ── Tier 2 — static guards ─────────────────────────────────────────────

section "Tier 2 — argv-only lint + pinned-manifest shape"

# Finding #4: shell-invocation patterns in src/ are a regression. The
# lint script fails non-zero on any hit; re-run it here so "zig build
# finishes" isn't the only gate.
run_ok s2.lint.argv -- "$ROOT/scripts/lint-spawn-invariants.sh"

# Finding #1: pins_manifest.txt is the allowlist for the Ruby fetch
# path. Entries here must have a 64-char lowercase hex SHA256, or the
# runtime parser will reject them. This catches a botched gen-pins.sh
# run before release rather than at install time.
MANIFEST="$ROOT/src/core/pins_manifest.txt"
if [[ ! -f "$MANIFEST" ]]; then
  manual_fail s2.manifest.exists "src/core/pins_manifest.txt missing"
else
  bad_line=""
  entries=0
  while IFS= read -r raw; do
    line="${raw%%$'\r'*}"
    # Skip comments + blanks (same parser as src/core/pins.zig).
    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == "#" ]] && continue
    entries=$((entries + 1))
    name="${line%% *}"
    rest="${line#* }"
    # Strip leading whitespace.
    rest="${rest#"${rest%%[! $'\t']*}"}"
    hash="${rest:0:64}"
    if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]]; then
      bad_line="$raw"
      break
    fi
    if [[ -z "$name" ]]; then
      bad_line="$raw"
      break
    fi
  done <"$MANIFEST"
  if [[ -n "$bad_line" ]]; then
    manual_fail s2.manifest.shape "malformed entry: $bad_line"
  elif [[ "$entries" -lt 1 ]]; then
    # An empty manifest is parser-valid but silently disables every
    # post_install fetch — the state that shipped before the seed was
    # populated. Guard against regressing back to it.
    manual_fail s2.manifest.entries "pins_manifest.txt has no entries (run scripts/gen-pins.sh)"
  else
    manual_pass s2.manifest.shape "$entries entries, all well-formed (64-char lowercase hex SHA256)"
  fi
fi

# The pinned commit constant should be a 40-char lowercase hex SHA.
PINS_ZIG="$ROOT/src/core/pins.zig"
sha=$(grep -E 'homebrew_core_commit_sha.*=.*"' "$PINS_ZIG" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  manual_pass s2.pins.commit-sha "pinned commit: $sha"
else
  manual_fail s2.pins.commit-sha "homebrew_core_commit_sha is not 40-char hex: '$sha'"
fi

# ── Tier 3 — install.sh fail-closed regression harness ────────────────

section "Tier 3 — install.sh fail-closed regression suite"

# The suite under scripts/test/ owns the detailed assertions (happy
# path + missing checksums + unlisted archive + SHA mismatch). We
# shell out so one top-level smoke run covers the integrity story.
if "$ROOT/scripts/test/install_sh_test.sh" >"$LOGDIR/install_sh.log" 2>&1; then
  manual_pass s3.install_sh "checksum/signature paths all fail-closed"
else
  manual_fail s3.install_sh "install_sh_test.sh suite failed — see $LOGDIR/install_sh.log"
  sed -n '1,30p' "$LOGDIR/install_sh.log" | sed 's/^/        | /' >&2
fi

# Informational: cosign presence. Missing cosign forces MALT_ALLOW_UNVERIFIED
# in production, which is a degraded mode. We just report it.
if command -v cosign >/dev/null 2>&1; then
  printf '  INFO  [s3.cosign] cosign on PATH — install.sh will verify signatures\n'
else
  printf '  INFO  [s3.cosign] cosign NOT on PATH — install.sh will demand MALT_ALLOW_UNVERIFIED=1\n'
fi

# ── Summary ───────────────────────────────────────────────────────────

section "Summary"
TOTAL=$((PASS + FAIL))
printf 'Ran %d security checks — %d passed, %d failed.\n' "$TOTAL" "$PASS" "$FAIL"
if ((FAIL > 0)); then
  printf 'Failures:\n'
  for t in "${FAILURES[@]}"; do printf '  - %s\n' "$t"; done
  printf 'Logs in: %s (preserved on failure)\n' "$LOGDIR"
  trap - EXIT
  exit 1
fi
exit 0
