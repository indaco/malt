#!/usr/bin/env bash
# scripts/gen-pins.sh — regenerate src/core/pins.zig + pins_manifest.txt
#
# Pins the homebrew-core fetch path in malt to a specific commit and
# records the SHA256 of every formula's .rb blob at that commit. The
# runtime refuses any formula whose fetched source doesn't match an
# entry here (see src/core/pins.zig::expectedSha256).
#
# Usage:
#   scripts/gen-pins.sh                        # auto-pin to current HEAD
#   scripts/gen-pins.sh <commit-sha>           # pin to specific commit
#   scripts/gen-pins.sh --check               # verify committed manifest
#   FORMULAS="fontconfig openssl@3" scripts/gen-pins.sh
#
# --check re-verifies every committed manifest entry's hash against the
# committed pin and writes nothing. It deliberately skips the live-API
# enumeration: the formula list tracks homebrew-core HEAD and moves under
# a frozen pin, so a full regen is not reproducible on CI. Freshness is
# owned by the scheduled pins-bump auto-PR, which runs the full regen.
#
# Env:
#   FORMULAS  — space-separated list of formulas to seed. Defaults to a
#               small set covering the most common post_install paths.
#
# Output: writes src/core/pins.zig's SHA constant and rewrites
#         src/core/pins_manifest.txt in place. Run `git diff` after.
#
# Network: fetches from raw.githubusercontent.com; safe to run offline
#          only if the target commit is already cached (rare — don't).

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# Pick the first working sha256 hasher. macOS ships /usr/bin/shasum, but
# nanobrew/homebrew setups can shadow the Perl runtime and leave it
# broken; fall back to sha256sum (coreutils) or openssl.
if command -v sha256sum >/dev/null 2>&1 && sha256sum </dev/null >/dev/null 2>&1; then
  sha256_stdin() { sha256sum | awk '{print $1}'; }
elif /usr/bin/shasum -a 256 </dev/null >/dev/null 2>&1; then
  sha256_stdin() { /usr/bin/shasum -a 256 | awk '{print $1}'; }
elif command -v openssl >/dev/null 2>&1; then
  sha256_stdin() { openssl dgst -sha256 -r | awk '{print $1}'; }
else
  echo "error: no working sha256 hasher (need sha256sum, shasum, or openssl)" >&2
  exit 1
fi

# PINS_MANIFEST is an override seam for tests; production always uses the
# committed manifest.
MANIFEST="${PINS_MANIFEST:-src/core/pins_manifest.txt}"

# Download Formula/<x>/<name>.rb at <commit> into $RB_TMP and echo the
# terminal HTTP code. Downloads to a file — command substitution strips
# trailing newlines, which makes the computed SHA256 disagree with the
# runtime fetch (the runtime hashes the raw bytes, newline included).
# raw.githubusercontent rate-limits by IP: 429 / transient 5xx / transport
# errors (000) are retried with backoff. Only 200 and 404 are terminal —
# both are deterministic at a pinned commit; the caller decides what a
# 404 means for its mode.
fetch_rb() {
  name="$1"
  commit="$2"
  first=${name:0:1}
  url="https://raw.githubusercontent.com/Homebrew/homebrew-core/${commit}/Formula/${first}/${name}.rb"
  http_code=""
  for attempt in 1 2 3 4 5; do
    http_code=$(curl -sSL --max-time 15 -o "$RB_TMP" -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    case "$http_code" in
    200 | 404) break ;;
    esac
    [ "$attempt" -eq 5 ] && break
    sleep "$((attempt * 3))" # 3s, 6s, 9s, 12s backoff
  done
  printf '%s' "$http_code"
}

read_committed_pin() {
  grep -E 'homebrew_core_commit_sha.*=.*"' src/core/pins.zig |
    head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}

# ── --check: verify the committed manifest against the committed pin ──
# Read-only integrity gate for CI: every entry's blob must exist at the
# pin and hash to the committed value. Catches "bumped pins.zig, forgot
# to regenerate" (all hashes mismatch), hand-edited entries, and names
# absent at the pin — without depending on the moving live formula list.
if [ "${1:-}" = "--check" ]; then
  PIN=$(read_committed_pin)
  if [ ${#PIN} -ne 40 ]; then
    echo "error: no committed pin found in src/core/pins.zig" >&2
    exit 1
  fi
  printf '▸ verifying %s against pin %s\n' "$MANIFEST" "$PIN" >&2

  RB_TMP=$(mktemp)
  trap 'rm -f "$RB_TMP"' EXIT

  checked=0
  bad=0
  while IFS=' ' read -r name sha _; do
    case "$name" in '' | '#'*) continue ;; esac
    code=$(fetch_rb "$name" "$PIN")
    case "$code" in
    200) ;;
    404)
      printf '  ✗ %-24s not at pinned commit\n' "$name" >&2
      bad=$((bad + 1))
      continue
      ;;
    *)
      printf '  ✗ %-24s HTTP %s after retries\n' "$name" "$code" >&2
      exit 1
      ;;
    esac
    got=$(sha256_stdin <"$RB_TMP")
    if [ "$got" != "$sha" ]; then
      printf '  ✗ %-24s hash mismatch (manifest %s, pinned %s)\n' "$name" "$sha" "$got" >&2
      bad=$((bad + 1))
      continue
    fi
    checked=$((checked + 1))
  done <"$MANIFEST"

  if [ "$checked" -eq 0 ]; then
    echo "error: no entries verified — empty or unreadable manifest" >&2
    exit 1
  fi
  if [ "$bad" -ne 0 ]; then
    printf 'error: %d manifest entr(y/ies) do not match the pinned commit\n' "$bad" >&2
    printf 'Run scripts/gen-pins.sh <pinned-commit> and commit the diff.\n' >&2
    exit 1
  fi
  printf '▸ %d entries verified against the pinned commit\n' "$checked" >&2
  exit 0
fi

# Fallback seed — TLS + popular language toolchains. Only used when the
# Homebrew API enumeration below can't be reached (offline dev runs).
FALLBACK_FORMULAS=(
  ca-certificates
  fontconfig
  git
  go
  node
  openssl@3
  perl
  python@3.11
  python@3.12
  python@3.13
  ruby
)

# Resolve the formula list. Explicit FORMULAS env var wins (useful for
# tests and one-off regeneration). Otherwise pull every formula whose
# post_install_defined flag is true from formulae.brew.sh — an exhaustive
# allowlist is what the fail-closed gate actually needs. Fall back to the
# static seed only when the API is unreachable.
if [ -n "${FORMULAS:-}" ]; then
  # shellcheck disable=SC2206
  read -r -a FORMULAS_ARR <<<"$FORMULAS"
  printf '▸ using FORMULAS override (%d entries)\n' "${#FORMULAS_ARR[@]}" >&2
else
  printf '▸ enumerating post_install formulas from formulae.brew.sh\n' >&2
  api_json=$(curl -fsSL --max-time 30 "https://formulae.brew.sh/api/formula.json" || true)
  if [ -n "$api_json" ]; then
    # Python 3 ships on every supported runner and all dev macOS/Linux
    # boxes; avoids a jq dependency on CI. Read line-by-line instead of
    # `mapfile` because macOS still ships bash 3.2.
    FORMULAS_ARR=()
    while IFS= read -r line; do
      [ -n "$line" ] && FORMULAS_ARR+=("$line")
    done < <(
      printf '%s' "$api_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for f in data:
    if f.get("post_install_defined") and f.get("name"):
        print(f["name"])
' | LC_ALL=C sort -u
    )
    printf '▸ %d formulas have post_install_defined\n' "${#FORMULAS_ARR[@]}" >&2
  else
    printf '  ⚠ API fetch failed — falling back to static seed\n' >&2
    FORMULAS_ARR=("${FALLBACK_FORMULAS[@]}")
  fi
fi

if [ $# -ge 1 ]; then
  COMMIT="$1"
else
  printf '▸ resolving homebrew-core HEAD\n' >&2
  # Use git ls-remote, not the api.github.com REST endpoint: the latter's
  # anonymous 60-req/hr cap is shared across GitHub-hosted runner egress
  # IPs and reliably 403s the scheduled run. ls-remote hits the git smart
  # protocol (no REST rate limit, no token) and returns the SHA directly.
  COMMIT=$(git ls-remote https://github.com/Homebrew/homebrew-core.git HEAD |
    awk 'NR==1{print $1}')
  [ -n "$COMMIT" ] || {
    echo "failed to resolve HEAD" >&2
    exit 1
  }
fi

case "$COMMIT" in
[0-9a-f]*)
  [ ${#COMMIT} -eq 40 ] || {
    echo "not a 40-char SHA: $COMMIT" >&2
    exit 1
  }
  ;;
*)
  echo "not a hex SHA: $COMMIT" >&2
  exit 1
  ;;
esac
printf '▸ pinning to %s\n' "$COMMIT" >&2

# Rewrite pins.zig's commit constant. sed -i portability: BSD sed needs
# -i '' (empty extension); GNU sed accepts -i with no arg. Detect.
if sed --version >/dev/null 2>&1; then
  SED_INPLACE=(sed -i)
else
  SED_INPLACE=(sed -i '')
fi
"${SED_INPLACE[@]}" \
  "s|^pub const homebrew_core_commit_sha: \\[40\\]u8 = .*|pub const homebrew_core_commit_sha: [40]u8 = \"${COMMIT}\".*;|" \
  src/core/pins.zig

# Regenerate the manifest.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

cat >"$TMP" <<'HEADER'
# malt — pinned formula source manifest
#
# One record per line:  <formula-name> <sha256-of-.rb-at-pinned-commit>
#
# Entries here authorize fetchPostInstallFromGitHub() to execute the
# matching Ruby source after verifying its SHA256. Formulas with no
# entry are refused — the code path is fail-closed.
#
# Regenerate with: scripts/gen-pins.sh
# Pinned commit lives in src/core/pins.zig (homebrew_core_commit_sha).
#
# Lines starting with '#' and blank lines are ignored.
HEADER
printf '\n' >>"$TMP"

RB_TMP=$(mktemp)
trap 'rm -f "$TMP" "$RB_TMP"' EXIT

for name in "${FORMULAS_ARR[@]}"; do
  [ -n "$name" ] || continue
  # 404s here are formulas in the API's HEAD snapshot that were renamed or
  # moved before the pinned commit — skip with a warning. Anything else is
  # fail-loud: never emit a silently-incomplete manifest that would read
  # as a drift downstream.
  code=$(fetch_rb "$name" "$COMMIT")
  case "$code" in
  200) ;;
  404)
    printf '  ⚠ %-24s not at pinned commit (skipping)\n' "$name" >&2
    continue
    ;;
  *)
    printf '  ✗ %-24s HTTP %s after retries\n' "$name" "$code" >&2
    exit 1
    ;;
  esac
  sha=$(sha256_stdin <"$RB_TMP")
  printf '%s %s\n' "$name" "$sha" >>"$TMP"
  printf '  ✓ %-24s %s\n' "$name" "$sha" >&2
done

mv "$TMP" "$MANIFEST"
trap - EXIT
printf '\n▸ wrote %s\n' "$MANIFEST" >&2
printf '▸ review the diff, then commit:\n' >&2
printf '    git diff src/core/pins.zig src/core/pins_manifest.txt\n' >&2
