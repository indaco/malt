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

# Default seed set — formulas whose post_install runs during common
# installs (TLS + language toolchains). Callers can override via FORMULAS.
DEFAULT_FORMULAS=(
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
# shellcheck disable=SC2206
read -r -a FORMULAS_ARR <<<"${FORMULAS:-${DEFAULT_FORMULAS[*]}}"

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
  "s|^pub const HOMEBREW_CORE_COMMIT_SHA: \\[\\]const u8 = .*|pub const HOMEBREW_CORE_COMMIT_SHA: []const u8 = \"${COMMIT}\";|" \
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
# Pinned commit lives in src/core/pins.zig (HOMEBREW_CORE_COMMIT_SHA).
#
# Lines starting with '#' and blank lines are ignored.
HEADER
printf '\n' >>"$TMP"

for name in "${FORMULAS_ARR[@]}"; do
  [ -n "$name" ] || continue
  first=${name:0:1}
  url="https://raw.githubusercontent.com/Homebrew/homebrew-core/${COMMIT}/Formula/${first}/${name}.rb"
  body=$(curl -fsSL --max-time 15 "$url" || true)
  if [ -z "$body" ]; then
    printf '  ⚠ %s: fetch failed (skipping)\n' "$name" >&2
    continue
  fi
  sha=$(printf '%s' "$body" | sha256_stdin)
  printf '%s %s\n' "$name" "$sha" >>"$TMP"
  printf '  ✓ %-24s %s\n' "$name" "$sha" >&2
done

mv "$TMP" "$MANIFEST"
trap - EXIT
printf '\n▸ wrote %s\n' "$MANIFEST" >&2
printf '▸ review the diff, then commit:\n' >&2
printf '    git diff src/core/pins.zig src/core/pins_manifest.txt\n' >&2
