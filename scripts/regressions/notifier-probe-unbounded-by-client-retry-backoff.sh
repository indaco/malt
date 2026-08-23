#!/usr/bin/env bash
# Regression: the passive version probe must not inherit the client's retry
# schedule.
#
# The bug: the probe's timeout knobs bound a single attempt. A transient
# failure - a 5xx, a reset, a timeout - bought four attempts plus seven
# seconds of backoff on top, so a GitHub brownout held *every* command for
# around 13 seconds while the probe advertised a 1.5 s bound.
#
# The fix gives the probe a no-retry budget alongside the per-phase deadlines.
# That is the notifier's choice, not a new client default: an install losing
# its retries would be a worse regression than the latency this fixes, so the
# stock schedule is asserted here too.
#
# The fixture is a loopback TLS endpoint answering 503 to everything. TLS
# rather than cleartext because the probe's endpoint is https and the
# handshake is the phase that costs; a self-signed cert plus a trust store
# scoped to the test keeps it hermetic. Judged through the integration test
# binary: the probe's URL is a hardcoded constant, so the real binary cannot
# be pointed at a fixture without a seam that would also redirect self-update.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

NOTIFIER="src/update/notifier.zig"
TESTS="tests/notifier_probe_budget_test.zig"
BIN="$ROOT/zig-out/test-bin/notifier_probe_budget_test"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# A dropped guard or a dropped fixture would let the binary go green vacuously.
grep -Fqs -- "applyProbeBudget(&http)" "$NOTIFIER" || fail "the probe no longer applies its budget"
grep -Fqs -- "retry_backoff_ms" "$NOTIFIER" || fail "the probe's retry budget is gone"
grep -Fqs -- "MALT_TEST_PROBE_CA" "$TESTS" || fail "the https fixture wiring is gone"

command -v openssl >/dev/null 2>&1 || fail "openssl is required to mint the fixture cert"
command -v python3 >/dev/null 2>&1 || fail "python3 is required to serve the fixture"

# Always rebuild: a prebuilt binary could predate the fix, and zig 0.16 has no
# --test-filter to narrow this down.
zig build test-bin >/dev/null 2>&1 || fail "could not build the test binaries"

WORK=$(mktemp -d -t probe-budget)
SERVER_PID=""
cleanup() {
  # `[[ ... ]] && kill` as a bare statement aborts the trap under `errexit`
  # when the server is already gone, stranding the key in $WORK.
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# P-256 and a DNS SAN: the client verifies host names against DNS entries, and
# an IP SAN never satisfies that.
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 1 \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost" \
  >/dev/null 2>&1 || fail "could not mint the fixture certificate"

LOG_FILE="$WORK/requests"
: >"$LOG_FILE"

# A loopback TLS endpoint that answers 503 to everything, prints its port once
# bound, and appends each request's path so attempts can be counted per walk.
cat >"$WORK/fixture.py" <<'FIXTURE'
import http.server
import os
import ssl
import sys

log_path = os.environ["REQUEST_LOG_FILE"]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        with open(log_path, "a") as f:
            f.write("%s\n" % self.path)
        body = b"busy"
        self.send_response(503)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile=sys.argv[1], keyfile=sys.argv[2])
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
server.socket = ctx.wrap_socket(server.socket, server_side=True)
print(server.server_address[1], flush=True)
server.serve_forever()
FIXTURE

REQUEST_LOG_FILE="$LOG_FILE" python3 "$WORK/fixture.py" "$WORK/cert.pem" "$WORK/key.pem" \
  >"$WORK/port" 2>"$WORK/server.err" &
SERVER_PID=$!

# Bound the wait: a fixture that never binds must fail, not hang.
for _ in $(seq 1 50); do
  [[ -s "$WORK/port" ]] && break
  sleep 0.1
done
PORT=$(cat "$WORK/port" 2>/dev/null || true)
[[ -n "$PORT" ]] || fail "the fixture never bound a port: $(tail -3 "$WORK/server.err")"

MALT_TEST_PROBE_PORT="$PORT" MALT_TEST_PROBE_CA="$WORK/cert.pem" \
  timeout 60 "$BIN" >"$WORK/out" 2>&1 || fail "the probe walk failed: $(tail -5 "$WORK/out")"

grep -Fqs "All 2 tests passed" "$WORK/out" || fail "the fixture was not exercised: $(tail -5 "$WORK/out")"

# Counted per walk, so the assertion does not move when a test is added.
PROBE=$(grep -c '^/releases/latest$' "$LOG_FILE" || true)
[[ "$PROBE" -eq 1 ]] || fail "the probe made ${PROBE} attempts, expected 1 - it inherited the retry schedule"

# The stock schedule is three retries on top of the first attempt. Asserted
# against the same endpoint so a client-wide loss of retries fails here too.
RETRIED=$(grep -c '^/retried$' "$LOG_FILE" || true)
[[ "$RETRIED" -eq 4 ]] || fail "a retrying walk made ${RETRIED} attempts, expected 4"

echo "PASS: the version probe spends one attempt on a failing endpoint"
