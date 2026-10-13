#!/usr/bin/env bash
# Regression: a termination signal that lands inside the background-colour
# probe's window must not leave the user's tty in raw mode. The probe turns
# echo and canonical mode off to read the terminal's OSC 11 reply, but it only
# restored them on scope exit; a plain CLI command had no crash handler, so
# SIGTERM/SIGHUP/SIGQUIT killed it with the pty still `-echo -icanon`.
#
# script(1) with a sleep cannot target a 100 ms window, so an embedded python
# pty driver keys on the query bytes: it signals the command the moment
# `ESC ] 11 ; ?` appears, then reads the pty's termios back. A session-leader
# holder keeps the pty open after the command dies; without it macOS revokes
# the slave and tcgetattr fails.
#
# Exits 0 when the bug is absent, non-zero with a message when present.
# No network (--offline plus a throwaway MALT_PREFIX); cleans up its temp
# state; finishes in a few seconds once built.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

PREFIX=$(mktemp -d -t mt_osc11_raw.XXXXXX)
trap 'rm -rf "$PREFIX"' EXIT

DRIVER=$(
  cat <<'PY'
import fcntl, os, pty, select, signal, struct, sys, termios, time

binary, name, prefix = sys.argv[1:4]
# "ign-SIG": parent ignores SIG before exec; "tui-SIG": run the dashboard.
mode = name.split("-")[0] if name.split("-")[0] in ("ign", "tui") else "plain"
sig_name = name.split("-")[1] if mode != "plain" else name
signal.alarm(20)  # bounds a hang; the assertions then fail on missing output

m, s = pty.openpty()
if mode == "tui":  # the dashboard refuses a zero-sized terminal
    fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
r, w = os.pipe()

holder = os.fork()
if holder == 0:
    os.close(m)  # a hung case then hangs up the pty when the driver dies
    os.setsid()
    fcntl.ioctl(s, termios.TIOCSCTTY, 0)
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("MALT_")
           and k not in ("NO_COLOR", "CLICOLOR", "CLICOLOR_FORCE", "CI", "COLORFGBG")}
    env.update(MALT_PREFIX=prefix, TERM="xterm-256color", COLORTERM="truecolor")
    mt = os.fork()
    if mt == 0:
        for fd in (0, 1, 2):
            os.dup2(s, fd)
        for name_ in ("SIGTERM", "SIGHUP", "SIGQUIT"):  # undo a nohup/& parent
            signal.signal(getattr(signal, name_), signal.SIG_DFL)
        if mode == "ign":
            signal.signal(getattr(signal, "SIG" + sig_name), signal.SIG_IGN)
        argv = [binary, "tui"] if mode == "tui" else [binary, "--offline", "info", "zzz-not-a-pkg"]
        os.execve(binary, argv, env)
    os.write(w, f"{mt}\n".encode())
    _, st = os.waitpid(mt, 0)
    how = f"signal {os.WTERMSIG(st)}" if os.WIFSIGNALED(st) else f"exit {os.WEXITSTATUS(st)}"
    os.write(w, f"{how}\n".encode())
    time.sleep(60)  # keep the pty alive until the driver reads it
    os._exit(0)

rf = os.fdopen(r, "r")
mt = int(rf.readline())

seen = b""
deadline = time.time() + 5
while b"\x1b]11;?" not in seen and time.time() < deadline:
    if select.select([m], [], [], 0.05)[0]:
        try:
            seen += os.read(m, 4096)
        except OSError:
            break
query = int(b"\x1b]11;?" in seen)

if name.startswith("reply-"):
    # Feed the terminal's answer in pieces; the colour it picks shows in the
    # command's own output, which the driver returns for comparison.
    reply = {"white": b"\x1b]11;rgb:ffff/ffff/ffff\x07",
             "black": b"\x1b]11;rgb:0000/0000/0000\x07"}[name.split("-")[2]]
    pieces = [reply[:12], reply[12:]] if name.split("-")[1] == "split" else [reply]
    for piece in pieces:
        os.write(m, piece)
        time.sleep(0.03)
    out = seen.split(b"\x1b]11;?\x1b\\", 1)[-1]
    done = False
    while not done:
        done = bool(select.select([r], [], [], 0)[0])  # exited: drain once more
        while select.select([m], [], [], 0.05)[0]:
            try:
                out += os.read(m, 4096)
            except OSError:
                done = True
                break
    print(f"QUERY={query} OUT={out.hex()}", flush=True)
    os.kill(holder, signal.SIGKILL)
    sys.exit(0)

post = seen.split(b"\x1b]11;?\x1b\\", 1)[-1]
if sig_name != "none":
    os.kill(mt, getattr(signal, "SIG" + sig_name))
# Keep draining: the dashboard repaints, and a full pty buffer would block its
# crash restore (tcsetattr waits for output to drain).
drain = True
while drain:
    drain = not select.select([r], [], [], 0)[0]
    while select.select([m], [], [], 0.05)[0]:
        try:
            post += os.read(m, 4096)
        except OSError:
            drain = False
            break
status = rf.readline().strip()

lflag = termios.tcgetattr(s)[3]
print(f"QUERY={query} STATUS={status} "
      f"ECHO={int(bool(lflag & termios.ECHO))} ICANON={int(bool(lflag & termios.ICANON))} "
      f"ALTLEAVE={int(b'\x1b[?1049l' in post)}",
      flush=True)
# No waitpid: the dying session leader blocks on tty teardown while we hold
# the master, so reaping would hang. It is reparented and goes away on its own.
os.kill(holder, signal.SIGKILL)
PY
)

for sig in none TERM HUP QUIT; do
  out=$(python3 -I -c "$DRIVER" "$BIN" "$sig" "$PREFIX") ||
    fail "$sig: pty driver failed"
  [[ $out == *QUERY=1* ]] ||
    fail "$sig: probe never sent OSC 11 (colour env leaked?) ($out)"
  [[ $out == *ECHO=1*ICANON=1* ]] ||
    fail "$sig: pty left raw after the signal ($out)"
  # Death must still be BY the signal so the parent sees it (and SIGQUIT dumps).
  [[ $sig == none || $out == *"signal $(kill -l "$sig")"* ]] ||
    fail "$sig: command did not die by SIG$sig ($out)"
done

# A parent that ignores a signal must keep ignoring it: the command finishes
# on its own (exit 1) and still leaves the pty cooked.
out=$(python3 -I -c "$DRIVER" "$BIN" ign-TERM "$PREFIX") || fail "ign-TERM: pty driver failed"
[[ $out == *QUERY=1* ]] || fail "ign-TERM: probe never sent OSC 11 ($out)"
[[ $out == *"STATUS=exit 1"* ]] || fail "ign-TERM: an ignored SIGTERM killed the command ($out)"
[[ $out == *ECHO=1*ICANON=1* ]] || fail "ign-TERM: pty left raw ($out)"

# When the dashboard owns the raw terminal, the probe must not take over its
# restore: a kill during the probe still leaves the alt screen and cooks the pty.
out=$(python3 -I -c "$DRIVER" "$BIN" tui-TERM "$PREFIX") || fail "tui-TERM: pty driver failed"
[[ $out == *QUERY=1* ]] || fail "tui-TERM: dashboard never probed ($out)"
[[ $out == *ECHO=1*ICANON=1* ]] || fail "tui-TERM: pty left raw ($out)"
[[ $out == *ALTLEAVE=1* ]] || fail "tui-TERM: alt screen never left ($out)"

# A reply split across reads must resolve to the same colour as a whole one.
reply() { python3 -I -c "$DRIVER" "$BIN" "reply-$1" "$PREFIX" || fail "reply-$1: pty driver failed"; }
whole=$(reply whole-white)
split=$(reply split-white)
black=$(reply whole-black)
[[ $whole == *QUERY=1* ]] || fail "reply: probe never sent OSC 11 ($whole)"
[[ $split == "$whole" ]] || fail "a colour reply split across reads was not understood"
[[ $black != "$whole" ]] || fail "reply colour has no effect on output; the split check proves nothing"

printf 'PASS: OSC 11 probe restores the tty on TERM/HUP/QUIT and reads split replies\n'
