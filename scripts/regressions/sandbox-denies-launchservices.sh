#!/usr/bin/env bash
# Regression: the Ruby fence used to grant every Mach service, so a
# `--use-system-ruby` post_install could talk to any daemon that does work on
# its behalf (read the clipboard, ask LaunchServices to open an app) even
# though the profile has no file or network hole. The profile now denies
# mach-lookup and allowlists only the platform services Ruby and codesign need.
#
# A standalone `zig test` harness drives the real `runRubySandboxed` with the
# system Ruby: `open -a` and `osascript … activate` must fail and leave no
# Calculator behind, and `pbpaste` (the pasteboard server, reachable only via
# Mach) must not read the clipboard; `Dir.tmpdir`, `Etc.getpwuid` and
# `codesign --verify` must still work so the allowlist is not too tight.
# No network, no prefix writes, under 60s.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
RUBY=/usr/bin/ruby
[[ -x "$RUBY" ]] || {
  echo "SKIP: no system Ruby on this box"
  exit 0
}

TMP=$(mktemp -d)
# Unique per run: concurrent runs sharing a harness path wipe each other's
# fixtures mid-compile.
HARNESS="$ROOT/.sandbox-mach-lookup-$$.zig"
trap 'rm -rf "$TMP" "$HARNESS"' EXIT

PREFIX="$TMP/prefix"
KEG="$PREFIX/Cellar/probe/1.0"
mkdir -p "$KEG"

cat >"$TMP/open.rb" <<'RB'
exit(system("/usr/bin/open", "-a", "Calculator") ? 0 : 1)
RB
cat >"$TMP/osascript.rb" <<'RB'
exit(system("/usr/bin/osascript", "-e", 'tell app "Finder" to activate') ? 0 : 1)
RB
cat >"$TMP/pbpaste.rb" <<'RB'
exit(system("/usr/bin/pbpaste", out: File::NULL, err: File::NULL) ? 0 : 1)
RB
cat >"$TMP/allowed.rb" <<'RB'
require "etc"
require "tmpdir"
Etc.systmpdir
Dir.tmpdir
Etc.getpwuid(Process.uid).name
exit 1 unless system("/usr/bin/codesign", "--verify", "--strict", "/bin/ls", out: File::NULL, err: File::NULL)
RB

CALC_BEFORE=0
pgrep -x Calculator >/dev/null && CALC_BEFORE=1

cat >"$HARNESS" <<ZIG
const std = @import("std");
const sandbox = @import("src/core/sandbox/macos.zig");

fn run(script: []const u8) !u8 {
    const env: sandbox.ScrubbedEnv = .{
        .home = "$TMP",
        .path = sandbox.sandbox_path,
        .malt_prefix = "$PREFIX",
        .tmpdir = "$TMP",
    };
    return sandbox.runRubySandboxed(
        std.testing.allocator,
        .empty,
        "$RUBY",
        script,
        "$KEG",
        "$PREFIX",
        env,
        .{},
        .{},
    );
}

test "the fence refuses to open an application through LaunchServices" {
    if (try run("$TMP/open.rb") == 0) return error.OpenEscapedTheFence;
}

test "the fence refuses to drive another application through AppleScript" {
    if (try run("$TMP/osascript.rb") == 0) return error.OsascriptEscapedTheFence;
}

test "the fence keeps the clipboard out of reach" {
    if (try run("$TMP/pbpaste.rb") == 0) return error.PasteboardReachable;
}

test "the fence still serves tmpdir, passwd and codesign" {
    if (try run("$TMP/allowed.rb") != 0) return error.AllowlistTooTight;
}
ZIG

run_harness() {
  (cd "$ROOT" && zig test -lc "$HARNESS")
}

if ! run_harness >"$TMP/harness.log" 2>&1; then
  grep -Ev '\.\.\.OK$' "$TMP/harness.log" | tail -20 >&2
  echo "FAIL: mach-lookup fence probes did not behave as expected" >&2
  exit 1
fi

if [[ "$CALC_BEFORE" == 0 ]] && pgrep -x Calculator >/dev/null; then
  pkill -x Calculator || true
  echo "FAIL: Calculator was launched from inside the fence" >&2
  exit 1
fi

echo "PASS: the fence denies LaunchServices and still serves tmpdir/passwd/codesign"
