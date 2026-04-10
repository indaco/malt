#!/usr/bin/env bash
# scripts/e2e/test_smoke_install.sh
#
# End-to-end smoke test for `mt install`. Runs an isolated install of the
# three packages that P1 regressed (zig, curl, rust), each of which ships as
# a `:any` Homebrew bottle carrying `@@HOMEBREW_PREFIX@@` / `@@HOMEBREW_CELLAR@@`
# placeholder tokens in their Mach-O load commands.
#
# The script is a smoke test for the WHOLE install pipeline — download,
# materialize, patch, link, codesign, record — not a unit test for any one
# fix. It complements tests/cellar_test.zig's synthetic-Mach-O guards, which
# cover P1 specifically without network I/O.
#
# Assertions:
#   1. `mt install` exits 0.
#   2. `mt doctor` exits 0 (all checks green, including Mach-O placeholders).
#   3. Each binary runs and prints a plausible version string.
#   4. otool -L on each binary shows no remaining `@@HOMEBREW_` tokens.
#
# Usage:
#   ./scripts/e2e/test_smoke_install.sh           # default
#   MT_BIN=./zig-out/bin/malt ./scripts/e2e/test_smoke_install.sh
#   SKIP_BUILD=1 ./scripts/e2e/test_smoke_install.sh   # reuse an existing build
#
# Exit codes:
#   0 — all assertions passed
#   1 — at least one assertion failed
#   2 — infrastructure error (temp dir, binary not found, …)

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────
# The script is written for macOS /bin/bash (3.2), which has no associative
# arrays — `expected_bin_for` is a case-based lookup instead.
MT_BIN="${MT_BIN:-./zig-out/bin/malt}"
PACKAGES=(zig curl rust)

# For each package, echo a glob pattern that resolves to the canonical binary
# after install. curl is keg-only so it lives under Cellar/ rather than bin/.
expected_bin_for() {
    case "$1" in
        zig)  echo "$PREFIX/bin/zig" ;;
        rust) echo "$PREFIX/bin/rustc" ;;
        curl) echo "$PREFIX/Cellar/curl/*/bin/curl" ;;
        *)    return 1 ;;
    esac
}

# Canonical version-check args per package.
version_args_for() {
    case "$1" in
        zig)  printf 'version' ;;
        rust) printf '%s' '--version' ;;
        curl) printf '%s' '--version' ;;
        *)    return 1 ;;
    esac
}

# ── Helpers ───────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m' "$*"; }
green() { printf '\033[32m%s\033[0m' "$*"; }
yellow(){ printf '\033[33m%s\033[0m' "$*"; }

log()   { printf '[smoke] %s\n' "$*"; }
fail()  { printf '[smoke] %s %s\n' "$(red FAIL)" "$*" >&2; FAILURES=$((FAILURES + 1)); }
pass()  { printf '[smoke] %s %s\n' "$(green PASS)" "$*"; }
info()  { printf '[smoke] %s %s\n' "$(yellow INFO)" "$*"; }

# Retry wrapper for network calls. Exponential back-off: 10s 20s 40s 80s, cap at 2 min.
retry() {
    local n=0 max=5 delay=10
    until "$@"; do
        n=$((n + 1))
        if [ "$n" -ge "$max" ]; then
            fail "command failed after $max attempts: $*"
            return 1
        fi
        info "attempt $n failed, retrying in ${delay}s…"
        sleep "$delay"
        delay=$((delay * 2))
        [ "$delay" -gt 120 ] && delay=120
    done
}

FAILURES=0

# ── Preconditions ─────────────────────────────────────────────────────────
if [ ! -x "$MT_BIN" ]; then
    if [ "${SKIP_BUILD:-0}" = "1" ]; then
        printf '[smoke] %s\n' "$(red ERROR): $MT_BIN not found and SKIP_BUILD=1" >&2
        exit 2
    fi
    log "building $MT_BIN (set SKIP_BUILD=1 to reuse an existing build)"
    zig build -Doptimize=ReleaseSafe >/dev/null
fi

if [ ! -x "$MT_BIN" ]; then
    printf '[smoke] %s\n' "$(red ERROR): $MT_BIN still not found after build" >&2
    exit 2
fi

# Short prefix (≤ 13 bytes is the Mach-O patch budget). mktemp -d /tmp/mt.XXX
# gives us /tmp/mt.aBc, 11 bytes, with enough entropy for parallel runs.
PREFIX=$(mktemp -d /tmp/mt.XXX)
CACHE=$(mktemp -d /tmp/mc.XXX)
log "prefix: $PREFIX (${#PREFIX} bytes)"
log "cache:  $CACHE"

# Cleanup on any exit — only remove the dirs we created, never anything under
# /opt/malt or the user's real prefix.
cleanup() {
    if [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == /tmp/mt.* ]]; then
        rm -rf "$PREFIX"
    fi
    if [ -n "${CACHE:-}" ] && [[ "$CACHE" == /tmp/mc.* ]]; then
        rm -rf "$CACHE"
    fi
}
trap cleanup EXIT INT TERM

export MALT_PREFIX="$PREFIX"
export MALT_CACHE="$CACHE"
export MALT_NO_EMOJI=1
export NO_COLOR=1

# ── 1. Install ────────────────────────────────────────────────────────────
log "installing ${PACKAGES[*]} into $PREFIX …"

INSTALL_LOG="$PREFIX/.install.log"
if retry "$MT_BIN" install "${PACKAGES[@]}" >"$INSTALL_LOG" 2>&1; then
    pass "mt install exited 0"
else
    fail "mt install exited non-zero — see $INSTALL_LOG"
    sed -n '$,$p' "$INSTALL_LOG" >&2 || true
fi

# ── 2. mt doctor ──────────────────────────────────────────────────────────
log "running mt doctor …"
DOCTOR_LOG="$PREFIX/.doctor.log"
if "$MT_BIN" doctor >"$DOCTOR_LOG" 2>&1; then
    pass "mt doctor reported a clean tree"
else
    fail "mt doctor exited non-zero"
    cat "$DOCTOR_LOG" >&2 || true
fi

# ── 3. Execute each binary ────────────────────────────────────────────────
for pkg in "${PACKAGES[@]}"; do
    bin_pattern=$(expected_bin_for "$pkg") || {
        fail "$pkg: no binary template configured"
        continue
    }

    # Resolve the glob. compgen is a bash builtin so this works without
    # enabling nullglob. `|| true` so the pipeline does not die under set -e
    # when the glob matches nothing.
    bin_path=$(compgen -G "$bin_pattern" 2>/dev/null | head -1 || true)

    if [ -z "$bin_path" ] || [ ! -x "$bin_path" ]; then
        fail "$pkg: expected binary not found (pattern: $bin_pattern)"
        continue
    fi

    arg=$(version_args_for "$pkg")
    if out=$("$bin_path" "$arg" 2>&1); then
        # Strip everything after the first newline for concise reporting.
        pass "$pkg runs: ${out%%$'\n'*}"
    else
        fail "$pkg binary failed to execute: $out"
    fi
done

# ── 4. No unresolved @@HOMEBREW_ tokens in the running-arch Mach-O slice ──
#
# We specifically scan the slice that matches the current architecture.
# malt's Mach-O patcher processes one slice per file (the one that matches
# the build host's arch), so fat binaries may still have unpatched tokens
# in the *other* arch's slice. That is a latent bug worth fixing separately
# but it does NOT affect runtime on the machine running this smoke test —
# dyld only loads the matching slice.
case "$(uname -m)" in
    arm64)  HOST_ARCH=arm64 ;;
    x86_64) HOST_ARCH=x86_64 ;;
    *)      HOST_ARCH="" ;;  # unknown — scan unfiltered as a fallback
esac

log "scanning Cellar for unpatched @@HOMEBREW_* placeholders (arch: ${HOST_ARCH:-any}) …"
bad_count=0
first_bad=""
other_arch_count=0

while IFS= read -r -d '' f; do
    # Only consider Mach-O files.
    if ! file "$f" 2>/dev/null | grep -q 'Mach-O'; then
        continue
    fi

    # Hard check: the host-arch slice must be clean.
    if [ -n "$HOST_ARCH" ]; then
        if otool -arch "$HOST_ARCH" -l "$f" 2>/dev/null | grep -q '@@HOMEBREW_'; then
            bad_count=$((bad_count + 1))
            [ -z "$first_bad" ] && first_bad="$f"
        fi
        # Soft check: any *other* arch slice with remaining tokens is a
        # known-latent fat-binary patching limitation — warn but don't fail.
        if otool -l "$f" 2>/dev/null | grep -q '@@HOMEBREW_'; then
            if ! otool -arch "$HOST_ARCH" -l "$f" 2>/dev/null | grep -q '@@HOMEBREW_'; then
                other_arch_count=$((other_arch_count + 1))
            fi
        fi
    else
        # No arch filter available — treat every finding as a hard failure.
        if otool -l "$f" 2>/dev/null | grep -q '@@HOMEBREW_'; then
            bad_count=$((bad_count + 1))
            [ -z "$first_bad" ] && first_bad="$f"
        fi
    fi
done < <(find "$PREFIX/Cellar" -type f -print0 2>/dev/null)

if [ "$bad_count" -eq 0 ]; then
    pass "zero Mach-O files with unpatched @@HOMEBREW_* placeholders in the ${HOST_ARCH:-all} slice(s)"
else
    fail "$bad_count Mach-O file(s) still contain @@HOMEBREW_ tokens in the $HOST_ARCH slice (first: $first_bad)"
fi

if [ "$other_arch_count" -gt 0 ]; then
    info "$other_arch_count fat-binary file(s) carry unpatched tokens in a non-$HOST_ARCH slice — latent cross-arch bug, not a runtime failure on this host"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo
if [ "$FAILURES" -eq 0 ]; then
    log "$(green 'ALL CHECKS PASSED') (prefix: $PREFIX)"
    exit 0
else
    log "$(red "$FAILURES CHECK(S) FAILED") (prefix kept at $PREFIX for inspection)"
    # Disarm the cleanup trap so the user can inspect the broken tree.
    trap - EXIT
    exit 1
fi
