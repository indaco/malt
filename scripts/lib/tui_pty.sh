#!/usr/bin/env bash
# scripts/lib/tui_pty.sh
#
# Shared setup for the `mt tui` PTY end-to-end tests. Sourced, not run.
#
# The dashboard only behaves correctly under a real pseudo-terminal: raw mode,
# the alt-screen, the TIOCGWINSZ/SIGWINCH resize path, and the re-exec
# delegation round-trip all need a tty. These helpers provide the pty driver,
# a tool guard, and a disposable offline fixture prefix so each e2e is hermetic
# (a throwaway MALT_PREFIX under /tmp, no network, no dependence on the user's
# real Homebrew / /opt/malt) and mirrors the existing e2e contract: MT_BIN guard
# with exit 2 when the binary (or required tooling) is missing.

# Resolve paths relative to this file so callers can source it from anywhere.
TUI_PTY_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TUI_PTY_DRIVER="$TUI_PTY_LIB_DIR/tui_pty_drive.pl"

MT_BIN="${MT_BIN:-./zig-out/bin/malt}"

# Guard: refuse with exit 2 (the e2e "can't run here" signal) when the binary
# or any required host tool is absent, instead of failing obscurely later.
tui_pty_guard() {
  if [[ ! -x "$MT_BIN" ]]; then
    echo "tui-e2e: $MT_BIN not found or not executable" >&2
    echo "tui-e2e: run 'zig build' first (or set MT_BIN)" >&2
    exit 2
  fi
  if ! command -v perl >/dev/null 2>&1; then
    echo "tui-e2e: perl is required to drive the pty" >&2
    exit 2
  fi
  if ! perl -MIO::Pty -e 1 >/dev/null 2>&1; then
    echo "tui-e2e: perl module IO::Pty is required to drive the pty" >&2
    exit 2
  fi
  if ! perl -c "$TUI_PTY_DRIVER" >/dev/null 2>&1; then
    echo "tui-e2e: pty driver failed to compile: $TUI_PTY_DRIVER" >&2
    exit 2
  fi
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "tui-e2e: sqlite3 is required to seed the fixture store" >&2
    exit 2
  fi
}

# Create a disposable, offline fixture prefix and export it. Scrubs CI/NO_COLOR
# from the environment because `mt tui` refuses to launch under either (it would
# otherwise exit 2 on a CI runner before the pty test could begin). The caller
# owns cleanup: `trap 'rm -rf "$TUI_PREFIX"' EXIT`.
tui_pty_make_prefix() {
  TUI_PREFIX=$(mktemp -d /tmp/mt_tui_e2e.XXXXXX)
  export MALT_PREFIX="$TUI_PREFIX"
  export MALT_CACHE="$TUI_PREFIX/cache"
  # Genuinely offline so the launch-time outdated audit never reaches the
  # network — without this the bulk version-map fetch stalls the header.
  export MALT_OFFLINE=1
  unset CI NO_COLOR
  # `mt list` initialises + migrates the schema only when db/ already exists.
  mkdir -p "$TUI_PREFIX/db"
  "$MT_BIN" list >/dev/null 2>&1 || true
}

# Seed N phantom formula kegs (pkg01..pkgNN) so the Installed tab has a
# scrollable list. cellar_path points at a dir that need not exist — `mt list
# --size --linked` tolerates it (reports 0 bytes / unlinked), which is all the
# resize test needs: enough rows to scroll and a stable selection.
tui_pty_seed_kegs() {
  local n="$1" i sql="BEGIN;"
  for ((i = 1; i <= n; i++)); do
    local name
    name=$(printf 'pkg%02d' "$i")
    sql+="INSERT INTO kegs (name,full_name,version,store_sha256,cellar_path,pinned)"
    sql+=" VALUES ('$name','$name','1.$i','sha$i','$TUI_PREFIX/Cellar/$name/1.$i',0);"
  done
  sql+="COMMIT;"
  printf '%s' "$sql" | sqlite3 "$TUI_PREFIX/db/malt.db"
}

# Seed a single keg with a real (minimal) Cellar dir so `mt uninstall` succeeds
# end-to-end — the delegation round-trip needs the real subcommand to complete.
tui_pty_seed_keg_real() {
  local name="$1"
  sqlite3 "$TUI_PREFIX/db/malt.db" \
    "INSERT INTO kegs (name,full_name,version,store_sha256,cellar_path,pinned) \
     VALUES ('$name','$name','1.0','sha','$TUI_PREFIX/Cellar/$name/1.0',0);"
  mkdir -p "$TUI_PREFIX/Cellar/$name/1.0"
  : >"$TUI_PREFIX/Cellar/$name/1.0/marker"
}

# Seed one orphaned store entry: a sha256 dir under store/ plus a store_refs
# row whose refcount has dropped to 0 — the exact shape `mt doctor --fix
# orphaned_store` and `mt purge --store-orphans` both sweep. A bare dir with no
# row is a warm / in-flight commit, not an orphan. Optional arg overrides the sha.
tui_pty_seed_orphan_store() {
  local sha="${1:-deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef}"
  mkdir -p "$TUI_PREFIX/store/$sha"
  : >"$TUI_PREFIX/store/$sha/payload"
  sqlite3 "$TUI_PREFIX/db/malt.db" \
    "INSERT OR REPLACE INTO store_refs (store_sha256, refcount) VALUES ('$sha', 0);"
}

# Drive `mt tui` under the pty. Args: <capfile> <cols> <rows>; the action
# program is read from this function's stdin. Echoes the driver's
# "EXIT_STATUS=<n>" line so the caller can assert on the child's exit code.
tui_pty_drive() {
  local capfile="$1" cols="$2" rows="$3"
  perl "$TUI_PTY_DRIVER" "$capfile" "$cols" "$rows" "$MT_BIN" tui
}

# Count installed kegs in the fixture store (post-run assertions).
tui_pty_keg_count() {
  sqlite3 "$TUI_PREFIX/db/malt.db" "SELECT COUNT(*) FROM kegs;" 2>/dev/null || echo -1
}
