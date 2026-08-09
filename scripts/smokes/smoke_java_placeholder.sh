#!/usr/bin/env bash
# scripts/smokes/smoke_java_placeholder.sh
#
# End-to-end smoke for the dependency-scoped Java placeholder. The
# `dependency-scoped-placeholder-unsubstituted` regression proves the wiring
# statically and against synthetic fixtures; this proves the contract that
# actually matters to a user — a real formula whose launcher carries the token
# resolves it to a real JDK and the JVM boots.
#
# maven is the formula the defect was found on: its `bin/mvn` wrapper is a
# shell script whose JAVA_HOME defaults to the token, so an unsubstituted one
# leaves a JAVA_HOME pointing nowhere and every invocation dies.
#
# Lives under smokes/ rather than regressions/ because it pulls openjdk — ~2 GB
# and ~30 kegs, far past the regression suite's budget. That cost is the JVM
# itself; there is no lighter formula that exercises this token.
#
# Assertions:
#   1. `mt install maven` exits 0.
#   2. The mvn wrapper's JAVA_HOME is a real path under the prefix, with no
#      `@@HOMEBREW_` token left anywhere in the tree.
#   3. `mvn -version` boots the JVM and reports the Homebrew runtime.
#   4. `mt doctor` reports no placeholder findings.
#
# Usage: scripts/smokes/smoke_java_placeholder.sh
# Requirements: built `malt` binary, network to formulae.brew.sh + ghcr.io,
# ~2 GB free in /tmp.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

# 10 bytes: an embedded path can only shrink in place, and `/usr/local` is the
# shortest string relocation rewrites.
PREFIX=$(mktemp -d /tmp/mjXXX)
CACHE=$(mktemp -d /tmp/mjcXXX)
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$CACHE"
export NO_COLOR=1
export MALT_NO_EMOJI=1
cleanup() {
  [[ "$PREFIX" == /tmp/mj* ]] && rm -rf "$PREFIX"
  [[ "$CACHE" == /tmp/mjc* ]] && rm -rf "$CACHE"
}
trap cleanup EXIT INT TERM

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

printf '\n== java placeholder smoke (prefix: %s) ==\n' "$PREFIX"

# 1. Install.
"$BIN" install maven >"$PREFIX/.install.log" 2>&1 ||
  {
    tail -20 "$PREFIX/.install.log" >&2
    fail "mt install maven exited non-zero"
  }
pass "mt install maven exited 0"

# 2. The token must be gone, and the wrapper must name a directory that exists.
if grep -rqa '@@HOMEBREW_' "$PREFIX/Cellar" 2>/dev/null; then
  grep -rlao '@@HOMEBREW_[A-Z_]*@@' "$PREFIX/Cellar" 2>/dev/null | head -5 >&2
  fail "unsubstituted placeholder token survived into the keg"
fi
pass "no @@HOMEBREW_ tokens anywhere in the prefix"

wrapper=$(echo "$PREFIX"/Cellar/maven/*/bin/mvn)
[[ -f "$wrapper" ]] || fail "mvn wrapper not found under Cellar"
# Cut at the closing brace so only the JAVA_HOME default is considered — the
# rest of the line carries a second prefix-rooted path (the real launcher).
java_home=$(grep -m1 'JAVA_HOME' "$wrapper" | cut -d'}' -f1 | grep -o "$PREFIX.*" | head -1)
[[ -n "$java_home" ]] || fail "could not read JAVA_HOME out of the mvn wrapper"
[[ -x "$java_home/bin/java" ]] ||
  fail "wrapper JAVA_HOME does not contain a java binary: $java_home"
pass "wrapper JAVA_HOME resolves to a real JDK: $java_home"

# 3. The contract a user cares about: the JVM actually starts.
out=$("$PREFIX/bin/mvn" -version 2>&1) || {
  echo "$out" >&2
  fail "mvn -version failed to run"
}
grep -q 'Apache Maven' <<<"$out" || {
  echo "$out" >&2
  fail "mvn -version produced no version banner"
}
grep -q 'Java version:' <<<"$out" || {
  echo "$out" >&2
  fail "mvn ran but the JVM never reported in"
}
pass "mvn -version booted the JVM: $(grep -m1 'Java version:' <<<"$out")"

# 4. Doctor must not report the placeholder class.
doctor_out=$("$BIN" doctor --verbose 2>&1 || true)
if grep -qa 'unpatched @@HOMEBREW_\* placeholders' <<<"$doctor_out"; then
  echo "$doctor_out" >&2
  fail "doctor reports unpatched placeholders after a clean install"
fi
pass "doctor reports no placeholder findings"

printf '\n✔ java-placeholder smoke passed\n'
