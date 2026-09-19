#!/usr/bin/env bash
# Regression: `mt rollback --to` on a binary-only cask used to fail with
# `InstallFailed`. The rollback re-drives `install` with a synthetic,
# artifact-less cask, so the dispatch never saw a `binary` stanza and fell
# through to the `.app` demand, which a bare executable cannot satisfy. The
# same path is the "put the old version back" fallback of a failed upgrade,
# so a broken upgrade of a binary cask left the user with no binary at all.
# A per-version sidecar of the `binary` stanzas now travels with the cached
# artefact, the way font stanzas already did.
#
# Independently, a cask declaring both an `app` and `$APPDIR/...` binaries
# never linked those binaries and had nothing to unlink on uninstall.
#
# Half one drives the CLI offline: a crafted zip with one executable, a
# digest-pinned history row that reuses it without a fetch, and a seeded
# sidecar (its write half is pinned in tests/cask_binary_zip_test.zig).
# Half two pins the `$APPDIR` pass statically: no offline CLI path reaches
# an app+binary install, so its behaviour lives in the test binary.
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
export MALT_OFFLINE=1
export NO_COLOR=1
export MALT_NO_EMOJI=1
trap 'rm -rf "$PREFIX"' EXIT

# `<prefix>/tmp` is seeded by a real install; the swap refuses to create it.
mkdir -p "$PREFIX/db" "$PREFIX/tmp" "$MALT_CACHE/Cask" "$PREFIX/stage"
printf '#!/bin/sh\necho 1.0\n' >"$PREFIX/stage/tool"
chmod +x "$PREFIX/stage/tool"
ditto -c -k "$PREFIX/stage" "$MALT_CACHE/Cask/tool-1.0.zip"
SHA=$(shasum -a 256 "$MALT_CACHE/Cask/tool-1.0.zip" | cut -d' ' -f1)
# Sidecar contract: one `source<TAB>target` line per binary stanza.
printf 'tool\n' >"$MALT_CACHE/Cask/tool-1.0.binaries"

# Bootstrap the schema; `list --quiet` needs no network.
"$BIN" list --quiet >/dev/null 2>&1 || true
DB="$PREFIX/db/malt.db"
[[ -f "$DB" ]] || fail "DB was not initialised by mt list"

# Installed at 2.0; the 1.0 row is digest-pinned to the cached zip so the
# rollback reuses it offline.
sqlite3 "$DB" "INSERT INTO casks(token,name,version,url,sha256,app_path)
  VALUES('tool','tool','2.0','https://example.invalid/tool-2.0.zip','aa','$PREFIX/bin/tool');
INSERT INTO cask_versions(token,version,url,sha256,artifact_type,cache_path) VALUES
  ('tool','1.0','https://example.invalid/tool-1.0.zip','$SHA','zip','$MALT_CACHE/Cask/tool-1.0.zip'),
  ('tool','2.0','https://example.invalid/tool-2.0.zip','aa','zip',NULL);"

# 1. Behaviour: the rollback re-links the executable from the Caskroom.
"$BIN" rollback tool --to 1.0 >"$PREFIX/out" 2>&1 ||
  fail "binary-only cask rollback failed: $(cat "$PREFIX/out")"
[[ -L "$PREFIX/bin/tool" ]] || fail "rollback did not re-link <prefix>/bin/tool"
# The link stores the resolved path, so compare against the resolved prefix.
target=$(readlink "$PREFIX/bin/tool")
[[ "$target" == "$(cd "$PREFIX" && pwd -P)/Caskroom/tool/1.0/"* ]] ||
  fail "link points outside Caskroom/tool/1.0: $target"
[[ "$("$PREFIX/bin/tool")" == "1.0" ]] || fail "linked binary is not the 1.0 payload"
[[ "$(sqlite3 "$DB" "SELECT version FROM casks WHERE token='tool';")" == "1.0" ]] ||
  fail "casks row was not flipped to 1.0"

# 2. Static pins: the $APPDIR pass and the rollback override stay in place.
T="$ROOT/tests/cask_binary_zip_test.zig"
SRC="$ROOT/src/core/cask.zig"
PINS=(
  "links an APPDIR binary into the placed bundle"
  "uninstall removes every placed link"
)
for name in "${PINS[@]}"; do
  grep -qF -- "test \"$name\"" "$T" || fail "missing pin test: $name"
done
awk '/pub fn reinstallFromHistory\(/,/^    }/' "$SRC" | grep -q 'binary_entries_override' ||
  fail "reinstallFromHistory no longer re-sources the binary stanzas"
grep -qF "appdir_var = \"\$APPDIR/\"" "$SRC" || fail "the \$APPDIR source prefix is no longer named"
awk '/fn resolveCaskBinaryPath\(/,/^    }/' "$SRC" | grep -q 'appdir_var' ||
  fail "resolveCaskBinaryPath has no \$APPDIR arm"

echo "PASS: a binary cask rolls back to a linked executable and app casks link their declared binaries"
