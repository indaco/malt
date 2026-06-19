#!/usr/bin/env bash
# scripts/test/man_sync_hook_test.sh — contract tests for the sley post-bump
# man-sync hook (.sley-extensions/man-sync/hook.sh).
#
# The hook regenerates the committed man page after a version bump. It reads a
# JSON HookInput on stdin, builds the binary, regenerates the page under
# project_root, and prints a HookOutput JSON. sley aborts the bump on any
# non-zero exit or success:false, so both paths are load-bearing:
#
#   1. success — pipes a synthetic HookInput; asserts exit 0, success:true
#      JSON, and that the page was written under project_root carrying the
#      project's .version (not the cwd's). A fake `zig` keeps the build cheap;
#      the hook's job under test is orchestration + the JSON contract, not the
#      compile itself.
#   2. failure — points project_root at a tree where generation fails; asserts
#      non-zero exit and success:false, so a flaky generator aborts the release
#      instead of committing a half-written page.
#
# Usage:
#   ./scripts/test/man_sync_hook_test.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
HOOK="$ROOT/.sley-extensions/man-sync/hook.sh"
GEN="$ROOT/scripts/gen-man.sh"
BIN="$ROOT/zig-out/bin/malt"

[ -x "$BIN" ] || {
  echo "malt binary missing at $BIN — run 'zig build' first" >&2
  exit 2
}
[ -x "$GEN" ] || {
  echo "generator missing or not executable at $GEN" >&2
  exit 2
}

TMP=$(mktemp -d /tmp/malt_man_sync_test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
failures=()
ok() {
  printf '  ✓ %s\n' "$1"
  pass=$((pass + 1))
}
ko() {
  printf '  ✗ %s\n' "$1" >&2
  fail=$((fail + 1))
  failures+=("$1")
}

# A fake `zig` that exits 0 without compiling: the hook builds the binary, but
# these tests pre-stage one, so a real build would only add cost and a source
# dependency without exercising the hook's own logic.
fake_zig_dir="$TMP/fakebin"
mkdir -p "$fake_zig_dir"
printf '#!/bin/sh\nexit 0\n' >"$fake_zig_dir/zig"
chmod +x "$fake_zig_dir/zig"

[ -x "$HOOK" ] || ko "hook exists and is executable at $HOOK"

# ── 1: success path ──────────────────────────────────────────────────
printf '▸ success path\n'
proj="$TMP/proj"
mkdir -p "$proj/scripts" "$proj/zig-out/bin"
cp "$GEN" "$proj/scripts/gen-man.sh"
ln -s "$BIN" "$proj/zig-out/bin/malt"
printf '9.9.9' >"$proj/.version"

if [ -x "$HOOK" ]; then
  out=$(printf '{"hook":"post-bump","version":"9.9.9","project_root":"%s"}' "$proj" |
    PATH="$fake_zig_dir:$PATH" "$HOOK") && rc=0 || rc=$?

  if [ "$rc" -eq 0 ]; then
    ok "hook exits 0 on the success path"
  else
    ko "hook exited $rc on the success path"
  fi

  if printf '%s' "$out" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    ok "hook prints success:true JSON"
  else
    ko "hook did not print success:true (got: $out)"
  fi

  page="$proj/man/malt.1"
  if [ -f "$page" ]; then
    ok "page written under project_root"
    if grep -q '9\.9\.9' "$page"; then
      ok "page .TH carries the project's .version (9.9.9)"
    else
      ko "page does not reference 9.9.9"
    fi
  else
    ko "page not written at $page"
    ko "page .TH version unverifiable (no page)"
  fi
fi

# ── 2: failure path ──────────────────────────────────────────────────
# scripts/gen-man.sh present but no binary and no .version, so generation
# fails: the hook must surface that as a non-zero exit and success:false.
printf '▸ failure path\n'
bad="$TMP/bad"
mkdir -p "$bad/scripts"
cp "$GEN" "$bad/scripts/gen-man.sh"

if [ -x "$HOOK" ]; then
  out=$(printf '{"hook":"post-bump","version":"9.9.9","project_root":"%s"}' "$bad" |
    PATH="$fake_zig_dir:$PATH" "$HOOK") && rc=0 || rc=$?

  if [ "$rc" -ne 0 ]; then
    ok "hook exits non-zero when generation fails"
  else
    ko "hook exited 0 despite a failed generation"
  fi

  if printf '%s' "$out" | grep -q '"success"[[:space:]]*:[[:space:]]*false'; then
    ok "hook prints success:false JSON on failure"
  else
    ko "hook did not print success:false (got: $out)"
  fi
fi

# ── summary ──────────────────────────────────────────────────────────
printf '\n── summary ──\npass: %d\nfail: %d\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf 'failures:\n'
  for f in "${failures[@]}"; do printf '  %s\n' "$f"; done
  exit 1
fi
