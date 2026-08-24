#!/usr/bin/env bash
# Regression: malt recognises ca-certificates' post-install script by the hash
# of its contents and then builds the trust bundle natively instead of spawning
# it. Recognising the script says nothing about the arguments it was handed,
# and any formula - including a third-party tap - can name that script by
# absolute path, because it lives under the prefix and so passes the argv0
# check. The spawned script was confined by sandbox-exec; running the work
# in-process is not, so a formula could once hand it a source and destination
# anywhere the user can read and write.
#
# This drives the real step executor with a hostile formula: a synthetic keg
# whose libexec holds a byte-identical copy of the recognised script, invoked
# with a destination outside the prefix. The destination must not appear.
#
# Needs the ca-certificates keg for the genuine script bytes, so it installs
# into a throwaway prefix. Never point MALT_PREFIX at a real install.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/mt}"
[[ -x "$BIN" ]] || {
  echo "FAIL: $BIN not built - run 'zig build' first" >&2
  exit 1
}

if [[ -z "${MALT_GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  MALT_GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
  export MALT_GITHUB_TOKEN
fi

TMP=$(mktemp -d)
# Unique per run: concurrent runs sharing a fixed prefix or harness path wipe
# each other's fixtures mid-compile.
PREFIX=$(mktemp -d -t mt_cabc)
HARNESS="$ROOT/.native-ca-bundle-confinement-$$.zig"
LOOT="$TMP/loot.pem"
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export NO_COLOR=1 MALT_NO_EMOJI=1
trap 'rm -rf "$PREFIX" "$TMP" "$HARNESS"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

"$BIN" install ca-certificates >"$TMP/install.log" 2>&1 ||
  fail "installing ca-certificates: $(tail -3 "$TMP/install.log")"

KEG=$(echo "$PREFIX"/Cellar/ca-certificates/*)
SCRIPT="$KEG/libexec/post-install"
SOURCE="$KEG/share/ca-certificates/cacert.pem"
[[ -f "$SCRIPT" && -f "$SOURCE" ]] || fail "keg is missing the post-install script or its source bundle"

# A hostile keg carrying the recognised script verbatim, so the digest matches.
EVIL="$PREFIX/Cellar/evil/1.0"
mkdir -p "$EVIL/libexec"
cp "$SCRIPT" "$EVIL/libexec/post-install"

# A source that looks like it lives in the keg but resolves outside it. The
# path check is lexical, so only resolving it catches this.
OUTSIDE="$TMP/outside.pem"
cp "$SOURCE" "$OUTSIDE"
ln -s "$OUTSIDE" "$EVIL/libexec/smuggled.pem"

cat >"$HARNESS" <<ZIG
const std = @import("std");
const malt = @import("malt");
const steps = malt.post_install_steps;

test "a formula cannot aim the native trust-store builder outside the prefix" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var flog = steps.FallbackLog.init(std.testing.allocator);
    defer flog.deinit();

    const ctx: steps.StepsCtx = .{
        .io = io,
        .allocator = a,
        .name = "evil",
        .version = "1.0",
        .prefix = "$PREFIX",
        .keg_path = "$EVIL",
        .flog = &flog,
    };

    const formula =
        \\\\{"name":"evil","versions":{"stable":"1.0"},"post_install_steps":
        \\\\[{"type":"run","command":{"base":"absolute","path":"$EVIL/libexec/post-install"},
        \\\\  "args":["$SOURCE","$LOOT"]}]}
    ;
    _ = steps.execute(ctx, formula);
}

test "a source symlinked out of the keg is refused by the native path" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var flog = steps.FallbackLog.init(std.testing.allocator);
    defer flog.deinit();

    const ctx: steps.StepsCtx = .{
        .io = io,
        .allocator = arena.allocator(),
        .name = "evil",
        .version = "1.0",
        .prefix = "$PREFIX",
        .keg_path = "$EVIL",
        .flog = &flog,
    };

    // Destination inside the keg, so only the source is in question. The path
    // sits under the keg but resolves outside it.
    const formula =
        \\\\{"name":"evil","versions":{"stable":"1.0"},"post_install_steps":
        \\\\[{"type":"run","command":{"base":"absolute","path":"$EVIL/libexec/post-install"},
        \\\\  "args":["$EVIL/libexec/smuggled.pem","$EVIL/etc/out.pem"]}]}
    ;
    _ = steps.execute(ctx, formula);

    for (flog.notes()) |n| {
        if (std.mem.indexOf(u8, n, "native trust-store build declined") != null) return;
    }
    return error.SymlinkedSourceWasNotRefused;
}
ZIG

zig translate-c -I "$ROOT/vendor/" "$ROOT/c/sqlite.h" >"$TMP/c_sqlite.zig" 2>/dev/null
zig translate-c "$ROOT/c/clonefile.h" >"$TMP/c_clonefile.zig" 2>/dev/null
zig translate-c "$ROOT/c/mount.h" >"$TMP/c_mount.zig" 2>/dev/null

(cd "$ROOT" && zig test -OReleaseSafe \
  --dep malt -Mroot="$HARNESS" \
  --dep c_sqlite --dep c_clonefile --dep c_mount \
  -Mmalt="$ROOT/src/lib.zig" -lc -I "$ROOT/vendor/" -I "$ROOT/c/" \
  -cflags -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0 -- "$ROOT/vendor/sqlite3.c" \
  -Mc_sqlite="$TMP/c_sqlite.zig" \
  -Mc_clonefile="$TMP/c_clonefile.zig" \
  -Mc_mount="$TMP/c_mount.zig") >"$TMP/harness.log" 2>&1 ||
  fail "harness did not run: $(tail -5 "$TMP/harness.log")"

# The step is allowed to fail, be downgraded, or fall through to the fenced
# spawn - any of those is fine. What must not happen is the file appearing.
if [[ -e "$LOOT" ]]; then
  echo "  wrote $(wc -c <"$LOOT") bytes to $LOOT, outside the prefix" >&2
  fail "the native trust-store builder honoured a formula-supplied path outside the prefix"
fi

echo "PASS: formula-supplied paths cannot steer the native trust-store builder out of the prefix"
