# malt

**The fastest Homebrew-compatible package manager for everyday macOS work.**

![macOS only](https://img.shields.io/badge/platform-macOS-blue)
![Zig 0.15.x](https://img.shields.io/badge/zig-0.15.x-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![Coverage](.github/badges/coverage.svg)
[![Built with Devbox](https://www.jetify.com/img/devbox/shield_galaxy.svg)](https://www.jetify.com/devbox/docs/contributor-quickstart/)

malt is a macOS-only package manager written in Zig that consumes Homebrew's existing formula, bottle, cask, and tap ecosystem. It ships as a single binary (`malt`, ~3 MB) with sub-millisecond cold start. malt downloads pre-built bottles from the Homebrew infrastructure — it is a fast client for Homebrew's package registry, not a fork. Requires macOS 11 (Big Sur) or later on Apple Silicon or Intel.

**Warm installs of packages with dependencies — the workload that dominates day-to-day development, CI rebuilds, and dev-environment provisioning — are 5–17× faster than every measured alternative.** First-time cold installs are competitive with nanobrew and faster than Homebrew on `tree` and `ffmpeg`. See [Benchmarks](#benchmarks) for the full table and methodology.

> [!NOTE]
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
mt outdated --formula
```

| Flag            | Description                 |
| --------------- | --------------------------- |
| `--json`        | Output as JSON              |
| `--formula`     | Show outdated formulas only |
| `--cask`        | Show outdated casks only    |
| `--quiet`, `-q` | Suppress status messages    |

Compares installed versions against the latest from the Homebrew API. Checks both formulas and casks by default.

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

Show detailed information about a formula or cask.

```bash
mt info <package>
mt info <package> --json
mt info --cask <app>
mt info --formula <name>
```

| Flag        | Description            |
| ----------- | ---------------------- |
| `--formula` | Show formula info only |
| `--cask`    | Show cask info only    |
| `--json`    | Output as JSON         |

Auto-detects whether the package is a formula or cask. For formulas, shows version, tap, cellar path, and pinned status. For casks, shows version, download URL, app path, and auto-update status.

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

### `mt backup`

Dump the list of directly-installed formulas and casks to a plain-text file for later restoration on the same or another machine.

```bash
mt backup                                # writes malt-backup-<timestamp>.txt to cwd
mt backup --output my-setup.txt          # custom path
mt backup -o -                           # write to stdout
mt backup --versions                     # pin each entry to its installed version
```

| Flag             | Description                                         |
| ---------------- | --------------------------------------------------- |
| `--output`, `-o` | Destination path (`-` for stdout)                   |
| `--versions`     | Append `@<version>` to each entry for exact pinning |
| `--quiet`, `-q`  | Suppress status messages                            |

Only directly-installed formulas are recorded — transitive dependencies are resolved again on restore. The file format is plain text, one entry per line (`formula <name>` or `cask <token>`), with `#` comments. It is safe to hand-edit before restoring.

### `mt restore`

Reinstall every entry in a backup file produced by `mt backup`.

```bash
mt restore my-setup.txt
mt restore my-setup.txt --dry-run        # preview what would be installed
mt restore my-setup.txt --force          # pass --force to the underlying installs
```

| Flag            | Description                                        |
| --------------- | -------------------------------------------------- |
| `--dry-run`     | Print the list of packages without installing      |
| `--force`       | Forward `--force` to `mt install` for each package |
| `--quiet`, `-q` | Suppress status messages                           |

Formulas and casks are batched into two `mt install` invocations, so dependency resolution, parallel downloads, and the atomic install protocol all apply. Lines prefixed with `#` and blank lines are ignored, and entries with a `@<version>` suffix are installed at that exact version.

### `mt purge`

Completely wipe a malt installation from disk — every package, the content-addressable store, linked binaries, the cache, and the SQLite database.

```bash
mt purge                                 # interactive, requires typing `purge`
mt purge --dry-run                       # preview every target with sizes
mt purge --backup ~/malt-snapshot.txt    # dump restorable manifest first
mt purge --keep-cache                    # leave cache/ intact (faster reinstall)
mt purge --remove-binary --yes           # also unlink /usr/local/bin/{mt,malt}
```

| Flag                    | Description                                                                                        |
| ----------------------- | -------------------------------------------------------------------------------------------------- |
| `--backup`, `-b` _path_ | Write a `mt restore`-compatible manifest of installed packages **before** any deletion             |
| `--keep-cache`          | Preserve the cache directory (downloaded bottles stay on disk for a later reinstall)               |
| `--remove-binary`       | Also unlink `/usr/local/bin/mt` and `/usr/local/bin/malt` (opt-in — these live outside the prefix) |
| `--yes`, `-y`           | Skip the typed confirmation (required for non-interactive / CI use)                                |
| `--dry-run`             | Preview every target without touching disk                                                         |

Interactive by default: prints a warning banner with every target and its size, then requires you to type the literal word `purge` (not `y`) to proceed. Refuses to run when stdin is not a TTY unless `--yes` is passed, so a stray `echo y | mt purge` cannot trigger a wipe.

Acquires `{prefix}/db/malt.lock` before deleting so concurrent malt processes cannot race, and releases the lock before removing the `db/` directory itself. Honours `MALT_PREFIX` and `MALT_CACHE`, so pointing those at a throwaway path is the safe way to test the command end-to-end.

Use `mt uninstall <name>` for per-package removal, `mt cleanup` for cache-only cleanup, and `mt autoremove` / `mt gc` for orphan removal — `mt purge` is specifically the nuclear option for uninstalling malt entirely.

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

### `mt completions`

Generate a shell completion script for `bash`, `zsh`, or `fish`. The script is printed to stdout, so it can be eval'd immediately or redirected to a file for permanent install.

```bash
# Temporary (current shell only)
eval "$(malt completions bash)"
eval "$(malt completions zsh)"       # run AFTER `compinit`
malt completions fish | source

# Permanent
malt completions bash > /usr/local/etc/bash_completion.d/malt
malt completions zsh  > "${fpath[1]}/_malt"
malt completions fish > ~/.config/fish/completions/malt.fish
```

Completes subcommands (for both `malt` and `mt`), per-command flags, global flags, and the positional shell name for `completions` itself. Unknown shell names exit non-zero with an error.

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
    ├──-> SHA256 hasher (streaming — computed as chunks arrive)
    └──-> gzip/zstd decompressor
            └──-> tar extractor
                    └──-> filesystem write to tmp/
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

| Tool | Size |
| ---- | ---- |
| **malt** | 3.2M |
| nanobrew | 1.4M |
| zerobrew | 8.6M |
| bru | 1.8M |
<!-- BENCH:SIZE:END -->

<!-- BENCH:COLD:START -->
### Cold Install

| Package | malt | nanobrew | zerobrew | bru | Homebrew |
| ------- | ---- | -------- | -------- | --- | -------- |
| **tree** (0 deps) | 0.910s | 0.612s | 1.806s | 0.750s‡ | 3.419s |
| **wget** (6 deps) | 4.574s | 5.601s | 6.414s | 0.529s‡ | 3.682s |
| **ffmpeg** (11 deps) | 4.502s | 2.810s | 5.851s | 3.042s‡ | 15.632s |
<!-- BENCH:COLD:END -->

<!-- BENCH:WARM:START -->
### Warm Install

| Package | malt | nanobrew | zerobrew | bru |
| ------- | ---- | -------- | -------- | --- |
| **tree** (0 deps) | 0.022s | 0.008s | 0.243s | 0.039s |
| **wget** (6 deps) | 0.034s | 0.532s | 0.667s | 0.054s |
| **ffmpeg** (11 deps) | 0.151s | 0.760s | 2.182s | 1.004s |
<!-- BENCH:WARM:END -->

### Why warm matters more than cold

Every package is installed _cold_ exactly once per machine — the first time you type `mt install ffmpeg` on a fresh checkout. Everything after that — upgrades, reinstalls, dev-environment rebuilds (devbox, nix-style), CI cache restores, post-cleanup reinstalls — is a _warm_ install against the existing store. In a realistic developer workflow the ratio is roughly **1 cold : 10+ warm** over a machine's lifetime, so the warm row is where the minutes actually add up.

On that row **malt beats every measured alternative by 5–17× on packages with dependencies**, which is the common case (`wget` has 6 deps, `ffmpeg` has 11 — most useful packages do). Warm `tree` (0 deps) is within 1 ms of nanobrew, effectively tied. Cold installs are competitive — roughly tied with nanobrew on `wget`, ahead of Homebrew on `tree` and `ffmpeg` — but they represent a one-time cost you pay per package, not an ongoing one.

Put plainly: the number that matters after your first day using malt is the warm row, and on that row malt is the fastest tool measured here.

### Reading the numbers

Raw install time is only one axis — a few architectural choices behind these numbers are worth calling out, because they trade ms against correctness or features:

- **Binary size (3.2 M).** malt embeds SQLite where nanobrew (1.4 M) and bru (1.8 M) use a flat `state.json`. The extra ~1.5 M buys ACID state, reverse-dep queries (`mt uses openssl@3`), linker conflict detection, and atomic rollback on interrupted installs — features that are either missing or hand-rolled in the JSON-backed tools. zerobrew (8.6 M) pays a similar cost for Rust + its own stack.
- **Ad-hoc codesign on arm64.** Every Mach-O binary malt patches (rewriting `/opt/homebrew` -> `MALT_PREFIX` in load commands) is re-signed afterwards — roughly 15 ms per package. Skipping this step is faster, but leaves arm64 `dyld` refusing to load binaries whose ad-hoc signature was invalidated by the patch. malt pays the ms; nanobrew doesn't.
- **Global install lock + conflict detection.** `flock` on `db/malt.lock` prevents two concurrent `mt install` processes from racing on state (~0.5 ms uncontended). Before linking, malt walks the existing symlink tree and refuses to overwrite another keg's files (~2-3 ms). Both checks are absent in the JSON-backed tools.
- **`BENCH_TRUE_COLD=1` methodology.** Each tool's prefix is wiped between the cold and warm runs, so `cold` really does mean "no bottle in the store." See [`scripts/bench.sh`](scripts/bench.sh).

> [!NOTE]
> bru keeps its bottle download cache under `~/.bru/` and `~/Library/Caches/bru/`, outside the wiped `/tmp/bru` prefix, so its `cold` numbers reflect warm cache + materialise, not a real network fetch. bru's warm row is still an apples-to-apples comparison.

> Benchmarks on Apple Silicon (GitHub Actions macos-14), 2026-04-11. Auto-updated weekly via [benchmark workflow](.github/workflows/benchmark.yml).

---

## Contributing

Contributions are welcome. Please open an issue to discuss before submitting large changes.

## License

MIT
