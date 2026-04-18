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

# Pre-commit hook: auto-format staged .zig files in place and re-stage them
# so the formatted version is what actually lands in the commit.
# Note: if you `git add -p` partial hunks of a file, this will pick up the
# unstaged hunks too — a known limitation of format-on-commit hooks.
[group('hooks')]
pre-commit:
    #!/usr/bin/env bash
    set -euo pipefail
    files=()
    while IFS= read -r f; do
        files+=("$f")
    done < <(git diff --cached --name-only --diff-filter=ACM | grep -E '\.zig$' || true)
    if [ ${#files[@]} -eq 0 ]; then
        exit 0
    fi
    zig fmt "${files[@]}"
    git add "${files[@]}"
    echo "Auto-formatted ${#files[@]} staged .zig file(s)."

# Pre-push hook: everything that CI checks, plus shell-lint.
[group('hooks')]
pre-push: fmt-check test shell-lint
    @echo "All pre-push checks passed."

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
    ./scripts/bench.sh {{args}}

# ---------------------------------------------------------------------------
# Docs & media
# ---------------------------------------------------------------------------

# Record the README demo gif via VHS into docs/demo.gif.
[group('docs')]
record-demo:
    ./scripts/record-demo.sh
