#!/usr/bin/env bash
# scripts/test/verify_cask_paths_test.sh — release-time cross-check
# regression tests for scripts/release/verify_cask_paths.sh.
#
# Each fixture synthesises a (tarball-root, cask.rb) pair and asserts
# the helper's exit code and stderr greppability:
#
#   1. flat tarball + cask with root-relative binaries → pass
#   2. wrapped tarball + cask declaring wrapped-relative binaries → pass
#   3. cask declares a path the tarball doesn't contain → fail with
#      "cask path missing in tarball: <path>" per missing entry
#
# Usage:
#   ./scripts/test/verify_cask_paths_test.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HELPER="$ROOT/scripts/release/verify_cask_paths.sh"

[ -x "$HELPER" ] || {
  echo "verify_cask_paths.sh missing or not executable at $HELPER" >&2
  exit 2
}

TMP=$(mktemp -d /tmp/malt_verify_cask_paths_test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
failures=()

# Build a flat tarball-root layout: malt + mt symlink + LICENSE at root.
# Mirrors what goreleaser produces post-#376.
make_flat_root() {
  local root="$1"
  mkdir -p "$root"
  printf '#!/bin/sh\nexit 0\n' >"$root/malt"
  chmod +x "$root/malt"
  ln -sfn malt "$root/mt"
  printf 'license text\n' >"$root/LICENSE"
}

# Build a wrapped layout: everything under <root>/malt_X_Y_darwin_all/.
# Forward-compat for any future config that re-introduces wrap_in_directory.
make_wrapped_root() {
  local root="$1" wrapper="$2"
  mkdir -p "$root/$wrapper"
  printf '#!/bin/sh\nexit 0\n' >"$root/$wrapper/malt"
  chmod +x "$root/$wrapper/malt"
  ln -sfn malt "$root/$wrapper/mt"
}

# Render a minimal cask.rb. $1 is the path, $2 is the binary stanza
# body (one path per line, e.g. "malt\nmt" or "wrap/malt\nwrap/mt"),
# $3 is the postflight reference suffix (e.g. "malt" → "#{staged_path}/malt").
write_cask() {
  local cask_path="$1" binaries="$2" staged_suffix="$3"
  {
    printf 'cask "malt" do\n'
    printf '  version "9.9.9"\n'
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      printf '  binary "%s"\n' "$b"
    done <<<"$binaries"
    printf '  postflight do\n'
    printf '    if OS.mac?\n'
    printf '      system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{staged_path}/%s"]\n' "$staged_suffix"
    printf '    end\n'
    printf '  end\n'
    printf 'end\n'
  } >"$cask_path"
}

# ── test 1: flat tarball, root-relative binaries ─────────────────────
printf '▸ flat tarball + root-relative binaries\n'
ROOT1="$TMP/flat-root"
CASK1="$TMP/flat.rb"
make_flat_root "$ROOT1"
write_cask "$CASK1" "malt
mt" "malt"
if "$HELPER" "$ROOT1" "$CASK1" >"$TMP/flat.out" 2>&1; then
  printf '  ✓ flat layout accepted\n'
  pass=$((pass + 1))
else
  printf '  ✗ flat layout rejected (rc=%s)\n' "$?" >&2
  cat "$TMP/flat.out" >&2
  fail=$((fail + 1))
  failures+=("flat-rejected")
fi

# ── test 2: wrapped tarball, wrapped-relative binaries ───────────────
printf '▸ wrapped tarball + wrapped-relative binaries\n'
ROOT2="$TMP/wrapped-root"
CASK2="$TMP/wrapped.rb"
WRAP="malt_9.9.9_darwin_all"
make_wrapped_root "$ROOT2" "$WRAP"
write_cask "$CASK2" "$WRAP/malt
$WRAP/mt" "$WRAP/malt"
if "$HELPER" "$ROOT2" "$CASK2" >"$TMP/wrapped.out" 2>&1; then
  printf '  ✓ wrapped layout accepted\n'
  pass=$((pass + 1))
else
  printf '  ✗ wrapped layout rejected (rc=%s)\n' "$?" >&2
  cat "$TMP/wrapped.out" >&2
  fail=$((fail + 1))
  failures+=("wrapped-rejected")
fi

# ── test 3: regression of #375 — flat tarball but cask hardcodes the
#            wrapped path; helper must report both binaries missing. ──
printf '▸ cask paths missing in tarball (#375 shape)\n'
ROOT3="$TMP/regression-root"
CASK3="$TMP/regression.rb"
make_flat_root "$ROOT3"
write_cask "$CASK3" "$WRAP/malt
$WRAP/mt" "$WRAP/malt"
rc=0
"$HELPER" "$ROOT3" "$CASK3" >"$TMP/regression.out" 2>&1 || rc=$?
if [ "$rc" = "0" ]; then
  printf '  ✗ missing paths NOT rejected (rc=0)\n' >&2
  fail=$((fail + 1))
  failures+=("missing-allowed")
else
  printf '  ✓ missing paths rejected (rc=%s)\n' "$rc"
  pass=$((pass + 1))
fi
# Stable failure prefix is the public contract for any future
# release-monitoring scrape — assert it appears for each missing path.
for missing in "$WRAP/malt" "$WRAP/mt"; do
  if grep -q "cask path missing in tarball: $missing" "$TMP/regression.out"; then
    printf '  ✓ stderr names %s\n' "$missing"
    pass=$((pass + 1))
  else
    printf '  ✗ stderr did not name %s\n' "$missing" >&2
    cat "$TMP/regression.out" >&2
    fail=$((fail + 1))
    failures+=("missing-no-mention-$missing")
  fi
done

# ── summary ──────────────────────────────────────────────────────────
printf '\n── summary ──\npass: %d\nfail: %d\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf 'failures:\n'
  for f in "${failures[@]}"; do printf '  %s\n' "$f"; done
  exit 1
fi
