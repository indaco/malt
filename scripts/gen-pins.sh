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
#   FORMULAS="fontconfig openssl@3" scripts/gen-pins.sh
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
  COMMIT=$(curl -fsSL --max-time 10 \
    "https://api.github.com/repos/Homebrew/homebrew-core/commits/HEAD" |
    awk -F'"' '/^  "sha":/ {print $4; exit}')
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
MANIFEST=src/core/pins_manifest.txt
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
  first=${name:0:1}
  url="https://raw.githubusercontent.com/Homebrew/homebrew-core/${COMMIT}/Formula/${first}/${name}.rb"
  # Download to a file — command substitution strips trailing newlines,
  # which makes the computed SHA256 disagree with the runtime fetch (the
  # runtime hashes the raw bytes, trailing newline included).
  #
  # Drop -f and inspect %{http_code} ourselves so 404s (formulas in the
  # API's HEAD snapshot that were renamed/moved before the pinned commit)
  # produce one clean warning per entry instead of a raw "curl: (56)"
  # dump in CI logs.
  http_code=$(curl -sSL --max-time 15 -o "$RB_TMP" -w '%{http_code}' "$url" 2>/dev/null || echo "000")
  case "$http_code" in
  200) ;;
  404)
    printf '  ⚠ %-24s not at pinned commit (skipping)\n' "$name" >&2
    continue
    ;;
  *)
    printf '  ⚠ %-24s HTTP %s (skipping)\n' "$name" "$http_code" >&2
    continue
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
