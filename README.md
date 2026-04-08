# malt

**A fast, Homebrew-compatible package manager for macOS.**

![macOS only](https://img.shields.io/badge/platform-macOS-blue)
![Zig 0.15.x](https://img.shields.io/badge/zig-0.15.x-orange)
![License](https://img.shields.io/badge/license-MIT-green)

malt is a macOS-only package manager written in Zig that consumes Homebrew's existing formula, bottle, cask, and tap ecosystem. It ships as a single binary (`malt`, ~2.8 MB) with sub-millisecond cold start. malt downloads pre-built bottles from the Homebrew infrastructure — it is a fast client for Homebrew's package registry, not a fork.

> **Experimental project.** malt is a human-in-the-loop AI experiment. The design specification, architecture decisions, implementation strategy, and quality assurance were directed by a human. All implementation code was written by AI — [Claude Code](https://claude.ai/code) and [ruflo](https://github.com/ruvnet/ruflo). Every commit, bug fix, and feature was reviewed and validated by the human operator before merging. This is an exploration of what's possible when a human architect drives an AI coder on a non-trivial systems project.

---

## What malt is

- A performance-optimized installer for pre-built Homebrew bottles and casks on macOS (Apple Silicon + Intel)
- A single static binary with zero runtime dependencies
- Compatible with Homebrew's formula, cask, and tap ecosystem via the public Formulae API
- Designed for developers who want fast, reliable package management without Homebrew's ~1.5s Ruby startup overhead

## What malt is not

- A full Homebrew replacement — it cannot execute Ruby `post_install` hooks, build from source, or evaluate the Homebrew DSL
- A fork of Homebrew — malt is an independent client that uses the same package infrastructure
- A Linux package manager — macOS only

---

## Install

### One-liner (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash
```

Downloads the latest release, verifies the SHA256 checksum, installs the binary to `/usr/local/bin/`, and creates `/opt/malt` with proper ownership. Falls back to building from source if no release is available.

### Via Homebrew

```bash
brew tap indaco/tap
brew install malt
```

### From source

```bash
git clone https://github.com/indaco/malt.git
cd malt
zig build -Doptimize=ReleaseSafe
sudo install -m 755 zig-out/bin/malt zig-out/bin/mt /usr/local/bin/
sudo mkdir -p /opt/malt && sudo chown $USER /opt/malt
```

Requires [Zig 0.15.x](https://ziglang.org/download/). See [INSTALL.md](INSTALL.md) for build profiles, stripping, and universal binary instructions.

> **Note:** `zig build` produces both `malt` and `mt` in `zig-out/bin/`. Both are identical — use whichever you prefer. All install methods (script, Homebrew, source) install both.

---

## Quick Start

> **Tip:** `mt` is a built-in alias for `malt`. Every command works with either name — use `mt` if you prefer fewer keystrokes.

```bash
# Install a formula (resolves dependencies automatically)
malt install wget

# Install a cask (auto-detected)
malt install --cask firefox

# Install from a tap (inline — no separate tap step)
malt install user/tap/formula

# Install multiple packages (downloads in parallel)
malt install jq wget ripgrep

# List installed packages
malt list --versions

# Uninstall
malt uninstall wget
```

---

## Command Reference

### `mt install`

Install formulas, casks, or tap formulas.

```bash
mt install <package>                     # auto-detect formula or cask
mt install <package>@<version>           # specific version
mt install --cask <app>                  # explicit cask
mt install --formula <name>              # explicit formula
mt install <user>/<tap>/<formula>        # inline tap (no separate tap step)
mt install <package> [<package> ...]     # multiple packages
```

| Flag            | Description                                     |
| --------------- | ----------------------------------------------- |
| `--cask`        | Force cask installation                         |
| `--formula`     | Force formula installation                      |
| `--dry-run`     | Show what would be installed without installing |
| `--force`       | Overwrite existing installations                |
| `--quiet`, `-q` | Suppress all output except errors               |
| `--json`        | Output result as JSON                           |

**Exit codes:** 0 success, 1 not found, 2 download failure, 3 link conflict, 4 disk full, 5 lock held, 6 post-install hook required.

### `mt uninstall`

Remove installed packages.

```bash
mt uninstall <package>
mt uninstall --cask <app>
mt uninstall <package> --force           # ignore dependents check
```

| Flag        | Description                                        |
| ----------- | -------------------------------------------------- |
| `--force`   | Remove even if other packages depend on it         |
| `--zap`     | Deep clean (cask only: remove preferences, caches) |
| `--dry-run` | Show what would be removed                         |

Checks for dependent packages before removing. If dependents exist, refuses unless `--force` is passed. Store entries are preserved for `mt gc`.

**Exit codes:** 0 success, 1 not installed, 3 has dependents.

### `mt upgrade`

Upgrade installed packages to latest versions.

```bash
mt upgrade                               # upgrade all outdated
mt upgrade <package>                     # upgrade specific package
mt upgrade --cask                        # upgrade casks only
```

| Flag        | Description                           |
| ----------- | ------------------------------------- |
| `--all`     | Upgrade everything (formulas + casks) |
| `--cask`    | Upgrade casks only                    |
| `--formula` | Upgrade formulas only                 |
| `--dry-run` | Show what would be upgraded           |

Installs the new version first, verifies it works, switches symlinks, then removes the old version. On failure, symlinks revert to the old version.

**Exit codes:** 0 success, 1 not installed, 2 download failure.

### `mt update`

Refresh the local formula/cask metadata cache.

```bash
mt update
```

Invalidates all entries in the API cache. The next `install`, `search`, or `info` command fetches fresh data from the Homebrew API.

**Exit codes:** 0 success, 1 API unreachable.

### `mt outdated`

List packages with newer versions available.

```bash
mt outdated
mt outdated --json
mt outdated --formula
mt outdated --cask
```

Compares installed versions against the latest from the Homebrew API.

```
wget (1.24.5) < 1.25.0
openssl@3 (3.3.2) < 3.4.1
```

**Exit codes:** 0 success (even if nothing outdated).

### `mt list`

List installed packages.

```bash
mt list
mt list --versions
mt list --cask
mt list --formula
mt list --pinned
mt list --json
```

**Exit codes:** 0 success.

### `mt info`

Show detailed information about a package.

```bash
mt info <package>
mt info <package> --json
```

```
wget: Internet file retriever
https://www.gnu.org/software/wget/
/opt/malt/Cellar/wget/1.25.0 (12 files, 2.1MB)
  Poured from bottle on 2026-04-08
From: homebrew/core
License: GPL-3.0-or-later
Dependencies: libidn2, openssl@3
Post-install hook: No
```

**Exit codes:** 0 success, 1 not found.

### `mt search`

Search formulas and casks by name.

```bash
mt search <query>
mt search <query> --formula
mt search <query> --cask
mt search <query> --json
```

**Exit codes:** 0 success (even if no results).

### `mt cleanup`

Remove old package versions and prune caches.

```bash
mt cleanup
mt cleanup --dry-run
mt cleanup --prune=<days>               # cache age threshold (default: 30)
mt cleanup -s                           # scrub entire download cache
```

**Exit codes:** 0 success.

### `mt gc`

Garbage collect unreferenced store entries.

```bash
mt gc
mt gc --dry-run
```

Scans `store/` for entries not referenced by any installed keg. Removes them to reclaim disk space.

**Exit codes:** 0 success.

### `mt doctor`

System health check.

```bash
mt doctor
```

| Check                  | Pass                                             | Fail                         |
| ---------------------- | ------------------------------------------------ | ---------------------------- |
| SQLite integrity       | `PRAGMA integrity_check` returns `ok`            | Suggest `mt doctor --repair` |
| Orphaned store entries | All store entries referenced by a keg            | Suggest `mt gc`              |
| Missing kegs           | All DB entries have Cellar directories           | Suggest reinstall            |
| Broken symlinks        | All `bin/`, `lib/` links point to existing files | Suggest `mt cleanup`         |
| Disk space             | >1 GB free on volume                             | Warn: low disk space         |
| macOS version          | Supported version (12+)                          | Warn: untested version       |
| API reachable          | HEAD to `formulae.brew.sh` returns 200           | Warn: offline                |
| Stale lock             | No lock file, or lock PID is running             | Suggest removal              |
| APFS volume            | `/opt/malt` is on APFS                           | Warn: clonefile unavailable  |

**Exit codes:** 0 all OK, 1 warnings, 2 errors.

### `mt tap` / `mt untap`

Manage taps explicitly. Taps are auto-resolved during install, so this is optional.

```bash
mt tap <user>/<repo>                    # register a tap
mt tap                                  # list registered taps
mt untap <user>/<repo>                  # remove a tap
```

**Exit codes:** 0 success, 1 not found / already tapped.

### `mt autoremove`

Remove orphaned dependencies no longer needed by any directly-installed package.

```bash
mt autoremove
mt autoremove --dry-run
```

Finds kegs installed as dependencies that are no longer required by any directly-installed package, and removes them.

**Exit codes:** 0 success (even if nothing to remove).

### `mt migrate`

Import an existing Homebrew installation.

```bash
mt migrate
mt migrate --dry-run
```

Scans the Homebrew Cellar, resolves each installed package via the API, and installs it through malt. Does **not** modify the Homebrew installation. Packages requiring `post_install` hooks are skipped with a report.

**Exit codes:** 0 success, 1 no Homebrew found, 2 some packages could not be migrated.

### `mt rollback`

Revert a formula to its previous version using the content-addressable store.

```bash
mt rollback <package>
mt rollback <package> --dry-run
```

The store retains all previously installed bottle versions. Rollback unlinks the current version, materializes the previous one from the store, and updates the database. No re-download needed.

**Exit codes:** 0 success, 1 not installed or no previous version.

### `mt run`

Run a package binary without installing it.

```bash
mt run <package> -- <args...>
mt run jq -- --version
mt run ripgrep -- --help
```

Downloads the bottle to a temp directory, extracts the binary, executes it with the provided arguments, and cleans up. If the package is already installed, runs the installed binary directly.

**Exit codes:** 0 success, 1 formula not found.

### `mt version update`

Self-update the `mt` binary from GitHub releases.

```bash
mt version                    # show current version
mt version update             # download and install latest
mt version update --check     # check without installing
```

Queries the GitHub releases API, downloads the correct binary for the current platform, and replaces the running binary in-place.

### Global Flags

| Flag              | Description                                   |
| ----------------- | --------------------------------------------- |
| `--verbose`, `-v` | Verbose output (all commands)                 |
| `--quiet`, `-q`   | Suppress non-error output (all commands)      |
| `--json`          | JSON output (read commands)                   |
| `--dry-run`       | Preview without executing (mutating commands) |
| `--help`, `-h`    | Show help                                     |
| `--version`       | Show version                                  |

---

## How It Works

### Directory Layout

malt installs to `/opt/malt` — a deliberately short prefix (9 characters) that is always shorter than Homebrew's `/opt/homebrew` (14 chars on arm64) and `/usr/local` (10 chars on Intel). This guarantees Mach-O load command patching always has room to replace the original path.

```
/opt/malt/
├── store/          # Content-addressable bottle storage (immutable, by SHA256)
├── Cellar/         # Installed kegs (APFS cloned from store/)
├── Caskroom/       # Installed cask applications
├── opt/            # Versioned formula symlinks
├── bin/            # Symlinks to keg binaries
├── lib/            # Symlinks to keg libraries
├── include/        # Symlinks to keg headers
├── share/          # Symlinks to keg shared data
├── tmp/            # In-progress downloads and extractions
├── cache/          # Cached API responses (TTL-based)
└── db/             # SQLite database + advisory lock
```

### Content-Addressable Store

Bottles are stored by their SHA256 hash. The same bottle is never downloaded or extracted twice. Multiple installed kegs can reference the same store entry. Store entries are immutable — only `mt gc` removes them.

Kegs in `Cellar/` are materialized from `store/` via APFS `clonefile()`, which creates a copy-on-write clone at zero disk cost. On non-APFS volumes, a regular recursive copy is used as fallback.

### Download Pipeline

Each bottle download is a single-pass pipeline:

```
Network (HTTPS from GHCR CDN)
    ├──→ SHA256 hasher (streaming — computed as chunks arrive)
    └──→ gzip/zstd decompressor
            └──→ tar extractor
                    └──→ filesystem write to tmp/
```

No intermediate archive file is written to disk. The SHA256 is verified against the Homebrew API manifest immediately after the stream completes. On mismatch, the extracted directory is deleted.

### Mach-O Binary Patching

Homebrew bottles contain hardcoded paths like `/opt/homebrew/Cellar/...` in Mach-O load commands. Since malt uses its own prefix, these paths must be rewritten.

malt parses Mach-O headers using struct-aware parsing (not raw byte scanning), identifies all relevant load commands (`LC_ID_DYLIB`, `LC_LOAD_DYLIB`, `LC_RPATH`, etc.), and replaces paths in-place with null padding. On arm64, every patched binary is ad-hoc codesigned via `codesign --force --sign -`.

Text files (`.pc` configs, shell scripts) containing `@@HOMEBREW_PREFIX@@` or `@@HOMEBREW_CELLAR@@` placeholders are also patched.

Patching is always performed on the Cellar copy, never the store original. If patching fails, the Cellar copy is deleted and the store entry remains pristine for retry.

### Atomic Install Protocol

Every install follows a strict 9-step protocol. Failure at any step triggers cleanup of that step only — no prior state is modified.

1. **Acquire lock** — exclusive advisory lock on `db/malt.lock`
2. **Pre-flight** — resolve dependencies, check disk space, detect link conflicts
3. **Download** — fetch bottles from GHCR CDN with streaming SHA256 verification
4. **Extract** — decompress and untar to `tmp/`
5. **Commit to store** — atomic rename from `tmp/` to `store/`
6. **Materialize** — APFS clonefile from `store/` to `Cellar/`, patch Mach-O, codesign
7. **Link** — create symlinks in `bin/`, `lib/`, etc., record in DB
8. **DB commit** — insert into kegs, dependencies, links tables in a single transaction
9. **Release lock** — clean up tmp files

---

## Safety Guarantees

- **SHA256 verification** — streaming hash computed during download, verified before extraction. No unverified data touches the store.
- **Pre-flight checks** — dependencies resolved, disk space verified, link conflicts detected, and `post_install` hooks flagged before any download begins.
- **Link conflict detection** — all target symlink paths scanned before creating any links. Conflicts abort the operation with a clear report.
- **Atomic installs** — the 9-step protocol uses `errdefer` at every stage. Interrupted installs leave no partial state.
- **Concurrent access** — advisory `flock()` with 30-second timeout prevents concurrent mutations. Read-only commands (`list`, `info`, `search`) do not acquire the lock.
- **Upgrade rollback** — new version is fully installed and verified before the old version is touched. On failure, old symlinks are restored.
- **Store immutability** — store entries are never modified after commit. Patching happens on the Cellar clone. Only `malt gc` deletes store entries.

---

## Environment Variables

| Variable                    | Description                             | Default          |
| --------------------------- | --------------------------------------- | ---------------- |
| `MALT_PREFIX`               | Override install prefix                 | `/opt/malt`      |
| `MALT_CACHE`                | Override cache directory                | `{prefix}/cache` |
| `NO_COLOR`                  | Disable colored output                  | unset            |
| `MALT_NO_EMOJI`             | Disable emoji in output                 | unset            |
| `HOMEBREW_GITHUB_API_TOKEN` | GitHub token for higher API rate limits | unset            |

---

## Transparent Fallback

For commands not implemented by malt (e.g., `mt services`, `mt bundle`), malt checks if `brew` is installed and delegates the command with a visible message:

```
$ mt services list
==> malt: 'services' not implemented. Delegating to brew...
[brew output follows]
```

If `brew` is not installed, malt prints: `"'services' requires Homebrew. Install: https://brew.sh"`.

---

## What's Not in v1

| Feature              | Reason                                        | Workaround                              |
| -------------------- | --------------------------------------------- | --------------------------------------- |
| `post_install` hooks | Requires Ruby DSL interpreter                 | Detect and warn; suggest `brew install` |
| Build from source    | Requires compilers, `./configure`, `make`     | Use bottles only; fall back to `brew`   |
| Mac App Store (mas)  | Separate ecosystem, separate auth             | Out of scope                            |
| Linux support        | ELF patching, different prefix, doubles scope | macOS only                              |
| Services management  | launchctl integration is complex and fragile  | Delegate to `brew services`             |
| Brewfile/bundle      | Nice-to-have, not critical for v1             | Delegate to `brew bundle`               |
| Formula creation     | Authoring formulas requires Ruby              | Use Homebrew for formula authoring      |
| Audit/linting        | Formula validation tools                      | Out of scope                            |

---

## How malt Compares

|                        | Homebrew            | zerobrew        | nanobrew          | bru                      | **malt**                   |
| ---------------------- | ------------------- | --------------- | ----------------- | ------------------------ | -------------------------- |
| **Language**           | Ruby                | Zig + Rust      | Zig               | Zig                      | Zig                        |
| **Binary size**        | ~57 MB              | 7.9 MB          | 1.2 MB            | ~2 MB                    | ~2.8 MB                    |
| **Prefix**             | `/opt/homebrew`     | `/opt/zerobrew` | `/opt/nanobrew`   | `/opt/homebrew` (shared) | `/opt/malt` (own)          |
| **Drop-in**            | N/A                 | No              | No                | Yes                      | No                         |
| **Brew fallback**      | N/A                 | No              | No                | Yes                      | Yes                        |
| **Parallel downloads** | No                  | Yes             | Yes               | Yes                      | Yes                        |
| **Mach-O patching**    | `install_name_tool` | Raw byte scan   | Partial           | Not needed               | Struct-aware (`std.macho`) |
| **Lib symlinks**       | Full                | Full            | `bin`/`sbin` only | Full                     | Full                       |
| **Content store**      | No                  | Yes             | Yes               | No                       | Yes                        |
| **INSTALL_RECEIPT**    | Yes                 | No              | No                | Yes                      | Yes                        |
| **Rollback**           | No                  | No              | Yes               | Yes                      | Yes                        |
| **Ephemeral run**      | No                  | Yes (`zbx`)     | No                | No                       | Yes (`malt run`)           |
| **Bundle/services**    | Yes                 | Partial         | Yes               | Yes                      | No (delegates to brew)     |
| **Concurrent safety**  | Lock file           | Lock file       | None              | Unknown                  | flock + SQLite WAL         |

**bru** is a transparent accelerator — same prefix as Homebrew, zero migration, but no isolation. **malt** takes the opposite approach — full isolation with its own prefix, content-addressable store, and struct-aware Mach-O patching for correctness.

For a detailed comparison with specific issue references and design tradeoffs, see [docs/COMPARISON.md](docs/COMPARISON.md).

---

## Roadmap

1. **Phase 1: Core Install/Uninstall (MVP)** — `mt install` with dependency resolution, cask support, inline tap resolution, content-addressable store, Mach-O patching, atomic install protocol, `mt uninstall`, `mt list`, `mt info`, `mt search`.

2. **Phase 2: Lifecycle Management** — `mt upgrade` with rollback safety, `mt outdated`, `mt update`, `mt cleanup`, `mt gc`, pinning support.

3. **Phase 3: Health and Migration** — `mt doctor`, `mt migrate` (import from Homebrew), `mt tap`/`mt untap`, transparent `brew` fallback.

4. **Phase 4: Advanced** — `post_install` hook support, Brewfile/bundle, mmap'd binary index for O(1) lookups, services management, build from source.

---

## Building

```bash
# Requires Zig 0.15.x
zig build                                # debug build
zig build -Doptimize=ReleaseSafe         # release build (~2.8 MB)
zig build test                           # run tests
zig build universal                      # universal binary (arm64 + x86_64 via lipo)
```

## Contributing

Contributions are welcome. Please open an issue to discuss before submitting large changes.

## License

MIT
