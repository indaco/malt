#!/usr/bin/env bash
# scripts/bench.sh — local benchmark runner for malt
#
# Mirrors the build + benchmark steps of .github/workflows/benchmark.yml
# (without the README update / commit steps). Designed so it can also be
# called from CI: one step to build, one step per package, with results
# emitted to $GITHUB_OUTPUT when present.
#
# Usage:
#   scripts/bench.sh                       # build everything, bench tree+wget+ffmpeg
#   scripts/bench.sh tree                  # bench a subset
#   SKIP_BUILD=1 scripts/bench.sh tree     # reuse existing binaries
#   SKIP_OTHERS=1 scripts/bench.sh         # bench only malt (and brew)
#   SKIP_BREW=1 scripts/bench.sh           # skip Homebrew comparison
#   BENCH_TRUE_COLD=1 scripts/bench.sh     # wipe malt prefix before each cold install
#   BENCH_STRESS=20 scripts/bench.sh ffmpeg  # stress mode — see below
#
# Env overrides:
#   BENCH_WORK_DIR     Where to clone other tools      (default /tmp/malt-bench)
#   MALT_BIN           Path to malt binary             (default $BENCH_BUILD_PREFIX/bin/malt)
#   MALT_BENCH_PREFIX  Runtime MALT_PREFIX for malt    (default /tmp/mt-b, must be ≤13 bytes)
#   NB_BENCH_PREFIX    Runtime root for nanobrew       (default /tmp/nb,  patched into source)
#   ZB_BENCH_PREFIX    Runtime ZEROBREW_ROOT           (default /tmp/zb)
#   BRU_BENCH_PREFIX   Runtime HOMEBREW_PREFIX for bru (default /tmp/bru, must be ≤13 bytes)
#   NB_DIR/ZB_DIR/BRU_DIR  Other tools' source dirs    (default $BENCH_WORK_DIR/<name>)
#
# Notes:
# - The script runs every tool against an isolated /tmp prefix rather than
#   /opt/{malt,nanobrew,zerobrew,bru,homebrew}, so it never touches existing
#   installations. nanobrew has no prefix env var, so its source is sed-patched
#   in place before building (and the patch is reset on each build via
#   `git checkout -- src` so changing NB_BENCH_PREFIX always works).
# - With BENCH_TRUE_COLD=1 each tool's prefix is wiped before its cold
#   install, forcing a real network download (matches a fresh CI runner).
# - `BENCH_STRESS=N` runs N back-to-back cold installs of malt *only* for
#   each package and exits non-zero if any of them fail. Designed to catch
#   low-rate races in the parallel install pipeline (such as the
#   fetchFormulaWorker allocator race that went undetected by single-sample
#   runs). Builds nothing else, times nothing else, just pass/fail counts.
#   Example: `BENCH_STRESS=20 ./scripts/bench.sh ffmpeg`.
# - Compatible with bash 3.2 (macOS default) — no associative arrays.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${BENCH_WORK_DIR:-/tmp/malt-bench}"

# Build malt into an isolated prefix so local `zig build` / `just build`
# artifacts (debug binaries) can never pollute the benchmark.
BENCH_BUILD_PREFIX="${BENCH_BUILD_PREFIX:-$WORK_DIR/build}"
MALT_BIN="${MALT_BIN:-$BENCH_BUILD_PREFIX/bin/malt}"
NB_DIR="${NB_DIR:-$WORK_DIR/nanobrew}"
ZB_DIR="${ZB_DIR:-$WORK_DIR/zerobrew}"
BRU_DIR="${BRU_DIR:-$WORK_DIR/bru}"
NB_BIN="$NB_DIR/zig-out/bin/nb"
ZB_BIN="$ZB_DIR/target/release/zb"
BRU_BIN="$BRU_DIR/zig-out/bin/bru"

SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_BREW="${SKIP_BREW:-0}"
SKIP_OTHERS="${SKIP_OTHERS:-0}"
BENCH_TRUE_COLD="${BENCH_TRUE_COLD:-0}"
# Locally we record `FAIL` and continue so a flaky tool doesn't kill the
# whole run. CI sets this to 1 so a broken malt install can never silently
# publish fake numbers to the README.
BENCH_FAIL_FAST="${BENCH_FAIL_FAST:-0}"
# When set to a positive integer, bench.sh skips the normal comparison
# flow and instead runs that many back-to-back cold installs of malt for
# each listed package. Exits non-zero if any single run fails. Used to
# catch low-rate races in the parallel install pipeline — single-sample
# runs missed the fetchFormulaWorker allocator race for weeks.
BENCH_STRESS="${BENCH_STRESS:-0}"

# Isolated runtime prefixes — kept separate from /opt/{malt,nanobrew,...} so
# the benchmark never touches the user's real installations. malt and bru
# patch Mach-O LC_LOAD_DYLIB paths in place and so cap the prefix at 13 bytes
# (the length of the original `/opt/homebrew` slot). nanobrew uses a longer
# placeholder system and zerobrew similarly is not constrained the same way.
MALT_BENCH_PREFIX="${MALT_BENCH_PREFIX:-/tmp/mt-b}"
NB_BENCH_PREFIX="${NB_BENCH_PREFIX:-/tmp/nb}"
ZB_BENCH_PREFIX="${ZB_BENCH_PREFIX:-/tmp/zb}"
BRU_BENCH_PREFIX="${BRU_BENCH_PREFIX:-/tmp/bru}"

# Length cap (13) for the two tools that patch Mach-O paths in place.
_check_len() {
  if [ "${#2}" -gt 13 ]; then
    printf '✗ %s must be ≤13 bytes (got %d): %s\n' "$1" "${#2}" "$2" >&2
    exit 1
  fi
}
_check_len MALT_BENCH_PREFIX "$MALT_BENCH_PREFIX"
_check_len BRU_BENCH_PREFIX "$BRU_BENCH_PREFIX"
unset -f _check_len

# Refuse to wipe anything outside /tmp — protects /opt/{malt,nanobrew,...}.
if [ "$BENCH_TRUE_COLD" = "1" ]; then
  for _p in "$MALT_BENCH_PREFIX" "$NB_BENCH_PREFIX" "$ZB_BENCH_PREFIX" "$BRU_BENCH_PREFIX"; do
    case "$_p" in
      /tmp/*) ;;
      *)
        printf '✗ BENCH_TRUE_COLD refuses to wipe a prefix outside /tmp: %s\n' \
          "$_p" >&2
        exit 1
        ;;
    esac
  done
  unset _p
fi

# Wire each tool to its prefix via env (nanobrew has no env knob — handled in
# build_nanobrew via a source patch).
export MALT_PREFIX="$MALT_BENCH_PREFIX"
export ZEROBREW_ROOT="$ZB_BENCH_PREFIX"
export ZEROBREW_PREFIX="$ZB_BENCH_PREFIX"
# Real `brew` overwrites HOMEBREW_PREFIX from its own `$0` path on every run
# (see /opt/homebrew/bin/brew line ~75), so exporting it here only affects bru.
export HOMEBREW_PREFIX="$BRU_BENCH_PREFIX"

if [ $# -gt 0 ]; then
  PACKAGES=("$@")
else
  PACKAGES=(tree wget ffmpeg)
fi

# --- output helpers ----------------------------------------------------------

if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  BOLD=$'\033[1m'
  CYAN=$'\033[36m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  RESET=$'\033[0m'
else
  BOLD=""
  CYAN=""
  GREEN=""
  YELLOW=""
  RED=""
  RESET=""
fi

info() { printf "%s▸%s %s\n" "$CYAN" "$RESET" "$*" >&2; }
ok() { printf "%s✓%s %s\n" "$GREEN" "$RESET" "$*" >&2; }
warn() { printf "%s⚠%s %s\n" "$YELLOW" "$RESET" "$*" >&2; }
err() {
  printf "%s✗%s %s\n" "$RED" "$RESET" "$*" >&2
  exit 1
}

need() { command -v "$1" >/dev/null 2>&1 || err "missing required command: $1"; }

emit_output() {
  # Append a key=value line to $GITHUB_OUTPUT if running under Actions.
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s\n' "$1" >>"$GITHUB_OUTPUT"
  fi
}

# --- result storage (bash 3.2-compatible) ------------------------------------
#
# We can't use `declare -A` on macOS bash 3.2, so results are stored in
# dynamically-named scalar variables and accessed via indirect expansion.

_keysafe() {
  local s="${1//[^a-zA-Z0-9]/_}"
  printf '%s' "$s"
}

set_result() {
  # set_result <key> <value>
  local var
  var="_r_$(_keysafe "$1")"
  printf -v "$var" '%s' "$2"
}

get_result() {
  # get_result <key>  (prints empty string if unset)
  local var
  var="_r_$(_keysafe "$1")"
  printf '%s' "${!var:-}"
}

# --- build steps -------------------------------------------------------------

build_malt() {
  info "prefixes: malt=$MALT_BENCH_PREFIX nb=$NB_BENCH_PREFIX zb=$ZB_BENCH_PREFIX bru=$BRU_BENCH_PREFIX (BENCH_TRUE_COLD=$BENCH_TRUE_COLD)"
  if [ "$SKIP_BUILD" = "1" ] && [ -x "$MALT_BIN" ]; then
    info "skip build malt (SKIP_BUILD=1, binary present)"
    return
  fi
  need zig
  info "build malt (ReleaseSafe) → $BENCH_BUILD_PREFIX"
  # Wipe the dedicated bench prefix so we never pick up a stale debug binary
  # left behind by `zig build` / `just build` / IDE builds in ./zig-out.
  rm -rf "$BENCH_BUILD_PREFIX"
  (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe --prefix "$BENCH_BUILD_PREFIX")
  if [ ! -x "$MALT_BIN" ]; then
    err "build did not produce $MALT_BIN"
  fi
  "$MALT_BIN" --version >&2
}

build_nanobrew() {
  if [ "$SKIP_BUILD" = "1" ] && [ -x "$NB_BIN" ]; then return; fi
  need git
  need zig
  info "build nanobrew (prefix $NB_BENCH_PREFIX)"
  if [ ! -d "$NB_DIR/.git" ]; then
    git clone --depth 1 https://github.com/justrach/nanobrew.git "$NB_DIR"
  else
    # Discard any prior in-place patch so we re-apply for the current
    # NB_BENCH_PREFIX (idempotent across runs even if the value changed).
    git -C "$NB_DIR" checkout -- src
  fi
  # nanobrew has no prefix env var — its paths are compile-time constants in
  # src/platform/paths.zig and several call sites. Replace `/opt/nanobrew`
  # everywhere under src/ before building.
  grep -rlF "/opt/nanobrew" "$NB_DIR/src" 2>/dev/null | while read -r f; do
    sed -i '' "s|/opt/nanobrew|$NB_BENCH_PREFIX|g" "$f"
  done
  (cd "$NB_DIR" && zig build -Doptimize=ReleaseFast)
  mkdir -p "$NB_BENCH_PREFIX"
  "$NB_BIN" init >/dev/null 2>&1 || true
}

build_zerobrew() {
  if [ "$SKIP_BUILD" = "1" ] && [ -x "$ZB_BIN" ]; then return; fi
  need git
  need cargo
  info "build zerobrew (root $ZB_BENCH_PREFIX)"
  if [ ! -d "$ZB_DIR/.git" ]; then
    git clone --depth 1 https://github.com/lucasgelfond/zerobrew.git "$ZB_DIR"
  fi
  (cd "$ZB_DIR" && cargo build --release)
  mkdir -p "$ZB_BENCH_PREFIX"
  "$ZB_BIN" init >/dev/null 2>&1 || true
}

build_bru() {
  if [ "$SKIP_BUILD" = "1" ] && [ -x "$BRU_BIN" ]; then return; fi
  need git
  need zig
  info "build bru (prefix $BRU_BENCH_PREFIX)"
  if [ ! -d "$BRU_DIR/.git" ]; then
    git clone --depth 1 https://github.com/zieka/bru.git "$BRU_DIR"
  fi
  (cd "$BRU_DIR" && zig build -Doptimize=ReleaseFast)
  mkdir -p "$BRU_BENCH_PREFIX"
}

# --- timing ------------------------------------------------------------------

# Run `<bin> <uninstall> <pkg>` then time `<bin> <install> <pkg>`. Echo seconds.
# Unlike the upstream workflow, this checks the install exit code: a silent
# install failure (e.g. permission denied, tap missing) would otherwise look
# like a sub-millisecond "install" in the captured time, making the table lie.
time_install() {
  local bin="$1" install="$2" uninstall="$3" pkg="$4" t rc=0
  "$bin" "$uninstall" "$pkg" >/dev/null 2>&1 || true
  t=$({
    TIMEFORMAT='%R'
    time "$bin" "$install" "$pkg" >/tmp/malt-bench.out 2>&1
  } 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "$bin install $pkg FAILED (exit=$rc); output:"
    sed 's/^/    /' /tmp/malt-bench.out >&2
    if [ "$BENCH_FAIL_FAST" = "1" ]; then
      err "aborting (BENCH_FAIL_FAST=1)"
    fi
    printf 'FAIL'
    return
  fi
  printf '%s' "$t"
}

time_brew_install() {
  local pkg="$1" t rc=0
  brew uninstall "$pkg" >/dev/null 2>&1 || true
  t=$({
    TIMEFORMAT='%R'
    time brew install "$pkg" >/tmp/malt-bench.out 2>&1
  } 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "brew install $pkg FAILED (exit=$rc)"
    if [ "$BENCH_FAIL_FAST" = "1" ]; then
      err "aborting (BENCH_FAIL_FAST=1)"
    fi
    printf 'FAIL'
    return
  fi
  printf '%s' "$t"
}

size_of() {
  if [ -f "$1" ]; then
    # Path is an internally-controlled binary; ls -lh matches the workflow.
    # Normalize bare unit suffix (e.g. "3.3M") to "3.3 MB" for README/CLI.
    # shellcheck disable=SC2012
    ls -lh "$1" | awk '{
      s = $5
      if (s ~ /[0-9]$/)       { print s " B" }
      else if (s ~ /[KMGT]$/) { print substr(s,1,length(s)-1) " " substr(s,length(s)) "B" }
      else                    { print s }
    }'
  else
    echo "n/a"
  fi
}

# --- bench loop --------------------------------------------------------------

# Per-tool cold-state preparation. Called only when BENCH_TRUE_COLD=1 (and the
# safety check has already confirmed the prefix is under /tmp).
prep_cold_malt() {
  info "wiping $MALT_BENCH_PREFIX (true cold: malt)"
  rm -rf "$MALT_BENCH_PREFIX"
}
prep_cold_nb() {
  info "wiping $NB_BENCH_PREFIX (true cold: nanobrew)"
  rm -rf "$NB_BENCH_PREFIX"
  "$NB_BIN" init >/dev/null 2>&1 || true
}
prep_cold_zb() {
  info "wiping $ZB_BENCH_PREFIX (true cold: zerobrew)"
  rm -rf "$ZB_BENCH_PREFIX"
  "$ZB_BIN" init >/dev/null 2>&1 || true
}
prep_cold_bru() {
  info "wiping $BRU_BENCH_PREFIX (true cold: bru)"
  rm -rf "$BRU_BENCH_PREFIX"
  mkdir -p "$BRU_BENCH_PREFIX"
}

# --- stress mode -------------------------------------------------------------
#
# Run N back-to-back true-cold installs of malt per package and fail on any
# single failure. Designed for race detection, not for timing — single-sample
# timing runs missed the P3 fetchFormulaWorker allocator race because its
# failure window was ~10% and the bench only took one sample per package.
#
# Output is a compact progress bar of `.` (pass) and `F` (fail) characters,
# then a pass/fail summary per package. Exits non-zero on any failure so it
# slots cleanly into CI.
run_stress_pkg() {
  local pkg="$1" count="$2"
  local passes=0 failures=0 i
  info "${BOLD}stress: $pkg (×$count cold installs)${RESET}"
  printf "  " >&2
  for i in $(seq 1 "$count"); do
    "$MALT_BIN" uninstall "$pkg" >/dev/null 2>&1 || true
    rm -rf "$MALT_BENCH_PREFIX"
    if "$MALT_BIN" install "$pkg" >/tmp/malt-bench.out 2>&1; then
      passes=$((passes + 1))
      printf "." >&2
    else
      failures=$((failures + 1))
      printf "F" >&2
    fi
  done
  printf "\n" >&2
  if [ "$failures" -gt 0 ]; then
    err "  $pkg: $passes/$count passed, $failures FAILED"
    # Show the tail of the last failure output to aid triage.
    warn "  last failure output:"
    tail -10 /tmp/malt-bench.out | sed 's/^/      /' >&2
    return 1
  fi
  ok "  $pkg: $passes/$count passed"
  return 0
}

run_stress() {
  local count="$1" rc=0
  shift
  info "${BOLD}stress mode: $count cold runs per package${RESET}"
  for pkg in "$@"; do
    if ! run_stress_pkg "$pkg" "$count"; then
      rc=1
    fi
  done
  if [ "$rc" -ne 0 ]; then
    err "stress test failed — at least one package had a cold-install failure"
    return 1
  fi
  ok "stress test passed — all $count runs succeeded for every package"
  return 0
}

run_bench_for() {
  local pkg="$1" t
  info "${BOLD}benchmark: $pkg${RESET}"

  # malt
  if [ "$BENCH_TRUE_COLD" = "1" ]; then prep_cold_malt; fi
  t=$(time_install "$MALT_BIN" install uninstall "$pkg")
  set_result "cold_mt_$pkg" "$t"
  t=$(time_install "$MALT_BIN" install uninstall "$pkg")
  set_result "warm_mt_$pkg" "$t"
  "$MALT_BIN" uninstall "$pkg" >/dev/null 2>&1 || true
  emit_output "mt_cold=$(get_result "cold_mt_$pkg")s"
  emit_output "mt_warm=$(get_result "warm_mt_$pkg")s"

  if [ "$SKIP_OTHERS" != "1" ]; then
    if [ -x "$NB_BIN" ]; then
      if [ "$BENCH_TRUE_COLD" = "1" ]; then prep_cold_nb; fi
      t=$(time_install "$NB_BIN" install remove "$pkg")
      set_result "cold_nb_$pkg" "$t"
      t=$(time_install "$NB_BIN" install remove "$pkg")
      set_result "warm_nb_$pkg" "$t"
      "$NB_BIN" remove "$pkg" >/dev/null 2>&1 || true
      emit_output "nb_cold=$(get_result "cold_nb_$pkg")s"
      emit_output "nb_warm=$(get_result "warm_nb_$pkg")s"
    fi
    if [ -x "$ZB_BIN" ]; then
      if [ "$BENCH_TRUE_COLD" = "1" ]; then prep_cold_zb; fi
      t=$(time_install "$ZB_BIN" install uninstall "$pkg")
      set_result "cold_zb_$pkg" "$t"
      t=$(time_install "$ZB_BIN" install uninstall "$pkg")
      set_result "warm_zb_$pkg" "$t"
      "$ZB_BIN" uninstall "$pkg" >/dev/null 2>&1 || true
      emit_output "zb_cold=$(get_result "cold_zb_$pkg")s"
      emit_output "zb_warm=$(get_result "warm_zb_$pkg")s"
    fi
    if [ -x "$BRU_BIN" ]; then
      if [ "$BENCH_TRUE_COLD" = "1" ]; then prep_cold_bru; fi
      t=$(time_install "$BRU_BIN" install uninstall "$pkg")
      set_result "cold_bru_$pkg" "$t"
      t=$(time_install "$BRU_BIN" install uninstall "$pkg")
      set_result "warm_bru_$pkg" "$t"
      "$BRU_BIN" uninstall "$pkg" >/dev/null 2>&1 || true
      emit_output "bru_cold=$(get_result "cold_bru_$pkg")s"
      emit_output "bru_warm=$(get_result "warm_bru_$pkg")s"
    fi
  fi

  if [ "$SKIP_BREW" != "1" ] && command -v brew >/dev/null 2>&1; then
    t=$(time_brew_install "$pkg")
    set_result "cold_brew_$pkg" "$t"
    brew uninstall "$pkg" >/dev/null 2>&1 || true
    emit_output "brew_cold=$(get_result "cold_brew_$pkg")s"
  fi
}

# --- run ---------------------------------------------------------------------

build_malt

# Stress mode short-circuits the rest of the bench: no peer builds, no
# timings, just repeated cold installs of malt.
if [ "$BENCH_STRESS" -gt 0 ]; then
  run_stress "$BENCH_STRESS" "${PACKAGES[@]}"
  exit $?
fi

if [ "$SKIP_OTHERS" != "1" ]; then
  build_nanobrew || warn "nanobrew build failed — skipping"
  if command -v cargo >/dev/null 2>&1; then
    build_zerobrew || warn "zerobrew build failed — skipping"
  else
    warn "cargo missing — skipping zerobrew"
  fi
  build_bru || warn "bru build failed — skipping"
fi

set_result "size_mt" "$(size_of "$MALT_BIN")"
set_result "size_nb" "$(size_of "$NB_BIN")"
set_result "size_zb" "$(size_of "$ZB_BIN")"
set_result "size_bru" "$(size_of "$BRU_BIN")"
if command -v brew >/dev/null 2>&1; then
  set_result "size_brew" "$(size_of "$(command -v brew)")"
else
  set_result "size_brew" "n/a"
fi
emit_output "mt_size=$(get_result size_mt)"
emit_output "nb_size=$(get_result size_nb)"
emit_output "zb_size=$(get_result size_zb)"
emit_output "bru_size=$(get_result size_bru)"
# brew_size omitted: `which brew` is the shell wrapper, not a meaningful size.

for pkg in "${PACKAGES[@]}"; do
  run_bench_for "$pkg"
done

# --- summary -----------------------------------------------------------------

cell() {
  local v="${1:-}"
  if [ -n "$v" ]; then printf "%ss" "$v"; else printf "—"; fi
}

printf "\n%sBinary Size%s\n" "$BOLD" "$RESET"
printf "  %-10s %s\n" "malt" "$(get_result size_mt)"
printf "  %-10s %s\n" "nanobrew" "$(get_result size_nb)"
printf "  %-10s %s\n" "zerobrew" "$(get_result size_zb)"
printf "  %-10s %s\n" "bru" "$(get_result size_bru)"
# brew omitted: `which brew` is the shell wrapper, not a meaningful size.

printf "\n%sCold Install%s\n" "$BOLD" "$RESET"
printf "  %-14s %-10s %-10s %-10s %-10s %-10s\n" Package malt nanobrew zerobrew bru brew
for pkg in "${PACKAGES[@]}"; do
  printf "  %-14s %-10s %-10s %-10s %-10s %-10s\n" "$pkg" \
    "$(cell "$(get_result "cold_mt_$pkg")")" \
    "$(cell "$(get_result "cold_nb_$pkg")")" \
    "$(cell "$(get_result "cold_zb_$pkg")")" \
    "$(cell "$(get_result "cold_bru_$pkg")")" \
    "$(cell "$(get_result "cold_brew_$pkg")")"
done

printf "\n%sWarm Install%s\n" "$BOLD" "$RESET"
printf "  %-14s %-10s %-10s %-10s %-10s\n" Package malt nanobrew zerobrew bru
for pkg in "${PACKAGES[@]}"; do
  printf "  %-14s %-10s %-10s %-10s %-10s\n" "$pkg" \
    "$(cell "$(get_result "warm_mt_$pkg")")" \
    "$(cell "$(get_result "warm_nb_$pkg")")" \
    "$(cell "$(get_result "warm_zb_$pkg")")" \
    "$(cell "$(get_result "warm_bru_$pkg")")"
done

ok "done"
