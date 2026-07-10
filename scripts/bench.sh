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
#   BENCH_ROUNDS=7 scripts/bench.sh        # samples per tool/pkg, median wins (default 5)
#   BENCH_SKIP_UPDATE=1 scripts/bench.sh   # don't git-fetch nanobrew/zerobrew (offline)
#   BENCH_STRESS=20 scripts/bench.sh ffmpeg  # stress mode — see below
#   BENCH_PER_ROUND=1 scripts/bench.sh wget  # log every (round,tool,pkg,cold,warm) sample
#
# Env overrides:
#   BENCH_WORK_DIR     Where to clone other tools      (default /tmp/malt-bench)
#   MALT_BIN           Path to malt binary             (default $BENCH_BUILD_PREFIX/bin/malt)
#   MALT_BENCH_PREFIX  Runtime MALT_PREFIX for malt    (default /tmp/mt-b, must be ≤13 bytes)
#   NB_BENCH_PREFIX    Runtime root for nanobrew       (default /tmp/nb,  patched into source)
#   ZB_BENCH_PREFIX    Runtime ZEROBREW_ROOT           (default /tmp/zb)
#   NB_DIR/ZB_DIR     Other tools' source dirs         (default $BENCH_WORK_DIR/<name>)
#
# Notes:
# - The script runs every tool against an isolated /tmp prefix rather than
#   /opt/{malt,nanobrew,zerobrew,homebrew}, so it never touches existing
#   installations. nanobrew has no prefix env var, so its source is sed-patched
#   in place before building (and the patch is reset on each build via
#   `git reset --hard FETCH_HEAD` — or `git checkout -- src` in
#   BENCH_SKIP_UPDATE mode — so changing NB_BENCH_PREFIX always works).
# - By default the script `git fetch`es nanobrew/zerobrew before each
#   build so the comparison isn't malt-today vs peer-from-weeks-ago.
#   Set BENCH_SKIP_UPDATE=1 to pin whatever is already checked out
#   (offline/reproducibility).
# - bru was previously part of the bench but was dropped: upstream pins
#   Zig 0.15.2 and uses `std.heap.ThreadSafeAllocator`, which was removed in
#   Zig 0.16 (what malt and nanobrew now build on). Re-add when bru tracks 0.16.
# - With BENCH_TRUE_COLD=1 each tool's prefix is wiped before its cold
#   install, forcing a real network download (matches a fresh CI runner).
# - Every package bench starts with a discarded "warmup" round that runs
#   every active tool once — primes DNS/TLS/TCP/disk caches so round 1
#   is not systematically slower than rounds 2+. Measured rounds then
#   rotate the tool order per round (round r: tools[r % N] goes first),
#   so no single tool reliably eats the cold-network slot.
# - In addition to the median reported in the README table, every
#   (tool, pkg, cold|warm) triple emits `<key>_min` and `<key>_stddev`
#   to $GITHUB_OUTPUT. These aren't used by the README workflow yet —
#   they're there so run-to-run noise is visible in the step log and
#   in the terminal summary.
# - `BENCH_STRESS=N` runs N back-to-back cold installs of malt *only* for
#   each package and exits non-zero if any of them fail. Designed to catch
#   low-rate races in the parallel install pipeline (such as the
#   fetchFormulaWorker allocator race that went undetected by single-sample
#   runs). Builds nothing else, times nothing else, just pass/fail counts.
#   Example: `BENCH_STRESS=20 ./scripts/bench.sh ffmpeg`.
# - `BENCH_PER_ROUND=1` logs every measured (round, tool, pkg, cold, warm)
#   sample to stderr with a wall-clock timestamp. Off by default so the
#   published median ± σ summary used by the CI workflow is unchanged.
#   Use it to identify which round produced an outlier when σ is high.
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
NB_BIN="$NB_DIR/zig-out/bin/nb"
ZB_BIN="$ZB_DIR/target/release/zb"

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
# When set to 1, every measured round emits a per-sample line on stderr so
# the round responsible for an outlier σ is identifiable from the log.
# Off by default — the published median ± σ summary stays unchanged when
# the env var is unset, which the CI bench workflow relies on.
BENCH_PER_ROUND="${BENCH_PER_ROUND:-0}"
# Samples per tool/package. The reported number is the median, which
# damps single-run outliers (network jitter, transient launchd hiccups,
# disk caches warming) without inflating the table the way a mean would.
# 5 rounds survive one outright outlier (FAIL/timeout) and still give a
# stable middle value; 3 was the old default and left the median one bad
# sample away from a visible shift. Warmup round isn't included here —
# it's always run and always discarded, regardless of BENCH_ROUNDS.
BENCH_ROUNDS="${BENCH_ROUNDS:-5}"
# Whether to `git fetch && reset --hard origin/HEAD` on existing nanobrew
# and zerobrew clones before building. Default on: prevents comparing
# malt-today against peer-tool-from-weeks-ago. Set to 1 for offline/reproducible
# runs that must use whatever is already checked out.
BENCH_SKIP_UPDATE="${BENCH_SKIP_UPDATE:-0}"
# Cold-median sanity ceiling (seconds). A peer tool's cold install that
# exceeds this is treated as a regression in *their* tool, not a real
# comparison number: the offending cell is omitted from the published
# table (loud ⚠️ marker + a GitHub warning annotation) instead of
# silently rewriting the README with garbage. The guard deliberately
# skips malt itself — a genuinely slow malt install must stay visible,
# not be hidden. Set to 0 to disable. See build_nanobrew/finalize_results.
# Default 50s: comfortably above the legitimate range (peer colds top out
# around 8–9s) yet far below the pathological 90–130s regression spikes.
BENCH_MAX_COLD="${BENCH_MAX_COLD:-50}"
case "$BENCH_ROUNDS" in
'' | *[!0-9]*)
  printf '✗ BENCH_ROUNDS must be a positive integer (got: %s)\n' "$BENCH_ROUNDS" >&2
  exit 1
  ;;
esac
if [ "$BENCH_ROUNDS" -lt 1 ]; then
  printf '✗ BENCH_ROUNDS must be ≥1 (got: %s)\n' "$BENCH_ROUNDS" >&2
  exit 1
fi

# Isolated runtime prefixes — kept separate from /opt/{malt,nanobrew,...} so
# the benchmark never touches the user's real installations. malt patches
# Mach-O LC_LOAD_DYLIB paths in place and so caps its prefix at 13 bytes
# (the length of the original `/opt/homebrew` slot). nanobrew uses a longer
# placeholder system and zerobrew similarly is not constrained the same way.
MALT_BENCH_PREFIX="${MALT_BENCH_PREFIX:-/tmp/mt-b}"
NB_BENCH_PREFIX="${NB_BENCH_PREFIX:-/tmp/nb}"
ZB_BENCH_PREFIX="${ZB_BENCH_PREFIX:-/tmp/zb}"

# Length cap (13) for malt, which patches Mach-O paths in place.
if [ "${#MALT_BENCH_PREFIX}" -gt 13 ]; then
  printf '✗ MALT_BENCH_PREFIX must be ≤13 bytes (got %d): %s\n' \
    "${#MALT_BENCH_PREFIX}" "$MALT_BENCH_PREFIX" >&2
  exit 1
fi

# Refuse to wipe anything outside /tmp — protects /opt/{malt,nanobrew,...}.
if [ "$BENCH_TRUE_COLD" = "1" ]; then
  for _p in "$MALT_BENCH_PREFIX" "$NB_BENCH_PREFIX" "$ZB_BENCH_PREFIX"; do
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

# emit_per_round <round> <tool> <pkg> <cold> <warm>
#
# Logs one measured sample to stderr, gated on BENCH_PER_ROUND=1. Used to
# pin down which round produced an outlier σ — the median ± σ summary
# averages the noise away, so without a per-sample line the offending
# round is invisible. Wall-clock timestamp helps correlate with system
# events (Spotlight, cloudd, Time Machine).
emit_per_round() {
  if [ "$BENCH_PER_ROUND" = "1" ]; then
    printf '%s[per-round]%s round=%s tool=%s pkg=%s cold=%s warm=%s @ %s\n' \
      "$YELLOW" "$RESET" "$1" "$2" "$3" "$4" "$5" "$(date +%H:%M:%S)" >&2
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

# pick_latest_tag — read `git ls-remote --tags` lines (or bare tag names) on
# stdin and print the highest stable vX.Y.Z tag. Strips the `refs/tags/`
# prefix and the peeled `^{}` suffix, drops pre-release tags (anything with a
# `-suffix`), and version-sorts so v0.1.201 wins over v0.1.99. Pure/offline —
# unit-tested via scripts/test/bench_release_resolution_test.sh.
pick_latest_tag() {
  sed 's|.*refs/tags/||; s|\^{}$||' |
    grep -E '^v[0-9]+(\.[0-9]+)*$' |
    sort -V |
    tail -1
}

# latest_release_tag <git-url> — resolve the latest stable release tag of a
# remote without a GitHub token (git ls-remote, no API rate limit). Highest
# semver tag is used as the "latest release" proxy: for the peer tools we
# bench it matches GitHub's marked latest release. Empty on network failure —
# callers fall back to the checked-out revision.
latest_release_tag() {
  git ls-remote --tags "$1" 'v*' 2>/dev/null | pick_latest_tag
}

# over_threshold <value> <threshold> — true (exit 0) only when value is a
# finite number strictly greater than threshold. Non-numeric (FAIL/empty) or a
# zero/empty threshold (guard disabled) is never "over". Float-safe via awk.
over_threshold() {
  local val="$1" thr="$2"
  [ -n "$thr" ] && [ "$thr" != "0" ] || return 1
  case "$val" in '' | *[!0-9.]*) return 1 ;; esac
  awk -v v="$val" -v t="$thr" 'BEGIN { exit !(v + 0 > t + 0) }'
}

# gha_warning <msg> — emit a GitHub Actions warning annotation on stdout so a
# peer-tool regression is loud in the run UI. No-op outside Actions.
gha_warning() {
  [ -n "${GITHUB_OUTPUT:-}" ] || return 0
  printf '::warning title=Benchmark anomaly::%s\n' "$1"
}

build_malt() {
  info "prefixes: malt=$MALT_BENCH_PREFIX nb=$NB_BENCH_PREFIX zb=$ZB_BENCH_PREFIX (BENCH_TRUE_COLD=$BENCH_TRUE_COLD)"
  if [ "$SKIP_BUILD" = "1" ] && [ -x "$MALT_BIN" ]; then
    info "skip build malt (SKIP_BUILD=1, binary present)"
    set_result ver_mt "$(malt_version)"
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
  set_result ver_mt "$(malt_version)"
}

# malt_version — semver token from `malt --version` (e.g. "0.9.3"), for the
# table header. Empty if malt can't report one; the header just omits it.
malt_version() {
  "$MALT_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -1
}

build_nanobrew() {
  local url="https://github.com/justrach/nanobrew.git"
  if [ "$SKIP_BUILD" = "1" ] && [ -x "$NB_BIN" ]; then
    set_result ver_nb "$(git -C "$NB_DIR" describe --tags --always 2>/dev/null || true)"
    return
  fi
  need git
  need zig
  info "build nanobrew (prefix $NB_BENCH_PREFIX)"
  # Pin to the latest *release* tag rather than HEAD, so a mid-development
  # commit (or a peer-tool regression that only landed on HEAD) can't
  # silently rewrite the published table. Resolved tokenlessly via ls-remote.
  local tag=""
  [ "$BENCH_SKIP_UPDATE" = "1" ] || tag=$(latest_release_tag "$url")
  if [ ! -d "$NB_DIR/.git" ]; then
    if [ -n "$tag" ]; then
      git clone --depth 1 --branch "$tag" "$url" "$NB_DIR"
    else
      git clone --depth 1 "$url" "$NB_DIR"
    fi
  elif [ "$BENCH_SKIP_UPDATE" = "1" ]; then
    # Offline mode: discard any prior in-place sed patch so we re-apply
    # for the current NB_BENCH_PREFIX (idempotent across runs even if
    # the value changed), but don't hit the network.
    git -C "$NB_DIR" checkout -- src
  elif [ -n "$tag" ]; then
    info "pinning nanobrew to latest release $tag (BENCH_SKIP_UPDATE=1 to skip)"
    git -C "$NB_DIR" fetch --depth 1 origin "$tag"
    # reset --hard also wipes any prior sed patch — no separate checkout needed.
    git -C "$NB_DIR" reset --hard FETCH_HEAD
  else
    warn "could not resolve nanobrew latest release tag — falling back to HEAD"
    git -C "$NB_DIR" fetch --depth 1 origin HEAD
    git -C "$NB_DIR" reset --hard FETCH_HEAD
  fi
  set_result ver_nb "${tag:-$(git -C "$NB_DIR" describe --tags --always 2>/dev/null || true)}"
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
  local url="https://github.com/lucasgelfond/zerobrew.git"
  if [ "$SKIP_BUILD" = "1" ] && [ -x "$ZB_BIN" ]; then
    set_result ver_zb "$(git -C "$ZB_DIR" describe --tags --always 2>/dev/null || true)"
    return
  fi
  need git
  need cargo
  info "build zerobrew (root $ZB_BENCH_PREFIX)"
  # Pin to the latest release tag, same rationale as build_nanobrew.
  local tag=""
  [ "$BENCH_SKIP_UPDATE" = "1" ] || tag=$(latest_release_tag "$url")
  if [ ! -d "$ZB_DIR/.git" ]; then
    if [ -n "$tag" ]; then
      git clone --depth 1 --branch "$tag" "$url" "$ZB_DIR"
    else
      git clone --depth 1 "$url" "$ZB_DIR"
    fi
  elif [ "$BENCH_SKIP_UPDATE" = "1" ]; then
    : # offline: use whatever is checked out
  elif [ -n "$tag" ]; then
    info "pinning zerobrew to latest release $tag (BENCH_SKIP_UPDATE=1 to skip)"
    git -C "$ZB_DIR" fetch --depth 1 origin "$tag"
    git -C "$ZB_DIR" reset --hard FETCH_HEAD
  else
    warn "could not resolve zerobrew latest release tag — falling back to HEAD"
    git -C "$ZB_DIR" fetch --depth 1 origin HEAD
    git -C "$ZB_DIR" reset --hard FETCH_HEAD
  fi
  set_result ver_zb "${tag:-$(git -C "$ZB_DIR" describe --tags --always 2>/dev/null || true)}"
  (cd "$ZB_DIR" && cargo build --release)
  mkdir -p "$ZB_BENCH_PREFIX"
  "$ZB_BIN" init >/dev/null 2>&1 || true
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

# median <v1> <v2> ... <vN>
#
# Prints the median of N numeric samples. If any sample is "FAIL", the
# whole run is treated as failed and "FAIL" is printed — one bad sample
# would make the median lie about what actually happens. For even N we
# return the lower of the two middle samples (deterministic, no float).
median() {
  local v
  for v in "$@"; do
    case "$v" in *FAIL*)
      printf 'FAIL'
      return
      ;;
    esac
  done
  local n=$# mid
  if [ $((n % 2)) -eq 1 ]; then
    mid=$(((n + 1) / 2))
  else
    mid=$((n / 2))
  fi
  printf '%s\n' "$@" | sort -n | sed -n "${mid}p"
}

# min_of <v1> <v2> ... <vN>
#
# Prints the smallest numeric sample. FAIL propagates (same reasoning as
# median: one failed run taints the aggregate).
min_of() {
  local v
  for v in "$@"; do
    case "$v" in *FAIL*)
      printf 'FAIL'
      return
      ;;
    esac
  done
  printf '%s\n' "$@" | sort -n | sed -n '1p'
}

# fmt_disp "<median>" "<stddev>" — "1.234±0.021s" composite string.
#
# Used by finalize_results when emitting `<tool>_cold_disp` / `<tool>_warm_disp`
# to $GITHUB_OUTPUT so the README workflow can drop the combined figure
# straight into a table cell. Empty median → "—"; FAIL median → "FAIL".
fmt_disp() {
  local m="${1:-}" s="${2:-}"
  if [ -z "$m" ]; then
    printf "—"
    return
  fi
  case "$m" in *FAIL*)
    printf "FAIL"
    return
    ;;
  esac
  if [ -n "$s" ]; then
    printf "%s±%ss" "$m" "$s"
  else
    printf "%ss" "$m"
  fi
}

# stddev_of <v1> <v2> ... <vN>
#
# Prints sample stddev (n-1 denominator) with 3 decimals. n<2 prints 0.
# Reported alongside the median so the bench table surfaces how noisy a
# number is — a 1.20 ± 0.80 cell is not the same story as 1.20 ± 0.02,
# and a single median hides that.
stddev_of() {
  local v
  for v in "$@"; do
    case "$v" in *FAIL*)
      printf 'FAIL'
      return
      ;;
    esac
  done
  printf '%s\n' "$@" | awk '
    { x[NR] = $1; s += $1 }
    END {
      n = NR
      if (n < 2) { printf("0.000"); exit }
      m = s / n
      for (i = 1; i <= n; i++) { d = x[i] - m; sq += d * d }
      printf("%.3f", sqrt(sq / (n - 1)))
    }'
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

# prep_cold_brew <pkg>
#
# malt/nanobrew/zerobrew all keep their download cache inside their install
# prefix, so a single `rm -rf $PREFIX` wipes both cleanly. Brew does not —
# its bottle cache lives at `~/Library/Caches/Homebrew/downloads`, outside
# any prefix and untouched by the bench. Without this wipe, every brew
# "cold" sample reuses a bottle cached by a previous round, and local
# numbers come out 5–25× faster than CI's (which runs on a fresh VM with
# no cache). The stddev tells the story: brew was reporting ±0.02s on
# wget cold while malt reported ±1.0s — you can't get that tight unless
# the network never gets touched.
#
# Targeted wipe (bottle file for the package plus each transitive dep)
# rather than `brew cleanup --prune=all`, so we don't nuke the user's
# entire Homebrew cache for everything else they've installed.
prep_cold_brew() {
  local pkg="$1" deps paths
  deps=$(brew deps "$pkg" 2>/dev/null || true)
  # `brew --cache <formula>` prints the bottle path even if absent, so
  # `rm -f` is safe against missing files.
  # shellcheck disable=SC2086
  paths=$(brew --cache "$pkg" $deps 2>/dev/null || true)
  if [ -n "$paths" ]; then
    local n_deps
    # shellcheck disable=SC2086  # intentional: $deps is space-separated list
    n_deps=$(printf '%s\n' $deps | wc -l | tr -d ' ')
    info "wiping brew bottle cache for $pkg + $n_deps deps (true cold: brew)"
    # shellcheck disable=SC2086  # intentional: $paths is space-separated list
    printf '%s\n' $paths | xargs -I{} rm -f {} 2>/dev/null || true
  fi
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
# shellcheck disable=SC2317  # lines after `err` in the failure branch
# look unreachable to shellcheck because it can't see that `err` is a
# plain logger that returns, not a non-returning function.
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

# shellcheck disable=SC2317  # same reason as run_stress_pkg above —
# `err` is a logger that returns, not a non-returning exit.
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

# --- sample accumulators -----------------------------------------------------
#
# Samples are collected round-by-round and aggregated once the package is
# done. Each (kind, tool, pkg) triple gets its own space-separated scalar
# (bash 3.2 has no associative arrays).

append_sample() {
  # append_sample <cold|warm> <key> <pkg> <value>
  local kind="$1" key="$2" pkg="$3" val="$4" var
  var="_samples_${kind}_${key}_$(_keysafe "$pkg")"
  printf -v "$var" '%s %s' "${!var:-}" "$val"
}

get_samples() {
  local kind="$1" key="$2" pkg="$3" var
  var="_samples_${kind}_${key}_$(_keysafe "$pkg")"
  printf '%s' "${!var:-}"
}

# --- per-round runners -------------------------------------------------------
#
# run_one / run_brew_one perform one cold+warm (or, for brew, just one
# cold) install pair and optionally append the timings to the sample
# buffers. record=0 runs the full install/uninstall cycle but discards
# results — that's the warmup mode.
#
# Why warmup + interleave together:
# - Warmup (one discarded pass per tool) primes DNS, TLS session cache,
#   TCP congestion window, and disk caches so round 1 isn't systematically
#   slower than rounds 2+.
# - Interleave (tool order rotates each round) kills the "first tool
#   always eats the cold network" bias. The old loop ran N malt rounds,
#   then N nanobrew, then N zerobrew, then N brew — so brew reliably
#   benchmarked on the warmest network state.
#
# "True cold" is preserved: prep_cold_* wipes the install prefix before
# every cold sample when BENCH_TRUE_COLD=1, so each cold sample is still
# a full network download. The goal here is to reduce *cross-sample*
# noise, not to change what "cold" means.
#
# Caveat (unchanged from before): BENCH_TRUE_COLD wipes the install
# prefix, not the download cache. Round 1 of each tool is genuinely cold
# (prefix empty + post-warmup network); rounds 2+ are prefix-empty but
# server/CDN-cache-warm. That's intentional — median across rounds
# favours the steady-state install path.

run_one() {
  # run_one <bin> <install> <uninstall> <pkg> <key> <prep_fn> <record> [<round>]
  local bin="$1" install="$2" uninstall="$3" pkg="$4" key="$5" prep="$6" record="$7" round="${8:-0}"
  local c w
  if [ -n "$prep" ] && [ "$BENCH_TRUE_COLD" = "1" ]; then "$prep"; fi
  c=$(time_install "$bin" "$install" "$uninstall" "$pkg")
  w=$(time_install "$bin" "$install" "$uninstall" "$pkg")
  "$bin" "$uninstall" "$pkg" >/dev/null 2>&1 || true
  if [ "$record" = "1" ]; then
    append_sample cold "$key" "$pkg" "$c"
    append_sample warm "$key" "$pkg" "$w"
    emit_per_round "$round" "$key" "$pkg" "$c" "$w"
  fi
}

run_brew_one() {
  # run_brew_one <pkg> <record> [<round>]
  local pkg="$1" record="$2" round="${3:-0}" c
  if [ "$BENCH_TRUE_COLD" = "1" ]; then prep_cold_brew "$pkg"; fi
  c=$(time_brew_install "$pkg")
  brew uninstall "$pkg" >/dev/null 2>&1 || true
  if [ "$record" = "1" ]; then
    append_sample cold brew "$pkg" "$c"
    emit_per_round "$round" brew "$pkg" "$c" "n/a"
  fi
}

# run_round <pkg> <round_idx> <record> <tool1> [<tool2> ...]
#
# round_idx rotates the tool order: tool at position i is
# tools[(round_idx + i) mod N]. round_idx=0 runs the declared order
# (used for warmup), 1..N-1 for the measured rounds — so the first
# measured round always differs from warmup, and every tool gets its
# turn at being "first".
run_round() {
  local pkg="$1" round="$2" record="$3"
  shift 3
  local tools=("$@") n=$# i tool
  for i in $(seq 0 $((n - 1))); do
    tool=${tools[$(((round + i) % n))]}
    case "$tool" in
    mt) run_one "$MALT_BIN" install uninstall "$pkg" mt prep_cold_malt "$record" "$round" ;;
    nb) run_one "$NB_BIN" install remove "$pkg" nb prep_cold_nb "$record" "$round" ;;
    zb) run_one "$ZB_BIN" install uninstall "$pkg" zb prep_cold_zb "$record" "$round" ;;
    brew) run_brew_one "$pkg" "$record" "$round" ;;
    esac
  done
}

# --- finalize ----------------------------------------------------------------
#
# Collapse per-round samples into median (primary reported number), min,
# and stddev. All three get stored as named results and emitted to
# $GITHUB_OUTPUT. The README workflow still reads only `<key>_cold` /
# `<key>_warm`, so adding *_min and *_stddev keys is strictly additive.
finalize_results() {
  local pkg="$1"
  shift
  local tools=("$@") tool samples
  for tool in "${tools[@]}"; do
    samples=$(get_samples cold "$tool" "$pkg")
    if [ -n "$samples" ]; then
      # shellcheck disable=SC2086
      set_result "cold_${tool}_$pkg" "$(median $samples)"
      # shellcheck disable=SC2086
      set_result "cold_${tool}_${pkg}_min" "$(min_of $samples)"
      # shellcheck disable=SC2086
      set_result "cold_${tool}_${pkg}_std" "$(stddev_of $samples)"
      emit_output "${tool}_cold=$(get_result "cold_${tool}_$pkg")s"
      emit_output "${tool}_cold_min=$(get_result "cold_${tool}_${pkg}_min")s"
      emit_output "${tool}_cold_stddev=$(get_result "cold_${tool}_${pkg}_std")s"
      # Pre-formatted "median±stddev s" string for the README workflow —
      # saves the workflow template from concatenating two fields.
      local cold_med cold_disp
      cold_med=$(get_result "cold_${tool}_$pkg")
      cold_disp=$(fmt_disp "$cold_med" "$(get_result "cold_${tool}_${pkg}_std")")
      # Anomaly guard: a peer tool's cold install above the sanity ceiling is
      # a regression in *their* tool, not a comparable number — omit the cell
      # (loud marker) instead of publishing garbage. malt is exempt so a real
      # malt slowdown stays visible rather than hidden.
      if [ "$tool" != "mt" ] && over_threshold "$cold_med" "$BENCH_MAX_COLD"; then
        local tver
        tver=$(get_result "ver_$tool")
        warn "ANOMALY: $tool ${tver:+$tver }cold $pkg = ${cold_med}s > BENCH_MAX_COLD=${BENCH_MAX_COLD}s — omitting cell"
        gha_warning "$tool ${tver:+($tver) }cold install of $pkg regressed: ${cold_med}s exceeds ${BENCH_MAX_COLD}s ceiling — cell omitted"
        cold_disp="⚠️ n/a (>${BENCH_MAX_COLD}s)"
      fi
      emit_output "${tool}_cold_disp=$cold_disp"
    fi
    # brew has no warm column in the comparison — only cold gets recorded.
    if [ "$tool" != "brew" ]; then
      samples=$(get_samples warm "$tool" "$pkg")
      if [ -n "$samples" ]; then
        # shellcheck disable=SC2086
        set_result "warm_${tool}_$pkg" "$(median $samples)"
        # shellcheck disable=SC2086
        set_result "warm_${tool}_${pkg}_min" "$(min_of $samples)"
        # shellcheck disable=SC2086
        set_result "warm_${tool}_${pkg}_std" "$(stddev_of $samples)"
        emit_output "${tool}_warm=$(get_result "warm_${tool}_$pkg")s"
        emit_output "${tool}_warm_min=$(get_result "warm_${tool}_${pkg}_min")s"
        emit_output "${tool}_warm_stddev=$(get_result "warm_${tool}_${pkg}_std")s"
        emit_output "${tool}_warm_disp=$(fmt_disp "$(get_result "warm_${tool}_$pkg")" "$(get_result "warm_${tool}_${pkg}_std")")"
      fi
    fi
  done
}

# --- orchestration -----------------------------------------------------------

run_bench_for() {
  local pkg="$1" r
  # Build the active tool list. Declared order here also controls the
  # warmup order; measured rounds rotate from it.
  local tools=(mt)
  if [ "$SKIP_OTHERS" != "1" ]; then
    [ -x "$NB_BIN" ] && tools+=(nb)
    [ -x "$ZB_BIN" ] && tools+=(zb)
  fi
  if [ "$SKIP_BREW" != "1" ] && command -v brew >/dev/null 2>&1; then
    tools+=(brew)
  fi

  info "${BOLD}benchmark: $pkg (×$BENCH_ROUNDS rounds + warmup, median ±σ)${RESET}"

  info "warmup (discarded): ${tools[*]}"
  run_round "$pkg" 0 0 "${tools[@]}"

  for r in $(seq 1 "$BENCH_ROUNDS"); do
    info "round $r/$BENCH_ROUNDS"
    run_round "$pkg" "$r" 1 "${tools[@]}"
  done

  finalize_results "$pkg" "${tools[@]}"
}

# --- run ---------------------------------------------------------------------

# Allow sourcing (BENCH_LIB=1) for unit tests without running the bench.
# `return` succeeds only when sourced; the `exit 0` runs when executed
# directly — reachable, despite shellcheck's static guess.
if [ "${BENCH_LIB:-0}" = "1" ]; then
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

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
fi

set_result "size_mt" "$(size_of "$MALT_BIN")"
set_result "size_nb" "$(size_of "$NB_BIN")"
set_result "size_zb" "$(size_of "$ZB_BIN")"
if command -v brew >/dev/null 2>&1; then
  set_result "size_brew" "$(size_of "$(command -v brew)")"
else
  set_result "size_brew" "n/a"
fi
emit_output "mt_size=$(get_result size_mt)"
emit_output "nb_size=$(get_result size_nb)"
emit_output "zb_size=$(get_result size_zb)"
# brew_size omitted: `which brew` is the shell wrapper, not a meaningful size.

# Benchmarked versions — pinned peer release tags (malt is the local build).
# Surfaced in the README column headers so a version bump shows up loudly as
# a diff in the weekly benchmark PR, and a stale comparison can't hide.
emit_output "mt_ver=$(get_result ver_mt)"
emit_output "nb_ver=$(get_result ver_nb)"
emit_output "zb_ver=$(get_result ver_zb)"

for pkg in "${PACKAGES[@]}"; do
  run_bench_for "$pkg"
done

# --- summary -----------------------------------------------------------------

cell() {
  local v="${1:-}"
  if [ -n "$v" ]; then printf "%ss" "$v"; else printf "—"; fi
}

# cell_std "<median>" "<stddev>" — "1.234±0.021s" or "—" if median missing.
# Used by the terminal summary; for $GITHUB_OUTPUT use fmt_disp (defined
# alongside the other stat helpers so finalize_results can call it).
cell_std() {
  fmt_disp "$@"
}

printf "\n%sBinary Size%s\n" "$BOLD" "$RESET"
printf "  %-10s %s\n" "malt" "$(get_result size_mt)"
printf "  %-10s %s\n" "nanobrew" "$(get_result size_nb)"
printf "  %-10s %s\n" "zerobrew" "$(get_result size_zb)"
# brew omitted: `which brew` is the shell wrapper, not a meaningful size.

printf "\n%sBenchmarked versions%s\n" "$BOLD" "$RESET"
printf "  %-10s %s\n" "malt" "$(get_result ver_mt)"
printf "  %-10s %s\n" "nanobrew" "$(get_result ver_nb)"
printf "  %-10s %s\n" "zerobrew" "$(get_result ver_zb)"

printf "\n%sCold Install%s (median ±σ)\n" "$BOLD" "$RESET"
printf "  %-14s %-16s %-16s %-16s %-16s\n" Package malt nanobrew zerobrew brew
for pkg in "${PACKAGES[@]}"; do
  printf "  %-14s %-16s %-16s %-16s %-16s\n" "$pkg" \
    "$(cell_std "$(get_result "cold_mt_$pkg")" "$(get_result "cold_mt_${pkg}_std")")" \
    "$(cell_std "$(get_result "cold_nb_$pkg")" "$(get_result "cold_nb_${pkg}_std")")" \
    "$(cell_std "$(get_result "cold_zb_$pkg")" "$(get_result "cold_zb_${pkg}_std")")" \
    "$(cell_std "$(get_result "cold_brew_$pkg")" "$(get_result "cold_brew_${pkg}_std")")"
done

printf "\n%sCold Install%s (min)\n" "$BOLD" "$RESET"
printf "  %-14s %-10s %-10s %-10s %-10s\n" Package malt nanobrew zerobrew brew
for pkg in "${PACKAGES[@]}"; do
  printf "  %-14s %-10s %-10s %-10s %-10s\n" "$pkg" \
    "$(cell "$(get_result "cold_mt_${pkg}_min")")" \
    "$(cell "$(get_result "cold_nb_${pkg}_min")")" \
    "$(cell "$(get_result "cold_zb_${pkg}_min")")" \
    "$(cell "$(get_result "cold_brew_${pkg}_min")")"
done

printf "\n%sWarm Install%s (median ±σ)\n" "$BOLD" "$RESET"
printf "  %-14s %-16s %-16s %-16s\n" Package malt nanobrew zerobrew
for pkg in "${PACKAGES[@]}"; do
  printf "  %-14s %-16s %-16s %-16s\n" "$pkg" \
    "$(cell_std "$(get_result "warm_mt_$pkg")" "$(get_result "warm_mt_${pkg}_std")")" \
    "$(cell_std "$(get_result "warm_nb_$pkg")" "$(get_result "warm_nb_${pkg}_std")")" \
    "$(cell_std "$(get_result "warm_zb_$pkg")" "$(get_result "warm_zb_${pkg}_std")")"
done

printf "\n%sWarm Install%s (min)\n" "$BOLD" "$RESET"
printf "  %-14s %-10s %-10s %-10s\n" Package malt nanobrew zerobrew
for pkg in "${PACKAGES[@]}"; do
  printf "  %-14s %-10s %-10s %-10s\n" "$pkg" \
    "$(cell "$(get_result "warm_mt_${pkg}_min")")" \
    "$(cell "$(get_result "warm_nb_${pkg}_min")")" \
    "$(cell "$(get_result "warm_zb_${pkg}_min")")"
done

ok "done"
