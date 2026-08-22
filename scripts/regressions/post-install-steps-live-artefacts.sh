#!/usr/bin/env bash
# Regression guard for the native `post_install_steps` executor, driven by real
# installs.
#
# Its sibling `native-step-coverage-llvm-post-install.sh` is a static guard: it
# proves the step types are registered and their unit tests run. That cannot see
# what only a live keg has. The bug that motivated this script is the example —
# redis declares `set_permissions` on `<prefix>/lib/redis/modules/*`, and in a
# linked prefix those are symlinks into the Cellar. Unit fixtures are plain
# files, so every test passed while a real `mt install redis` failed with a
# sandbox violation. `chmod(1)` follows a symlink it is handed; the executor now
# does too, and this script is what proves it against the real layout.
#
# One formula per step type, each asserted on the artefact the step is supposed
# to leave behind — never merely on "install exited 0", because the pre-fix
# failure mode was a clean exit with the work skipped.
#
#   redis  set_permissions  modes applied through the prefix's own symlinks
#   nginx  move             docroot relocated out of the keg, source consumed
#   ruby   change_dylib_id  install name rewritten (+ the `on: macos` guard)
#
# Formulas whose bottles run to hundreds of megabytes (llvm, gcc, bazel) are
# behind MALT_REGRESSION_SLOW=1 so the default path stays a few minutes.
#
# Usage: scripts/regressions/post-install-steps-live-artefacts.sh
#        MALT_REGRESSION_SLOW=1 scripts/regressions/post-install-steps-live-artefacts.sh
# Requirements: built `mt` binary, network access to formulae.brew.sh + ghcr.io.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/mt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

if [[ -z "${MALT_GITHUB_TOKEN:-}" ]] && command -v gh >/dev/null 2>&1; then
  MALT_GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
  export MALT_GITHUB_TOKEN
fi

# Short on purpose: a long prefix exceeds the Mach-O patch budget and every
# install emits a relocation warning that has nothing to do with these steps.
PREFIX="/tmp/mt_pis"
export MALT_PREFIX="$PREFIX"
# Overridable so a warm cache can be reused; it lives outside PREFIX and
# therefore survives the cleanup trap.
export MALT_CACHE="${MALT_CACHE:-$PREFIX/cache}"
export NO_COLOR=1 MALT_NO_EMOJI=1
rm -rf "$PREFIX"
mkdir -p "$PREFIX/bin"
trap 'rm -rf "$PREFIX"' EXIT

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  exit 1
}

LOG="$PREFIX/install.log"

# install <formula> — refuses the partial-skip envelope as well as a non-zero
# exit. The pre-fix bug exited 0 and printed a warning; both must be gone.
install_clean() {
  local formula="$1"
  printf '▸ mt install %s\n' "$formula"
  "$BIN" install "$formula" >"$LOG" 2>&1 || {
    tail -20 "$LOG" >&2
    fail "$formula: install failed"
  }
  # Scoped to the formula under test. A transitive dependency can fail its own
  # post_install for reasons that have nothing to do with these step types —
  # fontconfig's `run` step is a known one, its fc-cache spawning before
  # gettext is linked — and swallowing that silently is as wrong as failing on
  # it, so it is reported and stepped over.
  if grep -qE "($formula: post_install partially skipped|post_install DSL failed for $formula|use --use-system-ruby=$formula)" "$LOG"; then
    grep -B2 -A4 -E "($formula: post_install partially skipped|post_install DSL failed for $formula)" "$LOG" >&2
    fail "$formula: post_install did not run natively"
  fi
  if grep -qE 'partially skipped|post_install DSL failed' "$LOG"; then
    printf '  ! a dependency of %s failed its own post_install (not one of the step types under test):\n' "$formula" >&2
    grep -E 'partially skipped|post_install DSL failed|\[system_command_failed\]' "$LOG" | sed 's/^/      /' >&2
  fi
  grep -q "post_install completed for $formula" "$LOG" ||
    fail "$formula: no post_install completion line"
  pass "$formula: post_install completed natively, no fallback envelope"
}

# ── set_permissions, applied through the prefix's link farm ──────────
install_clean redis
modules="$PREFIX/lib/redis/modules"
[[ -d "$modules" ]] || fail "redis: $modules missing"
found=0
for link in "$modules"/*.so; do
  [[ -e "$link" ]] || continue
  found=1
  # The declared mode is 0755 and the file behind the link is what must carry
  # it; asserting on the link itself would pass without the step running.
  [[ -L "$link" ]] || fail "redis: $link is not the expected prefix symlink"
  mode=$(stat -f '%Lp' "$(readlink "$link")")
  [[ "$mode" == "755" ]] || fail "redis: $(basename "$link") is $mode, expected 755"
done
[[ "$found" == "1" ]] || fail "redis: no modules found to check"
pass "redis: 0755 applied to the real files behind the prefix symlinks"

# ── move ─────────────────────────────────────────────────────────────
install_clean nginx
[[ -f "$PREFIX/var/www/index.html" ]] || fail "nginx: docroot not relocated to <prefix>/var/www"
pass "nginx: docroot relocated into the prefix"
if compgen -G "$PREFIX/Cellar/nginx/*/libexec/html" >/dev/null; then
  fail "nginx: source survived the move — it was copied, not moved"
fi
pass "nginx: source consumed by the move"
if compgen -G "$PREFIX/var/www.malt-replaced" >/dev/null; then
  fail "nginx: swap-aside scaffolding left behind in the prefix"
fi
pass "nginx: no swap-aside scaffolding left behind"

# ── change_dylib_id, and the `on: macos` guard that gates it ─────────
install_clean ruby
dylib=$(find "$PREFIX/Cellar/ruby" -name 'libruby.*.dylib' -type f 2>/dev/null | head -1)
[[ -n "$dylib" ]] || fail "ruby: no libruby dylib in the keg"
id=$(otool -D "$dylib" 2>/dev/null | tail -1)
[[ "$id" == "$PREFIX/opt/ruby"*/lib/libruby.*.dylib ]] ||
  fail "ruby: install name is '$id', expected the prefix's opt path"
pass "ruby: install name rewritten to the opt path"

# ── heavyweight bottles, opt-in ──────────────────────────────────────
if [[ -n "${MALT_REGRESSION_SLOW:-}" ]]; then
  # configure_clang_system — the originally reported failure. Six files, each
  # one line naming the SDK; the Darwin major and the macOS major differ, and
  # reading one sysctl for both is the mistake this pins.
  install_clean llvm
  kernel=$(uname -r | cut -d. -f1)
  macos=$(sw_vers -productVersion | cut -d. -f1)
  want="-isysroot /Library/Developer/CommandLineTools/SDKs/MacOSX${macos}.sdk"
  for arch in arm64 x86_64 aarch64; do
    for target in "darwin${kernel}" "macosx${macos}"; do
      cfg="$PREFIX/etc/clang/${arch}-apple-${target}.cfg"
      [[ -f "$cfg" ]] || fail "llvm: $cfg missing"
      [[ "$(cat "$cfg")" == "$want" ]] || fail "llvm: $cfg reads '$(cat "$cfg")', expected '$want'"
    done
  done
  pass "llvm: six clang configs written, named from both the kernel and macOS majors"

  # install_gzipped_executable — the archive must be consumed and the unpacked
  # binary left executable.
  install_clean bazel
  real=$(find "$PREFIX/Cellar/bazel" -name 'bazel-real' -type f 2>/dev/null | head -1)
  [[ -n "$real" ]] || fail "bazel: bazel-real was never unpacked"
  [[ "$(stat -f '%Lp' "$real")" == "755" ]] || fail "bazel: bazel-real is not 0755"
  if find "$PREFIX/Cellar/bazel" -name 'bazel-real.gz' | grep -q .; then
    fail "bazel: the gzipped source survived — it must be unlinked"
  fi
  pass "bazel: executable unpacked 0755 and the archive consumed"

  # configure_gcc_runtime — a correct macOS no-op, which must still not route
  # the formula into the partial-skip envelope.
  install_clean gcc
  pass "gcc: the Linux-only step stayed a clean no-op"
fi

echo "OK: every implemented post_install step left its artefact behind"
