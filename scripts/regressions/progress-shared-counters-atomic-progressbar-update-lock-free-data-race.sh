#!/usr/bin/env bash
# Regression: ProgressBar's cross-thread counters must be atomic. update()
# stores the byte count and render() bumps the spinner frame from the owning
# worker, while a sibling worker holding the group mutex repaints every bar
# on a resize tick and reads those same fields — a lock-free write racing a
# locked read is a data race even when the torn value is never visible.
#
# ThreadSanitizer cannot be the oracle here (a -fsanitize-thread hello-world
# segfaults on the target toolchain), so the synchronization discipline is
# pinned structurally at compile time, plus a two-thread smoke run that must
# survive a resize-repaint storm. The driver reaches progress.zig through the
# `malt` module root: rooting a module at src/ui/progress.zig stops resolving
# as soon as anything under src/ui/ imports a sibling outside it, which is how
# this guard silently stopped compiling. No network.
#
# Exits 0 when the counters are atomic and the storm run is clean; non-zero
# with a clear message otherwise.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/driver.zig" <<'ZIG'
const std = @import("std");
const progress = @import("malt").progress;

comptime {
    // The group mutex only guards draws; the counters cross threads on their own.
    if (@FieldType(progress.ProgressBar, "current") != std.atomic.Value(u64))
        @compileError("ProgressBar.current must be atomic: update() races repaintIfResized()");
    if (@FieldType(progress.ProgressBar, "spinner_frame") != std.atomic.Value(u8))
        @compileError("ProgressBar.spinner_frame must be atomic: render() races sibling repaints");
}

var stop = std.atomic.Value(bool).init(false);

fn hammer(bar: *progress.ProgressBar) void {
    var i: u64 = 0;
    while (!stop.load(.acquire)) : (i += 1) bar.update(i);
}

fn repainter(bar: *progress.ProgressBar) void {
    var j: u64 = 0;
    while (!stop.load(.acquire)) : (j += 1) {
        bar.last_render_ns = 0; // defeat the 10 Hz gate: render every call
        std.posix.raise(std.posix.SIG.WINCH) catch {};
        bar.update(j); // render -> mutex -> repaintIfResized reads the sibling
    }
}

pub fn main() !void {
    var t: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer t.deinit();
    progress.setRuntime(t.io(), std.Io.File.stderr());
    progress.setSupportsAnsiForTest(true);
    progress.setMode(.tty);
    progress.setColsForTest(80);

    var mp = progress.MultiProgress.init(2); // arms the WINCH flag handler
    var bars: [2]progress.ProgressBar = undefined;
    for (&bars, 0..) |*b, idx| {
        b.* = progress.ProgressBar.init("pkg", 1_000_000);
        b.line_index = @intCast(idx);
        b.multi = &mp;
    }
    mp.bars = &bars;

    const a = try std.Thread.spawn(.{}, hammer, .{&bars[0]});
    const b = try std.Thread.spawn(.{}, repainter, .{&bars[1]});
    std.Io.sleep(t.io(), std.Io.Duration.fromNanoseconds(2 * std.time.ns_per_s), .awake) catch {};
    stop.store(true, .release);
    a.join();
    b.join();
    mp.finish();
}
ZIG

zig translate-c -I "$ROOT/vendor/" "$ROOT/c/sqlite.h" >"$TMP/c_sqlite.zig" 2>/dev/null
zig translate-c "$ROOT/c/clonefile.h" >"$TMP/c_clonefile.zig" 2>/dev/null
zig translate-c "$ROOT/c/mount.h" >"$TMP/c_mount.zig" 2>/dev/null

# ca_bundle.zig evaluates trust in-process; the module graph needs the same
# frameworks build.zig links.
if ! zig build-exe -femit-bin="$TMP/driver" -lc \
  -I "$ROOT/vendor/" -I "$ROOT/c/" \
  -framework Security -framework CoreFoundation \
  --dep malt -Mmain="$TMP/driver.zig" \
  --dep c_sqlite --dep c_clonefile --dep c_mount \
  -Mmalt="$ROOT/src/lib.zig" \
  -cflags -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_THREADSAFE=1 -DSQLITE_DQS=0 -- "$ROOT/vendor/sqlite3.c" \
  -Mc_sqlite="$TMP/c_sqlite.zig" \
  -Mc_clonefile="$TMP/c_clonefile.zig" \
  -Mc_mount="$TMP/c_mount.zig" 2>"$TMP/build_err.txt"; then
  if grep -q "must be atomic" "$TMP/build_err.txt"; then
    echo "FAIL: shared progress counters are not atomic" >&2
  else
    echo "FAIL: driver build error" >&2
    cat "$TMP/build_err.txt" >&2
  fi
  exit 1
fi

timeout 20 "$TMP/driver" 2>/dev/null ||
  {
    echo "FAIL: concurrent update + resize repaint crashed or hung" >&2
    exit 1
  }
echo "OK: shared progress counters are atomic and repaint-safe"
