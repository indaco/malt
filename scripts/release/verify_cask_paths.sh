#!/usr/bin/env bash
# scripts/release/verify_cask_paths.sh — release-time static cross-check
#
# Parses a rendered Homebrew cask and asserts every `binary "..."` and
# `#{staged_path}/...` reference resolves to a real file (or non-dangling
# symlink) under the extracted-tarball root. Closes the gap that let
# #375 ship: goreleaser renders the cask and the tarball independently
# with no path-consistency check between them.
#
# Usage:
#   verify_cask_paths.sh <extracted_root> <cask_rb_path>
#
# Exit:
#   0  every declared path resolved
#   1  one or more paths missing — each printed to stderr as
#      "cask path missing in tarball: <path>"  (stable prefix; do not
#      reword without updating the release-monitoring scrape).
#   2  usage error.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <extracted_root> <cask_rb_path>" >&2
  exit 2
fi

root="$1"
cask="$2"

[ -d "$root" ] || {
  echo "extracted root not a directory: $root" >&2
  exit 2
}
[ -f "$cask" ] || {
  echo "cask file not found: $cask" >&2
  exit 2
}

# Collect every declared path, deduped via `sort -u`. The postflight
# typically re-references a path already declared as `binary`, and
# reporting the same miss twice is just noise. `binary "x"` and
# `manpage "x"` live anywhere in the cask; `#{staged_path}/x` references
# live inside `postflight do ... end` but the regex is specific enough
# that a flat scan is safe. `manpage` resolves relative to the staged
# path just like `binary`, so the tarball must carry it too — otherwise
# goreleaser's `manpages:` stanza and the archive layout could disagree
# unnoticed until a user's `brew install --cask` fails.
paths=()
while IFS= read -r p; do
  [ -n "$p" ] && paths+=("$p")
done < <(
  {
    sed -nE 's/^[[:space:]]*binary[[:space:]]+"([^"]+)".*/\1/p' "$cask"
    sed -nE 's/^[[:space:]]*manpage[[:space:]]+"([^"]+)".*/\1/p' "$cask"
    sed -nE 's/.*#\{staged_path\}\/([^"]+).*/\1/p' "$cask"
  } | sort -u
)

if [ "${#paths[@]}" -eq 0 ]; then
  echo "no binary, manpage, or staged_path references found in $cask" >&2
  exit 2
fi

missing=0
for p in "${paths[@]}"; do
  # `test -e` follows symlinks; a dangling `mt -> malt` therefore
  # fails (correct behaviour — the user would hit the same failure
  # at install time).
  if [ -e "$root/$p" ]; then
    printf 'verified: %s\n' "$p"
  else
    printf 'cask path missing in tarball: %s\n' "$p" >&2
    missing=$((missing + 1))
  fi
done

[ "$missing" -eq 0 ]
