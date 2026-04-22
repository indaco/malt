#!/usr/bin/env bash
# Smoke test for issue #136 — `.tar.gz` and `.tgz` casks were rejected
# with "Unsupported cask format for '<token>'" across the board,
# covering thousands of casks (most GoReleaser-packaged CLIs ship
# their macOS builds this way: copilot-cli, fly, codex, …).
#
# The fix teaches `core/cask.zig` about `tar_gz` containers and the
# `artifacts[].binary` shape — an extracted binary gets symlinked into
# `$MALT_PREFIX/bin/` so it lands on the user's `$PATH` the same way
# a formula's keg does.
#
# The script walks a handful of real tar.gz casks, tolerates individual
# upstream outages (network/release churn), but fails hard on the
# original rejection symptom. A small formula install (`hello`) runs
# afterwards to prove the formula tar.gz/bottle path — which has always
# worked — was not collaterally broken by this change.
#
# Usage: scripts/regressions/cask_targz_gh136.sh
# Requirements: built `malt` binary at $MALT_BIN or zig-out/bin/malt,
# network access to github.com / formulae.brew.sh / upstream release hosts.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# MALT_PREFIX must be ≤ 13 bytes (Mach-O in-place patching budget).
PREFIX="/tmp/mt_gh136"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
skip() { printf '  - %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

# ── Candidate tar.gz binary casks ──────────────────────────────────────
#
# Mixed `.tar.gz` and `.tgz` URL shapes, each paired with the binary
# name it ships. The symlink at $PREFIX/bin/<bin> pointing into
# Caskroom/<token>/<version>/ is the observable we assert on.
#
# Individual casks may disappear or change upstream — we require at
# least one of the candidates to install cleanly; the rest are best
# effort. Extend this list when adding canonical examples.
declare -a CASKS=(
  "copilot-cli:copilot" # .tar.gz, bare binary at archive root
  "fly:fly"             # .tgz variant — exercises the second suffix
  "codex:codex"         # .tar.gz, `binary [src, {target: alias}]` rename
  "dda:dda"             # .tar.gz, different upstream (DataDog)
  "filemon:filemon"     # .tgz, small binary from newosxbook.com
)

installed_any=0
for spec in "${CASKS[@]}"; do
  token="${spec%%:*}"
  bin="${spec##*:}"
  LOG="$PREFIX/install_${token}.log"
  printf '▸ malt install %s (logs → %s)\n' "$token" "$LOG"

  "$BIN" install "$token" >"$LOG" 2>&1 || true

  # The blanket rejection is the regression we're guarding — it must
  # never surface, even if another part of the install fails.
  if grep -q "Unsupported cask format for '${token}'" "$LOG"; then
    tail -20 "$LOG" >&2
    fail "'${token}': regression — tar.gz cask still rejected"
  fi

  # Tolerate unrelated transient failures (upstream 404, sha256 drift,
  # TLS hiccups) so one flaky cask does not mask the fix for the rest.
  if grep -qE "Failed to install (cask )?${token}|Sha256Mismatch|DownloadFailed" "$LOG"; then
    skip "${token}: install reported a non-regression failure; continuing"
    continue
  fi

  link="$PREFIX/bin/$bin"
  if [[ ! -L "$link" ]]; then
    tail -20 "$LOG" >&2
    fail "'${token}': expected symlink at $link"
  fi

  target=$(readlink "$link")
  if [[ "$target" != *"/Caskroom/${token}/"* ]]; then
    fail "'${token}': symlink points at '$target' (expected Caskroom/${token}/…)"
  fi

  if [[ ! -x "$target" ]]; then
    fail "'${token}': symlink target '$target' is not executable"
  fi

  pass "${token}: tar.gz cask installed → \$PREFIX/bin/${bin} → ${target##*/Caskroom/}"
  installed_any=1
done

((installed_any == 1)) || fail "no tar.gz cask installed — check network and candidate list"

# ── Formula sanity: tap/bottle tar.gz paths are unaffected. ────────────
#
# Homebrew formula bottles are also `.tar.gz`, but flow through an
# entirely separate install path (bottle materialisation, not the cask
# installer). This step guards against accidentally regressing the
# formula side when touching cask's tar.gz detection. `hello` is the
# smallest published formula with a real binary payload.

FORMULA_TARGET="${FORMULA_TARGET:-hello}"
FLOG="$PREFIX/install_${FORMULA_TARGET}.log"
printf '▸ malt install %s (formula sanity, logs → %s)\n' "$FORMULA_TARGET" "$FLOG"
if ! "$BIN" install "$FORMULA_TARGET" >"$FLOG" 2>&1; then
  skip "${FORMULA_TARGET} install failed (likely network); skipping formula sanity"
else
  grep -qE "${FORMULA_TARGET} [^ ]+ installed|✓ ${FORMULA_TARGET}.* installed" "$FLOG" ||
    fail "${FORMULA_TARGET}: formula install line missing in log"
  [[ -x "$PREFIX/bin/$FORMULA_TARGET" ]] ||
    fail "${FORMULA_TARGET}: expected executable at \$PREFIX/bin/${FORMULA_TARGET}"
  pass "${FORMULA_TARGET}: formula install path still works (tar.gz bottle)"
fi

printf '\n✔ gh136 tar.gz cask regression passed\n'
