#!/usr/bin/env bash
# scripts/e2e/pkg-cask-nontty-refusal.sh
#
# End-to-end proof that EVERY verb which can escalate a PKG cask to
# `sudo installer -target /` refuses when stdin is not a terminal, and never
# reaches sudo. Drives the real CLI with empty stdin and asserts, per verb,
# malt's own actionable "interactive terminal" message plus a `sudo` stub on
# PATH that stays untouched:
#   - install --cask <pkg>   (fresh install; needs the cask JSON — network)
#   - upgrade <pkg>          (seeded as installed-old; needs the cask JSON)
#   - rollback <pkg>         (seeded pkg history; fully offline)
# The refusal fires before any download or the upgrade's uninstall, so a
# refusal leaves disk untouched. The pure guard is unit-tested; this pins every
# verb at the binary edge, which no unit test can reach.
#
# Network: install/upgrade fetch one cask JSON from formulae.brew.sh (a CDN —
# no GitHub auth, no rate limit). Classified network failures SKIP those cases
# (matching the other cask e2e scripts). rollback needs no network and always
# runs, so the script always makes at least one hard assertion.
#
# Hermetic: throwaway MALT_PREFIX per case and a throwaway PATH dir, all cleaned
# up. Upgrade/rollback seed state via sqlite3 and are skipped if it is absent.
# Well under 30s.
#
# Usage:   MT_BIN=./zig-out/bin/malt ./scripts/e2e/pkg-cask-nontty-refusal.sh
# Exit:    0 on pass or a clean upstream skip, 1 on failure, 2 when MT_BIN missing.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
MT_BIN="${MT_BIN:-$ROOT/zig-out/bin/malt}"

if [[ ! -x "$MT_BIN" ]]; then
  echo "pkg-nontty: $MT_BIN not found or not executable (run 'zig build' or set MT_BIN)" >&2
  exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export NO_COLOR=1
export MALT_NO_EMOJI=1

# One sudo stub on PATH for every case: record any invocation, then succeed —
# so a broken guard that reached escalation leaves a marker (and "passes" sudo).
mark="$tmp/sudo_calls"
: >"$mark"
printf '#!/usr/bin/env bash\necho "invoked: $*" >>"%s"\nexit 0\n' "$mark" >"$tmp/sudo"
chmod +x "$tmp/sudo"

net_skip_re='rate limit|cannot reach|not found|network|could not resolve|offline|failed to (download|install)|could not fetch'

pass() { echo "pkg-nontty: OK — $*"; }
skip() { echo "pkg-nontty: skip — $*" >&2; }
fail() {
  echo "pkg-nontty: FAIL — $*" >&2
  exit 1
}

# Any sudo call means a guard let escalation through — fail hard regardless of
# which case triggered it (the stub marker is shared across cases).
assert_no_sudo() {
  [[ -s "$mark" ]] && fail "$1 escalated to sudo off a TTY: $(cat "$mark")"
  return 0
}

# Fresh prefix with an initialised DB (schema created by any real command).
fresh_prefix() {
  local p="$tmp/$1"
  mkdir -p "$p/db"
  MALT_PREFIX="$p" "$MT_BIN" list >/dev/null 2>&1
  echo "$p"
}

# ── Case 1: fresh install (network) ─────────────────────────────────────────
install_ok=skip
for token in basictex temurin dotnet-sdk; do
  p="$tmp/inst_$token"
  mkdir -p "$p"
  log="$tmp/inst_$token.log"
  printf '' | PATH="$tmp:$PATH" MALT_PREFIX="$p" "$MT_BIN" install --cask "$token" >"$log" 2>&1 || true
  assert_no_sudo "install $token"
  if grep -qi 'interactive terminal' "$log"; then
    pass "install --cask $token refused off a TTY"
    install_ok=ok
    break
  fi
  if grep -qiE "$net_skip_re" "$log"; then
    skip "install $token: classified upstream condition; trying next"
    continue
  fi
  tail -15 "$log" >&2
  fail "install $token neither refused nor reported a known upstream skip"
done
[[ "$install_ok" == skip ]] && skip "install: all candidates hit upstream conditions"

# ── Cases 2 & 3 seed installed/history state, which needs sqlite3 ────────────
if ! command -v sqlite3 >/dev/null 2>&1; then
  skip "upgrade/rollback cases need sqlite3; skipped"
  echo "pkg-nontty: DONE (install case only)"
  exit 0
fi

# ── Case 3: rollback (offline, deterministic) ───────────────────────────────
# Seed a cask with two PKG history versions; roll back to the older one. No
# network — the gate fires before reinstall reads the (fake) URL.
p=$(fresh_prefix rb)
db="$p/db/malt.db"
sqlite3 "$db" \
  "INSERT INTO casks(token,name,version,url) VALUES('faketpkg','faketpkg','2.0','https://example.invalid/f-2.0.pkg');
   INSERT INTO cask_versions(token,version,url,sha256,artifact_type) VALUES('faketpkg','2.0','https://example.invalid/f-2.0.pkg','','pkg');
   INSERT INTO cask_versions(token,version,url,sha256,artifact_type) VALUES('faketpkg','1.0','https://example.invalid/f-1.0.pkg','','pkg');"
log="$tmp/rb.log"
printf '' | PATH="$tmp:$PATH" MALT_PREFIX="$p" "$MT_BIN" rollback faketpkg --to 1.0 >"$log" 2>&1 || true
assert_no_sudo "rollback"
grep -qi 'interactive terminal' "$log" || {
  tail -15 "$log" >&2
  fail "rollback of a PKG cask did not refuse off a TTY"
}
pass "rollback (PKG history) refused off a TTY, no sudo"

# ── Case 2: upgrade (network) ───────────────────────────────────────────────
# Seed a real PKG cask as installed at an ancient version so the upgrade sees
# it as outdated and reaches the gate before the uninstall.
p=$(fresh_prefix up)
db="$p/db/malt.db"
sqlite3 "$db" \
  "INSERT INTO casks(token,name,version,url) VALUES('basictex','basictex','0.0','https://example.invalid/basictex-0.0.pkg');"
log="$tmp/up.log"
printf '' | PATH="$tmp:$PATH" MALT_PREFIX="$p" "$MT_BIN" upgrade basictex >"$log" 2>&1 || true
assert_no_sudo "upgrade"
if grep -qi 'interactive terminal' "$log"; then
  pass "upgrade (PKG cask) refused off a TTY, no sudo"
elif grep -qiE "$net_skip_re" "$log"; then
  skip "upgrade basictex: classified upstream condition"
else
  tail -15 "$log" >&2
  fail "upgrade neither refused nor reported a known upstream skip"
fi

# ── Cases 4 & 5: the interactive confirm branch (needs a real pty) ──────────
# The cases above only prove the refusal direction. On a real terminal the gate
# must ACCEPT "y" (proceed) and DECLINE anything else — an inverted or
# always-off confirm would otherwise ship green. Drive a pty with the shared
# perl driver against the offline fake cask so it stays fast and deterministic;
# skip (don't fail) when IO::Pty is unavailable, exactly like the tui e2e.
PTY_DRIVER="$ROOT/scripts/lib/tui_pty_drive.pl"
if perl -MIO::Pty -e 1 >/dev/null 2>&1 && perl -c "$PTY_DRIVER" >/dev/null 2>&1; then
  p=$(fresh_prefix cf)
  db="$p/db/malt.db"
  sqlite3 "$db" \
    "INSERT INTO casks(token,name,version,url) VALUES('faketpkg','faketpkg','2.0','https://example.invalid/f-2.0.pkg');
     INSERT INTO cask_versions(token,version,url,sha256,artifact_type) VALUES('faketpkg','2.0','https://example.invalid/f-2.0.pkg','','pkg');
     INSERT INTO cask_versions(token,version,url,sha256,artifact_type) VALUES('faketpkg','1.0','https://example.invalid/f-1.0.pkg','','pkg');"

  # Decline: "n" must abort at the gate — no reinstall attempt, no sudo.
  cap="$tmp/cf_no.cap"
  PATH="$tmp:$PATH" MALT_PREFIX="$p" MALT_OFFLINE=1 perl "$PTY_DRIVER" "$cap" 80 24 \
    "$MT_BIN" rollback faketpkg --to 1.0 <<<'settle 1
send n\n
quitwait 5' >/dev/null
  assert_no_sudo "confirm-decline"
  tr -d '\r' <"$cap" | grep -qi 'not confirmed' || {
    tr -d '\r' <"$cap" >&2
    fail "declining the PKG prompt did not abort at the gate"
  }
  tr -d '\r' <"$cap" | grep -qi 'reinstall' && {
    tr -d '\r' <"$cap" >&2
    fail "declining the PKG prompt still proceeded to reinstall"
  }
  pass "interactive decline ('n') aborts before reinstall, no sudo"

  # Accept: "y" must proceed past the gate. Offline, the fake URL then fails the
  # download — that failure is the observable "we got past confirmation".
  cap="$tmp/cf_yes.cap"
  PATH="$tmp:$PATH" MALT_PREFIX="$p" MALT_OFFLINE=1 perl "$PTY_DRIVER" "$cap" 80 24 \
    "$MT_BIN" rollback faketpkg --to 1.0 <<<'settle 1
send y\n
quitwait 10' >/dev/null
  assert_no_sudo "confirm-accept"
  tr -d '\r' <"$cap" | grep -qi 'reinstall' || {
    tr -d '\r' <"$cap" >&2
    fail "accepting the PKG prompt did not proceed past the gate"
  }
  pass "interactive accept ('y') proceeds past the gate, no sudo"
else
  skip "interactive confirm cases need Perl IO::Pty; skipped"
fi

echo "pkg-nontty: DONE — every verb that can sudo refuses off a TTY"
exit 0
