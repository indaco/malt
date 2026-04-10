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

# Run tests under kcov, print line-coverage percentage, and refresh
# the README badge SVG at .github/badges/coverage.svg.
# HTML report lands at coverage/merged/kcov-merged/index.html.
# Requires kcov (brew install kcov). Internet is needed for the badge fetch.
coverage:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v kcov >/dev/null 2>&1; then
        echo "error: kcov not found. Install with: brew install kcov" >&2
        exit 1
    fi
    rm -rf coverage
    mkdir -p coverage
    zig build test-bin
    # Only report coverage for files under the project's src/ directory.
    # --include-path takes an absolute path and is more reliable than --include-pattern.
    src_dir="$(pwd)/src"
    # Run kcov once per test binary into a shared outdir
    for bin in zig-out/test-bin/*; do
        # Skip .dSYM debug bundles and any non-regular files
        [ -f "$bin" ] || continue
        [ -x "$bin" ] || continue
        echo "→ kcov: $(basename "$bin")"
        kcov --include-path="$src_dir" coverage "$bin" >/dev/null
    done
    # kcov 43 on macOS doesn't reliably auto-merge, so do it explicitly.
    # The per-binary reports are in hash-suffixed dirs (e.g. cellar_test.a934ecd0).
    shopt -s nullglob
    per_bin_dirs=(coverage/*_test.*)
    shopt -u nullglob
    if [ ${#per_bin_dirs[@]} -eq 0 ]; then
        echo "error: kcov produced no per-binary reports" >&2
        exit 1
    fi
    kcov --merge coverage/merged "${per_bin_dirs[@]}" >/dev/null
    report="coverage/merged/kcov-merged/coverage.json"
    if [ ! -f "$report" ]; then
        echo "error: merged report not found at $report" >&2
        exit 1
    fi
    if command -v jq >/dev/null 2>&1; then
        percent=$(jq -r '.percent_covered' "$report")
    else
        percent=$(grep -oE '"percent_covered"[^,}]*' "$report" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    fi
    # Pick a shields.io color based on the integer part of the percentage.
    pct_int=${percent%.*}
    if   [ "$pct_int" -ge 90 ]; then color="brightgreen"
    elif [ "$pct_int" -ge 80 ]; then color="green"
    elif [ "$pct_int" -ge 70 ]; then color="yellowgreen"
    elif [ "$pct_int" -ge 60 ]; then color="yellow"
    elif [ "$pct_int" -ge 50 ]; then color="orange"
    else                             color="red"
    fi
    # Fetch the static badge SVG from shields.io and commit it under .github/badges/.
    # This keeps the README badge in-repo so it updates with normal commits — no CI needed.
    mkdir -p .github/badges
    badge_url="https://img.shields.io/badge/coverage-${percent}%25-${color}"
    if curl -sSLf "$badge_url" -o .github/badges/coverage.svg; then
        badge_msg=".github/badges/coverage.svg (refreshed — remember to commit it)"
    else
        badge_msg="warning: could not fetch badge from shields.io (offline?) — badge not refreshed"
    fi
    echo ""
    echo "Coverage: ${percent}%"
    echo "Report:   coverage/merged/kcov-merged/index.html"
    echo "Badge:    ${badge_msg}"

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
