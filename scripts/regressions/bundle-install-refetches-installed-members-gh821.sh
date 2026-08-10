#!/usr/bin/env bash
# Pin that a warm `bundle install` does no network work.
#
# `install` has an idempotent fast path that skips the DB, the lock and every
# HTTP call when the named package is already installed. Every Brewfile member
# kind but the plain formula was vetoed out of it: `--cask` (which the bundle
# dispatcher sets for every cask line) and the `owner/repo/name` tap form,
# which covers tap formulas and tap casks alike. All of them then took slow
# paths that fetched metadata *before* testing installed state, so a re-run
# where nothing had changed paid one serial round trip per member.
#
# Pinned behaviour:
#   1. A bundle whose members are all installed completes without fetching.
#   2. The skip is a presence check, not a blanket one - an uninstalled cask
#      is still attempted.
#
# Hermetic: MALT_OFFLINE=1 turns any attempted fetch into an immediate typed
# failure, so "reached the network" is observable without a network.
#
# Usage: scripts/regressions/bundle-install-refetches-installed-members-gh821.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

MALT_BIN=${MALT_BIN:-$ROOT/zig-out/bin/malt}
if [[ ! -x "$MALT_BIN" ]]; then
  printf 'FAIL: malt binary not found at %s - run "zig build" first.\n' "$MALT_BIN" >&2
  exit 1
fi

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

PFX=$(mktemp -d -t mt_warm_bundle.XXXXXX)
trap 'rm -rf "$PFX"' EXIT

export MALT_PREFIX="$PFX" MALT_OFFLINE=1 NO_COLOR=1

# Real schema straight from the binary: an unresolvable name creates
# db/malt.db before it fails offline.
"$MALT_BIN" install --quiet nope-not-real >/dev/null 2>&1 || true
[[ -f "$PFX/db/malt.db" ]] || fail 'could not bootstrap the fixture database'

mkdir -p "$PFX/Cellar/jq/1.7" "$PFX/Cellar/prowl/1.9.0" "$PFX/Caskroom/iterm2/3.5.0"

# `deckclip` deliberately gets no Caskroom dir: recording it is best-effort,
# so the row has to be enough on its own.
sqlite3 "$PFX/db/malt.db" <<SQL
INSERT INTO kegs(name,full_name,version,tap,store_sha256,cellar_path)
  VALUES ('jq','jq','1.7','homebrew/core','x','$PFX/Cellar/jq/1.7'),
         ('prowl','caarlos0/tap/prowl','1.9.0','caarlos0/tap','x','$PFX/Cellar/prowl/1.9.0');
INSERT INTO casks(token,name,version,url,sha256,app_path,tap)
  VALUES ('iterm2','iTerm2','3.5.0','u','x','/Applications/iTerm.app','homebrew/cask'),
         ('deckclip','Deck','1.4.5','u','x','/Applications/Deck.app','yuzeguitarist/deck');
INSERT INTO taps(name,url,commit_sha,github_owner,github_repo)
  VALUES ('caarlos0/tap','https://github.com/caarlos0/homebrew-tap','deadbeef','caarlos0','homebrew-tap'),
         ('yuzeguitarist/deck','https://github.com/yuzeguitarist/homebrew-deck','deadbeef','yuzeguitarist','homebrew-deck');
SQL

cat >"$PFX/Brewfile" <<'EOF'
brew "jq"
brew "caarlos0/tap/prowl"
cask "iterm2"
cask "yuzeguitarist/deck/deckclip"
EOF

OUT="$PFX/out.txt"
if ! "$MALT_BIN" bundle install "$PFX/Brewfile" >"$OUT" 2>&1; then
  fail "warm bundle install reached the network: $(tr '\n' ' ' <"$OUT")"
fi
grep -q 'bundle install complete' "$OUT" ||
  fail 'bundle install never reported completion'

# A member that is genuinely absent must still be attempted, otherwise the
# fast path is an unconditional skip rather than a presence check.
printf 'cask "not-installed-xyz"\n' >"$PFX/Brewfile2"
if "$MALT_BIN" bundle install "$PFX/Brewfile2" >/dev/null 2>&1; then
  fail 'an uninstalled cask was silently skipped'
fi

printf 'PASS: a warm bundle install skips the network for members already installed\n'
