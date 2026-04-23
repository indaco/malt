set unstable := true

# Default recipe
default:
    @just --list

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

# Build the project
[group('build')]
build:
    zig build

# Build with ReleaseSafe optimization
[group('build')]
build-release:
    zig build -Doptimize=ReleaseSafe

# Build universal binary (macOS arm64 + x86_64)
[group('build')]
build-universal:
    zig build universal -Doptimize=ReleaseSafe

# Install malt globally (builds from source, installs to /usr/local/bin)
[group('build')]
install:
    ./scripts/install.sh

# ---------------------------------------------------------------------------
# Test & coverage
# ---------------------------------------------------------------------------

# Run unit tests
[group('test')]
test:
    zig build test --summary all

# Run tests under kcov, print line-coverage percentage, and refresh
# the README badge SVG at .github/badges/coverage.svg.
# HTML report lands at coverage/merged/kcov-merged/index.html.

# Requires kcov (brew install kcov). Internet is needed for the badge fetch.
[group('test')]
coverage:
    ./scripts/coverage.sh

# ---------------------------------------------------------------------------
# Format & lint
# ---------------------------------------------------------------------------

# Check formatting
[group('lint')]
fmt-check:
    zig fmt --check src/ tests/

# Fix formatting
[group('lint')]
fmt:
    zig fmt src/ tests/

# Requires shellcheck + shfmt on PATH (`brew install shellcheck shfmt`).
# Project convention: 2-space indent across every shell script.

# Lint shell scripts with shellcheck + shfmt.
[group('lint')]
shell-lint:
    shellcheck scripts/*.sh scripts/lib/*.sh scripts/test/*.sh scripts/e2e/*.sh scripts/regressions/*.sh
    shfmt -i 2 -d scripts/*.sh scripts/lib/*.sh scripts/test/*.sh scripts/e2e/*.sh scripts/regressions/*.sh

# Apply shfmt formatting in place. Run after a failing `shell-lint`.
[group('lint')]
shell-fmt:
    shfmt -i 2 -w scripts/*.sh scripts/lib/*.sh scripts/test/*.sh scripts/e2e/*.sh scripts/regressions/*.sh

# Lint: format check + build + test
[group('lint')]
lint: fmt-check build test

# ---------------------------------------------------------------------------
# Git hooks
# ---------------------------------------------------------------------------
# Pre-commit hook: auto-format staged .zig + .sh files in place, re-stage
# them, and shellcheck the staged shell set so unfixable lint blocks the
# commit. Note: if you `git add -p` partial hunks of a file, this will
# pick up the unstaged hunks too — a known limitation of format-on-commit
# hooks.
[group('hooks')]
pre-commit:
    #!/usr/bin/env bash
    set -euo pipefail

    zig_files=()
    while IFS= read -r f; do
        zig_files+=("$f")
    done < <(git diff --cached --name-only --diff-filter=ACM | grep -E '\.zig$' || true)
    if [ ${#zig_files[@]} -gt 0 ]; then
        zig fmt "${zig_files[@]}"
        git add "${zig_files[@]}"
        echo "Auto-formatted ${#zig_files[@]} staged .zig file(s)."
    fi

    sh_files=()
    while IFS= read -r f; do
        sh_files+=("$f")
    done < <(git diff --cached --name-only --diff-filter=ACM | grep -E '\.sh$' || true)
    if [ ${#sh_files[@]} -gt 0 ]; then
        shfmt -i 2 -w "${sh_files[@]}"
        git add "${sh_files[@]}"
        echo "Auto-formatted ${#sh_files[@]} staged .sh file(s)."
        # shellcheck after shfmt — anything left is not auto-fixable and
        # should block the commit so issues don't slip past local hooks.
        shellcheck "${sh_files[@]}"
    fi

# Pre-push hook: everything that CI checks, plus shell-lint. When the
# diff vs origin/main touches the install/extract/download surface,
# additionally runs the heavy install smoke (~7-10 min, ~750 MB).
# Set MALT_SKIP_SMOKE=1 to bypass the smoke check (e.g. for a doc-only

# follow-up push you've already verified).
[group('hooks')]
pre-push: fmt-check test shell-lint
    #!/usr/bin/env bash
    set -euo pipefail
    if [ "${MALT_SKIP_SMOKE:-0}" = "1" ]; then
        echo "▸ MALT_SKIP_SMOKE=1 — skipping install smoke"
    elif git rev-parse --verify origin/main >/dev/null 2>&1 \
        && git diff --name-only origin/main...HEAD 2>/dev/null \
        | grep -qE '^(src/cli/install\.zig|src/core/bottle\.zig|src/core/cask\.zig|src/fs/archive\.zig|src/fs/atomic\.zig|src/net/client\.zig|src/net/ghcr\.zig|scripts/local-smoke-install\.sh)$'; then
        echo "▸ Install/extract/download surface touched — running install smoke"
        ./scripts/local-smoke-install.sh
    else
        echo "▸ Install/extract/download surface untouched — skipping install smoke"
    fi
    echo "All pre-push checks passed."

# Local-only install smoke. Heavy: ~7-10 min, downloads ~750 MB.
# Sandboxes into a temp MALT_PREFIX/MALT_CACHE; never touches /opt/malt.

# Auto-runs from `pre-push` when install/extract/download paths change.
[group('test')]
smoke-install: build
    @./scripts/local-smoke-install.sh

# Install git hooks (pre-commit + pre-push)
[group('hooks')]
hooks-install:
    @echo '#!/bin/sh' > .git/hooks/pre-commit
    @echo 'just pre-commit' >> .git/hooks/pre-commit
    @chmod +x .git/hooks/pre-commit
    @echo '#!/bin/sh' > .git/hooks/pre-push
    @echo 'just pre-push' >> .git/hooks/pre-push
    @chmod +x .git/hooks/pre-push
    @echo "pre-commit and pre-push hooks installed."

# Remove git hooks
[group('hooks')]
hooks-uninstall:
    @rm -f .git/hooks/pre-commit .git/hooks/pre-push
    @echo "pre-commit and pre-push hooks removed."

# ---------------------------------------------------------------------------
# Benchmarks
# ---------------------------------------------------------------------------
# Run local benchmarks against malt + peer tools (tree, wget, ffmpeg by default).
# Pass extra package names as args; set env vars on the command itself

# (e.g. `BENCH_TRUE_COLD=1 just bench`, `SKIP_OTHERS=1 just bench wget`).
[group('bench')]
bench *args:
    ./scripts/bench.sh {{ args }}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
# Remove Zig build artifacts (.zig-cache, zig-out, coverage) and test
# scratch directories under /tmp. Handles read-only test fixtures that

# defeat a plain `rm -rf`.
[group('clean')]
clean:
    ./scripts/clean.sh

# ---------------------------------------------------------------------------
# Docs & media
# ---------------------------------------------------------------------------

# Record the README demo gif via VHS into docs/demo.gif.
[group('docs')]
record-demo:
    ./scripts/record-demo.sh

# Regenerate docs/contrast-previews/*.png for the four palette cells
# (dark|light) × (truecolor|basic). Internal: only run after editing
# the palette cells in src/ui/color.zig or the sample text in
# scripts/contrast_preview.sh. Requires freeze on PATH

# (`brew install charmbracelet/tap/freeze`).
[group('docs')]
[private]
contrast-previews:
    #!/usr/bin/env bash
    set -euo pipefail
    command -v freeze >/dev/null || {
        echo "error: freeze not found — brew install charmbracelet/tap/freeze" >&2
        exit 1
    }
    out=docs/contrast-previews
    mkdir -p "$out"
    # Dark variants take freeze's default charm theme + background.
    THEME=dark  TIER=truecolor freeze -x "bash scripts/contrast_preview.sh" \
        -o "$out/dark-truecolor.png"
    THEME=dark  TIER=basic     freeze -x "bash scripts/contrast_preview.sh" \
        -o "$out/dark-basic.png"
    # Light variants force the github theme + white background so plain
    # (uncoloured) body text renders dark on white instead of charm's
    # light-grey default foreground.
    THEME=light TIER=truecolor freeze -x "bash scripts/contrast_preview.sh" \
        -t github -b '#ffffff' -o "$out/light-truecolor.png"
    THEME=light TIER=basic     freeze -x "bash scripts/contrast_preview.sh" \
        -t github -b '#ffffff' -o "$out/light-basic.png"
    echo "Regenerated 4 contrast previews in $out/."
