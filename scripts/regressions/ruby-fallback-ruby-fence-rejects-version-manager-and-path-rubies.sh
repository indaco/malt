#!/usr/bin/env bash
# Regression: `detectRuby` used to fall through to rbenv/asdf shims under
# `$HOME` and then to the first `ruby` on `$PATH`, but the fence denies
# `file-read-data` under every root those interpreters live in and scrubs
# `$PATH` to the system dirs. A shim cannot even be read; a PATH Ruby aborts in
# dyld on its first dylib. Both ends of the pipeline must agree on what a
# usable Ruby is, so detection stops at the interpreters the fence can run.
#
# Two assertions: (a) `detect.zig` no longer consults `HOME` or `PATH`; (b) the
# Ruby detected on this box actually starts inside the real `runRubySandboxed`
# and records its version in the keg. No Ruby at all is a
# FAIL, not a skip: every macOS ships `/usr/bin/ruby`. No network, no prefix
# writes, under 30s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DETECT="$ROOT/src/core/ruby/detect.zig"

if rg -n '"HOME"|"PATH"|rbenv|asdf' "$DETECT"; then
  echo "FAIL: detectRuby probes HOME/PATH again; the fence cannot run those Rubies" >&2
  exit 1
fi

TMP=$(mktemp -d)
# Unique per run: concurrent runs sharing a harness path wipe each other's
# fixtures mid-compile.
HARNESS="$ROOT/.ruby-fence-detect-$$.zig"
trap 'rm -rf "$TMP" "$HARNESS"' EXIT

PREFIX="$TMP/prefix"
KEG="$PREFIX/Cellar/probe/1.0"
mkdir -p "$KEG"
printf 'File.write("%s/version", RUBY_VERSION)\n' "$KEG" >"$TMP/probe.rb"

cat >"$HARNESS" <<ZIG
const std = @import("std");
const detect = @import("src/core/ruby/detect.zig");
const sandbox = @import("src/core/sandbox/macos.zig");

test "the detected Ruby starts inside the fence" {
    const ruby = detect.detectRuby(std.Options.debug_io, std.testing.allocator) orelse
        return error.NoRubyDetected;
    defer std.testing.allocator.free(ruby);
    std.debug.print("DETECTED {s}\n", .{ruby});
    const env: sandbox.ScrubbedEnv = .{
        .home = "$TMP",
        .path = sandbox.sandbox_path,
        .malt_prefix = "$PREFIX",
        .tmpdir = "$TMP",
    };
    const code = try sandbox.runRubySandboxed(
        std.testing.allocator,
        .empty,
        ruby,
        "$TMP/probe.rb",
        "$KEG",
        "$PREFIX",
        env,
        .{},
        .{},
    );
    if (code != 0) {
        std.debug.print("fenced {s} exited {d}\n", .{ ruby, code });
        return error.FencedInterpreterDidNotStart;
    }
}
ZIG

run_harness() {
  (cd "$ROOT" && zig test -lc "$HARNESS")
}

if ! run_harness >"$TMP/harness.log" 2>&1; then
  grep -Ev '\.\.\.OK$' "$TMP/harness.log" | tail -20 >&2
  echo "FAIL: the detected Ruby does not start inside the fence" >&2
  exit 1
fi

RUBY=$(grep -o "DETECTED [^[:space:]]*" "$TMP/harness.log" | head -1 | cut -d" " -f2 || true)
GOT=""
[[ -f "$KEG/version" ]] && GOT=$(<"$KEG/version")
[[ "$GOT" =~ ^[0-9]+\.[0-9]+ ]] || {
  echo "FAIL: fenced $RUBY ran but recorded no version (got '$GOT')" >&2
  exit 1
}

echo "PASS: detected $RUBY and it runs fenced ($GOT)"
