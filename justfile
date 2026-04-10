# Default recipe
default:
    @just --list

# Build the project
build:
    zig build

# Build with ReleaseSafe optimization
build-release:
    zig build -Doptimize=ReleaseSafe

# Build universal binary (macOS arm64 + x86_64)
build-universal:
    zig build universal -Doptimize=ReleaseSafe

# Install malt globally (builds from source, installs to /usr/local/bin)
install:
    ./scripts/install.sh

# Run unit tests
test:
    zig build test

# Check formatting
fmt-check:
    zig fmt --check src/ tests/

# Fix formatting
fmt:
    zig fmt src/ tests/

# Lint: format check + build + test
lint:
    zig fmt --check src/ tests/
    zig build
    zig build test

# Pre-commit hook: auto-format staged .zig files in place and re-stage them
# so the formatted version is what actually lands in the commit.
# Note: if you `git add -p` partial hunks of a file, this will pick up the
# unstaged hunks too — a known limitation of format-on-commit hooks.
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

# Pre-push hook: everything that CI checks
pre-push: fmt-check test
    @echo "All pre-push checks passed."

# Install git hooks (pre-commit + pre-push)
hooks-install:
    @echo '#!/bin/sh' > .git/hooks/pre-commit
    @echo 'just pre-commit' >> .git/hooks/pre-commit
    @chmod +x .git/hooks/pre-commit
    @echo '#!/bin/sh' > .git/hooks/pre-push
    @echo 'just pre-push' >> .git/hooks/pre-push
    @chmod +x .git/hooks/pre-push
    @echo "pre-commit and pre-push hooks installed."

# Remove git hooks
hooks-uninstall:
    @rm -f .git/hooks/pre-commit .git/hooks/pre-push
    @echo "pre-commit and pre-push hooks removed."
