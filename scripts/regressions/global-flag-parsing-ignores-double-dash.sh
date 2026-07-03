#!/usr/bin/env bash
# Regression: tokens after the POSIX `--` end-of-options separator must reach
# the child binary verbatim and must not flip malt's own output mode.
#
# The bug: the pre-dispatch global-flag loop in main() walked the whole argv
# with no `--` boundary, so a global-looking flag after `--` (e.g. --json,
# --dry-run) was consumed there — stripped from the subcommand's argv and
# mutating malt's process-wide output state. `mt run <pkg> -- <args…>` lost
# the child's flags and silently switched malt into JSON mode.
#
# Exercised fully offline via the installed path in run.execute: when
# {MALT_PREFIX}/bin/<pkg> exists, run execs it directly and never hits the
# network. Exits 0 when the child received the post-`--` flags verbatim,
# non-zero (with expected-vs-actual argv) when they were stripped.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
# The shell harness runs the built binary, which `zig build test` does not
# rebuild — build it here so a stale binary never masks the fix.
zig build >/dev/null

prefix="$(mktemp -d)"
trap 'rm -rf "$prefix"' EXIT

# Stub "child" that echoes exactly the argv it was handed.
mkdir -p "$prefix/bin"
cat >"$prefix/bin/echoargs" <<'EOF'
#!/usr/bin/env bash
printf 'ARGV:%s\n' "$*"
EOF
chmod +x "$prefix/bin/echoargs"

# --offline is consumed by a separate inline branch in main (not the flag
# map), so include it to guard that branch's boundary too.
expected='ARGV:--json --offline --dry-run'
out="$(MALT_PREFIX="$prefix" "$BIN" run echoargs -- --json --offline --dry-run 2>/dev/null)"
if ! grep -q "$expected" <<<"$out"; then
  echo "FAIL: post-'--' args stripped before child" >&2
  echo "  expected: $expected" >&2
  echo "  actual:   $out" >&2
  exit 1
fi

echo "ok: run pass-through preserves post-'--' global-looking flags"
