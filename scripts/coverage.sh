#!/usr/bin/env bash
#
# Run unit tests under kcov, print line-coverage percentage, and write the
# Codecov report to .github/codecov.json for CI to upload (commit to refresh).
#
# HTML report lands at coverage/merged/kcov-merged/index.html.
# Requires kcov (brew install kcov).

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v kcov >/dev/null 2>&1; then
  echo "error: kcov not found. Install with: brew install kcov" >&2
  exit 1
fi

rm -rf coverage
mkdir -p coverage
zig build test-bin

# Only report coverage for files under the project's src/ directory.
# --include-path takes an absolute path and is more reliable than --include-pattern.
src_dir="$(pwd)/src"

# Run kcov once per test binary into a shared outdir.
# Tests like purge_json's `confirmTyped` branch detect TTY stdin and would
# block on `read(STDIN_FILENO)` when kcov inherits the user's terminal.
# Redirecting from /dev/null forces isTty()=false so those paths take the
# unattended-abort branch the tests are written against.
#
# kcov's Mach-port instrumentation collides with sandbox-exec / posix_spawn
# children on macOS (vm_write / thread_get_state failures), turning a
# coverage run into an unbounded hang on tests that actually fork. The
# affected tests gate on `MALT_SKIP_SUBPROCESS_TESTS` and stay live under
# `zig build test`; only this loop opts out of them.
export MALT_SKIP_SUBPROCESS_TESTS=1
for bin in zig-out/test-bin/*; do
  # Skip .dSYM debug bundles and any non-regular files
  [ -f "$bin" ] || continue
  [ -x "$bin" ] || continue
  echo "→ kcov: $(basename "$bin")"
  kcov --include-path="$src_dir" coverage "$bin" </dev/null >/dev/null
done

# kcov 43 on macOS doesn't reliably auto-merge, so do it explicitly.
# The per-binary reports are in hash-suffixed dirs (e.g. cellar_test.a934ecd0).
# Match both `*_test.*` (the per-tests/ binaries) and `lib_tests.*` so the
# inline `test` blocks compiled into the lib_tests root contribute to the
# merged report — without this, inline coverage was silently dropped.
shopt -s nullglob
per_bin_dirs=(coverage/*_test.* coverage/lib_tests.*)
shopt -u nullglob
if [ ${#per_bin_dirs[@]} -eq 0 ]; then
  echo "error: kcov produced no per-binary reports" >&2
  exit 1
fi
kcov --merge coverage/merged "${per_bin_dirs[@]}" >/dev/null

report="coverage/merged/kcov-merged/coverage.json"
if [ ! -f "$report" ]; then
  echo "error: merged report not found at $report" >&2
  exit 1
fi

# Commit kcov's native Codecov report so CI uploads it without running kcov
# (which is flaky on macOS CI runners). Regenerate + commit to refresh.
cp coverage/merged/kcov-merged/codecov.json .github/codecov.json

if command -v jq >/dev/null 2>&1; then
  percent=$(jq -r '.percent_covered' "$report")
else
  percent=$(grep -oE '"percent_covered"[^,}]*' "$report" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
fi

echo ""
echo "Coverage: ${percent}%"
echo "Report:   coverage/merged/kcov-merged/index.html"
