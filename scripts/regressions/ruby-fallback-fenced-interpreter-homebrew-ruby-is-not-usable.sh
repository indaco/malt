#!/usr/bin/env bash
# Regression: the Ruby fence denies `file-read-data` under every package-manager
# prefix, but `detectRuby` prefers exactly those interpreters. A Homebrew Ruby
# links its `libruby` dylib from `<prefix>/Cellar`, so under the fence dyld
# aborts before Ruby runs a line and every post-install fallback fails on a box
# with Homebrew Ruby installed. The system Ruby loads from a framework tree
# that is never denied, which is why the gap stayed invisible elsewhere.
#
# A standalone `zig test` harness drives the real `runRubySandboxed` with the
# package-manager Ruby and a script that records its version inside the keg.
# The interpreter must start and the file must appear. Skips loudly when no
# package-manager Ruby is present. No network, no prefix writes, under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)

RUBY=""
for c in /opt/homebrew/opt/ruby/bin/ruby /usr/local/opt/ruby/bin/ruby; do
  [[ -x "$c" ]] && {
    RUBY="$c"
    break
  }
done
[[ -n "$RUBY" ]] || {
  echo "SKIP: no package-manager Ruby on this box"
  exit 0
}

TMP=$(mktemp -d)
# Unique per run: concurrent runs sharing a harness path wipe each other's
# fixtures mid-compile.
HARNESS="$ROOT/.ruby-fence-interpreter-$$.zig"
trap 'rm -rf "$TMP" "$HARNESS"' EXIT

PREFIX="$TMP/prefix"
KEG="$PREFIX/Cellar/probe/1.0"
mkdir -p "$KEG"
printf 'File.write("%s/version", RUBY_VERSION)\n' "$KEG" >"$TMP/probe.rb"

cat >"$HARNESS" <<ZIG
const std = @import("std");
const sandbox = @import("src/core/sandbox/macos.zig");

test "a package-manager Ruby starts inside the fence" {
    const env: sandbox.ScrubbedEnv = .{
        .home = "$TMP",
        .path = sandbox.sandbox_path,
        .malt_prefix = "$PREFIX",
        .tmpdir = "$TMP",
    };
    const code = try sandbox.runRubySandboxed(
        std.testing.allocator,
        .empty,
        "$RUBY",
        "$TMP/probe.rb",
        "$KEG",
        "$PREFIX",
        env,
        .{},
        .{},
    );
    if (code != 0) {
        std.debug.print("fenced $RUBY exited {d}\n", .{code});
        return error.FencedInterpreterDidNotStart;
    }
}
ZIG

run_harness() {
  (cd "$ROOT" && zig test -lc "$HARNESS")
}

if ! run_harness >"$TMP/harness.log" 2>&1; then
  grep -Ev '\.\.\.OK$' "$TMP/harness.log" | tail -20 >&2
  echo "FAIL: the fenced $RUBY did not start" >&2
  exit 1
fi

GOT=""
[[ -f "$KEG/version" ]] && GOT=$(<"$KEG/version")
[[ "$GOT" =~ ^[0-9]+\.[0-9]+ ]] || {
  echo "FAIL: fenced $RUBY ran but recorded no version (got '$GOT')" >&2
  exit 1
}

echo "PASS: the fenced $RUBY runs ($GOT)"
