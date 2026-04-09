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

# Pre-push hook: everything that CI checks
pre-push: fmt-check test
    @echo "All pre-push checks passed."

# Install git hooks
hooks-install:
    @echo '#!/bin/sh' > .git/hooks/pre-push
    @echo 'just pre-push' >> .git/hooks/pre-push
    @chmod +x .git/hooks/pre-push
    @echo "pre-push hook installed."

# Remove git hooks
hooks-uninstall:
    @rm -f .git/hooks/pre-push
    @echo "pre-push hook removed."
