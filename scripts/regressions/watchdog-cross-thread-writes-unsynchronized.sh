#!/usr/bin/env bash
# Regression: the download watchdog runs on its own thread and must not borrow
# anything the owning thread can invalidate.
#
# The bug: watchdogFn took the live `*std.http.Client.Request` and, on a fired
# deadline, wrote stdlib's plain `Connection.closing` bool and read the socket
# handle out of the connection. The redirect-drain path deinits that request
# inside the watchdog's live scope, which both frees the connection and stamps
# the request with `undefined`, so a late fire could store into freed memory and
# hand shutdown(2) a recycled fd number. The fix hands the watchdog a dup'd fd by
# value and drops the cross-thread bool write.
#
# The guarantee is structural (no race detector is usable on this toolchain), so
# this asserts the structure, proves it compiles (a top-level comptime block in
# the same file rejects a re-borrow at build time), and runs the behavioural
# guards. Those are inline tests, which only exist in the whole-lib binary, so
# this takes about a minute rather than the usual few seconds. Running a
# per-file binary instead would be quick and would never fail.
#
# Exits 0 when the watchdog owns its fd, non-zero when it reaches back into the
# request or the connection.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

SRC="src/net/client.zig"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

[[ -f "$SRC" ]] || fail "$SRC is missing"

# 1. Signature: the watchdog borrows nothing the owner can invalidate.
SIG=$(awk '/^    fn watchdogFn\(/,/^    \) void \{/' "$SRC")
[[ -n "$SIG" ]] || fail "could not locate watchdogFn in $SRC"
if grep -q 'std\.http\.Client\.Request' <<<"$SIG"; then
  fail "watchdogFn still borrows the request across threads"
fi
if grep -q 'std\.http\.Client\.Connection' <<<"$SIG"; then
  fail "watchdogFn still borrows the connection across threads"
fi
grep -q 'sock_fd: std\.posix\.fd_t' <<<"$SIG" ||
  fail "watchdogFn lost its fd-by-value parameter"

# 2. Body: no cross-thread write to stdlib's plain bool.
BODY=$(awk '/^    fn watchdogFn\(/,/^    \}$/' "$SRC")
if grep -nE '\.closing[[:space:]]*=' <<<"$BODY"; then
  fail "watchdogFn writes conn.closing across threads (line above)"
fi

# 3. The watchdog owns the dup, so it must release it on every exit path. An fd
#    leak here is invisible in-process - any liveness check races the fd churn
#    of every other thread - so it is pinned structurally instead.
grep -q 'defer _ = std\.c\.close(sock_fd);' <<<"$BODY" ||
  fail "watchdogFn no longer closes the socket handle it owns"

# 4. The owner is what retires a killed socket now, so both watchdog'd phases
#    must still do it after joining - otherwise stdlib pools a dead connection.
for fn in receiveHeadDeadlined streamResponseBody; do
  awk -v fn="$fn" '$0 ~ "^    fn " fn "\\(", /^    \}$/' "$SRC" |
    grep -q 'retireIfFired(' ||
    fail "$fn no longer retires a connection the watchdog shut down"
done

# 5. The comptime guard that turns a re-borrow into a build error still exists.
grep -q 'watchdogFn must not borrow the request' "$SRC" ||
  fail "the comptime borrow guard was removed from $SRC"

# 6. Prove the guard compiles rather than trusting the grep: the comptime block
#    rejects a re-borrow at build time. Always rebuild - a stale binary from an
#    earlier tree would pass a guard that no longer holds. The build is
#    incremental and needs no network.
zig build test-bin >/dev/null 2>&1 ||
  fail "could not build the test binaries (zig build test-bin)"

# The behavioural guards are inline `test` blocks in src/net/client.zig, so they
# are only compiled into `lib_tests` - the per-file binaries cross an
# `addImport("malt", ...)` boundary, which drops colocated tests. Running the
# wrong binary here would pass no matter what the watchdog does at runtime.
BIN="$ROOT/zig-out/test-bin/lib_tests"
[[ -x "$BIN" ]] || fail "the inline unit test binary was not produced"

OUT=$("$BIN" 2>&1) || {
  printf '%s\n' "$OUT" >&2
  fail "the inline unit test suite failed"
}

# A silently deleted guard would leave the suite green, so require both by name.
for t in "watchdogFn: a fired deadline shuts the socket down" \
  "watchdogFn: no fire leaves the socket alone" \
  "retireIfFired: a fired watchdog retires the connection" \
  "retireIfFired: no fire leaves the connection poolable"; do
  grep -Fq "$t" <<<"$OUT" || fail "the guard test '$t' did not run"
done

echo "PASS: the watchdog owns its socket handle and writes no owning-thread state"
