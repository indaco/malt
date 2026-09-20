#!/usr/bin/env bash
# Regression: an app cask that ships a command-line helper beside its bundle
# (`binary "#{staged_path}/<file>"`, rendered by the API as a plain relative
# source) never got that helper linked. The zip path promoted the bundle and
# deleted the stage, the dmg path detached the volume, and the link pass
# that followed only resolved `$APPDIR/...` sources - so `<prefix>/bin/<name>`
# was never created, no manifest or sidecar was written, and the install
# still reported success. A rollback that did carry the relative stanza took
# the binary-only branch and lost the bundle instead.
#
# Now the stage entries those helpers live under are kept under the Caskroom
# (only those - never the bundle, and nothing is deleted inside the copy),
# and one link pass resolves each source against its own root.
#
# Half one drives the CLI offline through `mt rollback --to`, the one offline
# path that runs `install` on a cached zip: a crafted zip holding a bundle and
# a helper, a digest-pinned history row, and a seeded sidecar naming the
# relative stanza. Half two pins the fresh-install behaviour statically,
# since no offline CLI path reaches an app+binary fresh install; the tests it
# names run in the suite proper.
#
# Requirements: built `malt` at $MALT_BIN or zig-out/bin/malt, `sqlite3`,
# `ditto` and `shasum` on PATH. No network.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}
for tool in sqlite3 ditto shasum; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "this regression needs $tool on PATH" >&2
    exit 2
  }
done

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

PREFIX=$(mktemp -d /tmp/mt.XXX) || exit 2
export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$PREFIX/cache"
export MALT_APPDIR="$PREFIX/Applications"
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1
trap 'rm -rf "$PREFIX"' EXIT

# `<prefix>/tmp` is seeded by a real install; the swap refuses to create it.
mkdir -p "$PREFIX/db" "$PREFIX/tmp" "$PREFIX/Applications" "$MALT_CACHE/Cask" \
  "$PREFIX/stage/Pad.app/Contents/MacOS"
printf '#!/bin/sh\necho 1.0\n' >"$PREFIX/stage/pad-cli"
chmod +x "$PREFIX/stage/pad-cli"
: >"$PREFIX/stage/Pad.app/Contents/MacOS/pad"
ditto -c -k "$PREFIX/stage" "$MALT_CACHE/Cask/pad-1.0.zip"
SHA=$(shasum -a 256 "$MALT_CACHE/Cask/pad-1.0.zip" | cut -d' ' -f1)
# Sidecar contract: one `source<TAB>target` line per binary stanza, the
# target already reduced to the bare link name.
printf 'pad-cli\tpad\n' >"$MALT_CACHE/Cask/pad-1.0.binaries"

# Bootstrap the schema; `list --quiet` needs no network.
"$BIN" list --quiet >/dev/null 2>&1 || true
DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

# Installed at 2.0; the 1.0 row is digest-pinned to the cached zip so the
# rollback reuses it offline.
sqlite3 "$DB" "INSERT INTO casks(token,name,version,url,sha256,app_path)
  VALUES('pad','pad','2.0','https://example.invalid/pad-2.0.zip','aa','$PREFIX/Applications/Pad.app');
INSERT INTO cask_versions(token,version,url,sha256,artifact_type,cache_path) VALUES
  ('pad','1.0','https://example.invalid/pad-1.0.zip','$SHA','zip','$MALT_CACHE/Cask/pad-1.0.zip'),
  ('pad','2.0','https://example.invalid/pad-2.0.zip','aa','zip',NULL);"

# 1. Behaviour: the rollback promotes the bundle AND links the helper.
"$BIN" rollback pad --to 1.0 >"$PREFIX/out" 2>&1 ||
  fail "rollback failed: $(cat "$PREFIX/out")"
[[ -d "$PREFIX/Applications/Pad.app" ]] || fail "bundle was not promoted (binary-only branch taken)"
[[ -L "$PREFIX/bin/pad" ]] || fail "relative binary was not linked"
# The link stores the resolved path, so compare against the resolved prefix.
target=$(readlink "$PREFIX/bin/pad")
[[ "$target" == "$(cd "$PREFIX" && pwd -P)/Caskroom/pad/1.0/pad-cli" ]] ||
  fail "link does not point into the Caskroom copy: $target"
[[ "$("$PREFIX/bin/pad")" == "1.0" ]] || fail "linked helper is not the 1.0 payload"
[[ ! -e "$PREFIX/Caskroom/pad/1.0/Pad.app" ]] || fail "Caskroom copy still holds the promoted bundle"
grep -qxF -- "$PREFIX/bin/pad" "$PREFIX/Caskroom/pad/1.0/.malt-links" ||
  fail ".malt-links does not record the link"
[[ "$(sqlite3 "$DB" "SELECT app_path FROM casks WHERE token='pad';")" == "$PREFIX/Applications/Pad.app" ]] ||
  fail "app_path is not the bundle"

# 2. Uninstall takes the link, the bundle and the Caskroom copy with it.
"$BIN" uninstall --cask pad >"$PREFIX/out" 2>&1 || fail "uninstall failed: $(cat "$PREFIX/out")"
[[ ! -L "$PREFIX/bin/pad" ]] || fail "uninstall left the link"
[[ ! -d "$PREFIX/Applications/Pad.app" ]] || fail "uninstall left the bundle"
[[ ! -d "$PREFIX/Caskroom/pad" ]] || fail "uninstall left the Caskroom copy"

# 3. Static pins: the fresh-install shape lives in the test suite.
T="$ROOT/tests/cask_binary_zip_test.zig"
SRC="$ROOT/src/core/cask.zig"
PINS=(
  "an app cask links a relative binary from the Caskroom copy beside its placed bundle"
  "a tarball cask with an app and a relative binary promotes the bundle and links the binary"
  "a bundle reached through a stage symlink is never deleted from where the link points"
  "a binary-only cask whose archive holds an app rolls back to its links, not to a bundle"
)
for name in "${PINS[@]}"; do
  grep -qF -- "test \"$name\"" "$T" || fail "missing pin test: $name"
done
grep -q 'appdir_var) != (root_kind == .bundle)' "$SRC" && fail "the link pass filters to a single root again"
awk '/fn keepStageCopy\(/,/^    }/' "$SRC" | grep -q 'deleteTree' && fail "keepStageCopy deletes inside the copy again"

echo "PASS: an app cask links the helpers it ships beside its bundle, from every container"
