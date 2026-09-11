#!/usr/bin/env bash
# Regression: naming an installed dependency on the command line must record
# it as installed on request.
#
# The bug: the promotion gate only matched `install_reason='dependency' AND
# bin_isolated=1`. A dependency poured without `--isolate-deps` and later
# named directly (`mt install wget` then `mt install libunistring`) took the
# "already installed" fast path, so its row stayed `dependency` and `doctor`
# / `link` kept treating the user's explicit request as a leaked dependency.
#
# The slow path after promotion resolves the formula over the network, so the
# guarantee is pinned by the colocated inline tests (`lib_tests`): the gate
# and the promotion both cover a non-isolated dependency row. This script
# builds and runs only that binary: about a minute, no network.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

# The unit binary would go green vacuously if the tests were dropped or the
# isolation filter crept back into either query; fail loudly instead.
if grep -Eq "install_reason='dependency' AND bin_isolated=1" src/cli/install.zig; then
  echo "FAIL: the promotion gate still requires the dependency to be bin-isolated" >&2
  exit 1
fi
for needle in "a non-isolated dependency named directly is marked on request" \
  "the fast-path gate yields to a non-isolated dependency"; do
  if ! grep -Fq -- "$needle" src/cli/install.zig; then
    echo "FAIL: the test '$needle' is missing from src/cli/install.zig" >&2
    exit 1
  fi
done

BIN="$ROOT/zig-out/test-bin/lib_tests"
# Always rebuild so the binary reflects current source; a no-op rebuild is cheap.
if ! zig build test-bin >/dev/null 2>&1; then
  echo "FAIL: could not build the unit test binary (zig build test-bin)" >&2
  exit 1
fi

OUT=$("$BIN" 2>&1) && STATUS=0 || STATUS=$?
if [[ "$STATUS" -ne 0 ]]; then
  echo "FAIL: a named non-isolated dependency was not promoted to on request" >&2
  printf '%s\n' "$OUT" | grep -iE "failed|leaked|panic" >&2 || true
  exit 1
fi

echo "PASS: a named dependency is recorded as installed on request"
