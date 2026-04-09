# malt

**A fast, Homebrew-compatible package manager for macOS.**

![macOS only](https://img.shields.io/badge/platform-macOS-blue)
![Zig 0.15.x](https://img.shields.io/badge/zig-0.15.x-orange)
![License](https://img.shields.io/badge/license-MIT-green)
[![Built with Devbox](https://www.jetify.com/img/devbox/shield_galaxy.svg)](https://www.jetify.com/devbox/docs/contributor-quickstart/)

malt is a macOS-only package manager written in Zig that consumes Homebrew's existing formula, bottle, cask, and tap ecosystem. It ships as a single binary (`malt`, ~3 MB) with sub-millisecond cold start. malt downloads pre-built bottles from the Homebrew infrastructure — it is a fast client for Homebrew's package registry, not a fork. Requires macOS 11 (Big Sur) or later on Apple Silicon or Intel.

> **Experimental project.** malt is a human-in-the-loop AI experiment. The design specification, architecture decisions, implementation strategy, and quality assurance were directed by a human. All implementation code was written by AI — [Claude Code](https://claude.ai/code) and [ruflo](https://github.com/ruvnet/ruflo). Every commit, bug fix, and feature was reviewed and validated by the human operator before merging. This is an exploration of what's possible when a human architect drives an AI coder on a non-trivial systems project.

<p align="center">
  <b><a href="#features">Features</a></b> &middot;
  <b><a href="#install">Install</a></b> &middot;
  <b><a href="#quick-start">Quick Start</a></b> &middot;
  <b><a href="#command-reference">Command Reference</a></b> &middot;
  <b><a href="#benchmarks">Benchmarks</a></b>
</p>

---

## Features

- **Isolated** — installs to its own prefix, never touches Homebrew's files
- **Deduplicated storage** — identical files across versions are stored only once
- **Parallel downloads** — fetches multiple packages at the same time
- **Brew fallback** — hands off to Homebrew for anything it doesn't support
- **Rollback** — revert to a previous version of any package
- **Ephemeral run** — `malt run` launches a formula without installing it permanently
- **Safe under concurrency** — multiple malt processes won't corrupt state

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

Clone the repo and run the install script — it detects the local checkout and builds from source automatically:

```bash
git clone https://github.com/indaco/malt.git
cd malt
./scripts/install.sh
```

Requires [Zig 0.15.x](https://ziglang.org/download/).

> **Note:** `zig build` produces both `malt` and `mt` in `zig-out/bin/`. Both are identical — use whichever you prefer. All install methods (script, Homebrew, source) install both.

---

## Quick Start

> **Tip:** `mt` is a built-in alias for `malt`. Every command works with either name — use `mt` if you prefer fewer keystrokes.
>
> Additional aliases: `remove` for `uninstall`, `ls` for `list`.

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

> The examples below use `mt` (the shorter alias). All commands work identically with `malt`.

### `mt install`

Install formulas, casks, or tap formulas.

```bash
mt install <package>                     # auto-detect formula or cask
mt install <package>@<version>           # versioned formula (e.g. openssl@3)
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

### `mt uninstall`

Remove installed packages.

```bash
mt uninstall <package>
mt uninstall --cask <app>
mt uninstall <package> --force           # ignore dependents check
```

| Flag            | Description                                |
| --------------- | ------------------------------------------ |
| `--force`, `-f` | Remove even if other packages depend on it |
| `--cask`        | Force cask uninstall                       |

Checks for dependent packages before removing. If dependents exist, refuses unless `--force` is passed. For casks, checks if the application is running and refuses unless `--force` is passed. Store entries are preserved for `mt gc`.

### `mt upgrade`

Upgrade installed packages to latest versions.

```bash
mt upgrade <package>                     # upgrade a specific formula or cask
mt upgrade --cask                        # upgrade all outdated casks
mt upgrade --formula                     # upgrade all outdated formulas
mt upgrade --dry-run                     # show what would be upgraded
```

| Flag        | Description               |
| ----------- | ------------------------- |
| `--cask`    | Upgrade casks only        |
| `--formula` | Upgrade formulas only     |
| `--dry-run` | Preview without upgrading |

Formula upgrades install the new version, verify it, switch symlinks atomically, and only remove the old version after success. On failure, the old version is restored automatically.

### `mt update`

Refresh the local formula/cask metadata cache.

```bash
mt update
```

Invalidates all entries in the API cache. The next `install`, `search`, or `info` command fetches fresh data from the Homebrew API.

### `mt outdated`

List packages with newer versions available.

```bash
mt outdated
mt outdated --json
mt outdated --cask
```

| Flag     | Description              |
| -------- | ------------------------ |
| `--json` | Output as JSON           |
| `--cask` | Show outdated casks only |

Compares installed versions against the latest from the Homebrew API. Checks both formulas and casks.

```
wget (1.24.5) < 1.25.0
openssl@3 (3.3.2) < 3.4.1
```

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

### `mt search`

Search formulas and casks by name.

```bash
mt search <query>
mt search <query> --formula
mt search <query> --cask
mt search <query> --json
```

### `mt cleanup`

Remove old package versions and prune caches.

```bash
mt cleanup
mt cleanup --dry-run
mt cleanup --prune=<days>               # cache age threshold (default: 30)
mt cleanup -s                           # scrub entire download cache
```

### `mt gc`

Garbage collect unreferenced store entries.

```bash
mt gc
mt gc --dry-run
```

Scans `store/` for entries not referenced by any installed keg. Removes them to reclaim disk space.

### `mt doctor`

System health check.

```bash
mt doctor
```

| Check               | Pass                                        | Fail                        |
| ------------------- | ------------------------------------------- | --------------------------- |
| SQLite integrity    | `PRAGMA integrity_check` returns `ok`       | Error: database corrupt     |
| Directory structure | All required directories exist under prefix | Warn: missing directory     |
| Stale lock          | No lock file, or lock PID is running        | Warn: suggest removal       |
| APFS volume         | `/opt/malt` is on APFS                      | Warn: clonefile unavailable |
| API reachable       | HEAD to `formulae.brew.sh` returns 2xx      | Warn: offline               |
| Orphaned store      | All store entries referenced by a keg       | Warn: suggest `mt gc`       |
| Missing kegs        | All DB keg paths exist on disk              | Error: suggest reinstall    |
| Broken symlinks     | All symlinks in bin/, lib/ etc. resolve     | Warn: suggest `mt cleanup`  |
| Disk space          | > 1 GB free on prefix volume                | Warn: low disk space        |

Exits with code 0 (all OK), 1 (warnings found), or 2 (errors found).

### `mt tap` / `mt untap`

Manage taps explicitly. Taps are auto-resolved during install, so this is optional.

```bash
mt tap <user>/<repo>                    # register a tap
mt tap                                  # list registered taps
mt untap <user>/<repo>                  # remove a tap
```

### `mt autoremove`

Remove orphaned dependencies no longer needed by any directly-installed package.

```bash
mt autoremove
mt autoremove --dry-run
```

Finds kegs installed as dependencies that are no longer required by any directly-installed package, and removes them.

### `mt migrate`

Import an existing Homebrew installation.

```bash
mt migrate
mt migrate --dry-run
```

Scans the Homebrew Cellar, resolves each installed package via the API, and installs it through malt. Does **not** modify the Homebrew installation. Packages requiring `post_install` hooks are skipped with a report.

### `mt rollback`

Revert a formula to its previous version using the content-addressable store.

```bash
mt rollback <package>
mt rollback <package> --dry-run
```

The store retains all previously installed bottle versions. Rollback unlinks the current version, materializes the previous one from the store, and updates the database. No re-download needed.

### `mt run`

Run a package binary without installing it.

```bash
mt run <package> -- <args...>
mt run jq -- --version
mt run ripgrep -- --help
```

Downloads the bottle to a temp directory, extracts the binary, executes it with the provided arguments, and cleans up. If the package is already installed, runs the installed binary directly.

### `mt link` / `mt unlink`

Manage symlinks for installed kegs.

```bash
mt link <formula>                        # create prefix symlinks for a keg
mt link <formula> --overwrite            # replace conflicting symlinks
mt unlink <formula>                      # remove symlinks (keg stays installed)
```

| Flag                           | Description               |
| ------------------------------ | ------------------------- |
| `--overwrite`, `--force`, `-f` | Replace existing symlinks |

`link` scans for symlink conflicts before creating links. If conflicts are found, it reports them and aborts unless `--overwrite` is passed. `unlink` removes symlinks from `bin/`, `lib/`, etc. and the `opt/` symlink, but leaves the keg installed in the Cellar.

### `mt version`

Show the current version or self-update the binary.

```bash
mt version                    # show current version
mt version update             # download and install latest
mt version update --check     # check without installing
```

`update` queries the GitHub releases API, downloads the correct binary for the current platform, and replaces the running binary in-place.

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

malt installs to `/opt/malt` — its own prefix, fully isolated from Homebrew. The shorter path guarantees that Mach-O load command patching always has room to replace the original Homebrew path.

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

malt parses Mach-O headers using struct-aware parsing (not raw byte scanning), identifies all relevant load commands (`LC_ID_DYLIB`, `LC_LOAD_DYLIB`, `LC_RPATH`, etc.), and replaces paths in-place, padding the remaining space with null bytes. On arm64, every patched binary is ad-hoc codesigned via `codesign --force --sign -`.

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
- **Concurrent access** — an advisory file lock with a 30-second timeout prevents concurrent mutations. Read-only commands (`list`, `info`, `search`) do not acquire the lock.
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

For commands not implemented by malt (e.g., `mt services`, `mt bundle`), malt checks if `brew` is installed and silently delegates the command to it.

If `brew` is not found, malt prints:

```
malt: 'services' is not a malt command and brew was not found.
Install Homebrew: https://brew.sh
```

---

## Building

```bash
# Requires Zig 0.15.x
zig build                                # debug build
zig build -Doptimize=ReleaseSafe         # release build (~3 MB)
zig build test                           # run tests
zig build universal                      # universal binary (arm64 + x86_64 via lipo)
```

---

## Benchmarks

Install times on macOS 14 (Apple Silicon), comparing malt against other Homebrew-compatible package managers.

<!-- BENCH:SIZE:START -->

### Binary Size

| Tool     | Size |
| -------- | ---- |
| **malt** | 3.0M |
| nanobrew | 1.4M |
| zerobrew | 8.6M |
| bru      | 1.8M |

<!-- BENCH:SIZE:END -->

<!-- BENCH:COLD:START -->

### Cold Install

| Package              | malt   | nanobrew | zerobrew | bru    | Homebrew |
| -------------------- | ------ | -------- | -------- | ------ | -------- |
| **tree** (0 deps)    | 0.011s | 0.681s   | 1.960s   | 0.819s | 3.833s   |
| **wget** (6 deps)    | 0.003s | 4.222s   | 5.757s   | 0.004s | 4.481s   |
| **ffmpeg** (11 deps) | 0.010s | 1.710s   | 4.522s   | 3.518s | 5.247s   |

<!-- BENCH:COLD:END -->

<!-- BENCH:WARM:START -->

### Warm Install

| Package              | malt   | nanobrew | zerobrew | bru    |
| -------------------- | ------ | -------- | -------- | ------ |
| **tree** (0 deps)    | 0.002s | 0.005s   | 0.212s   | 0.026s |
| **wget** (6 deps)    | 0.002s | 0.477s   | 0.529s   | 0.588s |
| **ffmpeg** (11 deps) | 0.002s | 0.717s   | 2.232s   | 1.098s |

<!-- BENCH:WARM:END -->

> Benchmarks on Apple Silicon (GitHub Actions macos-14). Auto-updated weekly via [benchmark workflow](.github/workflows/benchmark.yml).

---

## Contributing

Contributions are welcome. Please open an issue to discuss before submitting large changes.

## License

MIT
