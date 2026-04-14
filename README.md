# malt

**A Homebrew client in Zig. Warm installs in milliseconds. `post_install` scripts that actually run.**

![macOS only](https://img.shields.io/badge/platform-macOS-blue)
![Zig 0.15.x](https://img.shields.io/badge/zig-0.15.x-orange)
![License](https://img.shields.io/badge/license-MIT-green)
![Coverage](.github/badges/coverage.svg)
[![Built with Devbox](https://www.jetify.com/img/devbox/shield_galaxy.svg)](https://www.jetify.com/devbox/docs/contributor-quickstart/)

> [!NOTE]
> **Experimental project.** All implementation code in malt was written by AI ([Claude Code](https://claude.ai/code) and [ruflo](https://github.com/ruvnet/ruflo)). The design, architecture, and every merged change were directed and reviewed by a human. It's a hands-on look at how far human + AI pair-programming can go on a non-trivial systems project — and the tool **actually works**.

malt is a macOS package manager written in Zig that reuses Homebrew's formula, bottle, cask, and tap ecosystem — a client for the registry, not a fork. Single binary, ~3 MB, ~3 ms cold start. Requires macOS 11+ on Apple Silicon or Intel.

Unlike other alternative clients, malt runs Homebrew `post_install` blocks natively via a built-in Zig interpreter, so packages like `node`, `openssl`, `fontconfig`, and `docbook` are fully configured at install time. On warm installs — the common case after day one — malt is the fastest tool measured on packages with dependencies. See [Benchmarks](#benchmarks).

<p align="center">
  <b><a href="#features">Features</a></b> &middot;
  <b><a href="#install">Install</a></b> &middot;
  <b><a href="#quick-start">Quick Start</a></b> &middot;
  <b><a href="#command-reference">Commands</a></b> &middot;
  <b><a href="#post-install-dsl-interpreter">Post-Install</a></b> &middot;
  <b><a href="#benchmarks">Benchmarks</a></b>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/demo.gif" alt="malt install jq tree ripgrep — demo" width="800">
</p>

---

## Features

- **Native post_install execution** — a built-in Zig interpreter runs Homebrew `post_install` scripts that every other tool skips, so packages actually work after install
- **System Ruby fallback** — `--use-system-ruby` delegates to any installed Ruby for the handful of scripts the interpreter doesn't cover
- **Isolated** — installs to its own prefix, never touches Homebrew's files
- **Deduplicated storage** — identical files across versions are stored only once
- **Parallel downloads** — fetches multiple packages at the same time
- **Brew fallback** — hands off to Homebrew for anything it doesn't support
- **Rollback** — revert to a previous version of any package
- **Ephemeral run** — `malt run` launches a formula without installing it permanently
- **Services** — `malt services` manages long-running launchd processes, `brew services`-compatible
- **Bundles** — `malt bundle install` reads existing `Brewfile`s with no conversion
- **Path-sandboxed execution** — the DSL interpreter validates all writes stay within the package prefix
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

> [!NOTE]
> `zig build` produces both `malt` and `mt` in `zig-out/bin/`. Both are identical — use whichever you prefer. All install methods (script, Homebrew, source) install both.

---

## Quick Start

> [!TIP]
> `mt` is a built-in alias for `malt`. Every command works with either name — use `mt` if you prefer fewer keystrokes.
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

| Flag                | Description                                       |
| ------------------- | ------------------------------------------------- |
| `--cask`            | Force cask installation                           |
| `--formula`         | Force formula installation                        |
| `--dry-run`         | Show what would be installed without installing   |
| `--force`           | Overwrite existing installations                  |
| `--use-system-ruby` | Execute `post_install` via system Ruby (fallback) |
| `--quiet`, `-q`     | Suppress all output except errors                 |
| `--json`            | Output result as JSON                             |

> [!INFO]
> **Post-install scripts run natively.** malt includes a built-in interpreter that executes Homebrew `post_install` blocks in Zig — no Ruby required. Packages like `node`, `openssl`, `fontconfig`, and `docbook` are fully configured at install time. For the small number of scripts the interpreter doesn't cover, add `--use-system-ruby` to delegate to any available Ruby, or use `brew install` as a fallback. See [Post-Install DSL Interpreter](#post-install-dsl-interpreter) for details.

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

Checks for dependent packages before removing. If dependents exist, refuses unless `--force` is passed. For casks, checks if the application is running and refuses unless `--force` is passed. Store entries are preserved for `mt purge --store-orphans`.

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

```text
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

### `mt doctor`

System health check.

```bash
mt doctor
mt doctor --post-install-status   # check DSL support per installed formula
```

| Check               | Pass                                          | Fail                                     |
| ------------------- | --------------------------------------------- | ---------------------------------------- |
| SQLite integrity    | `PRAGMA integrity_check` returns `ok`         | Error: database corrupt                  |
| Directory structure | All required directories exist under prefix   | Warn: missing directory                  |
| Stale lock          | No lock file, or lock PID is running          | Warn: suggest removal                    |
| APFS volume         | `/opt/malt` is on APFS                        | Warn: clonefile unavailable              |
| API reachable       | HEAD to `formulae.brew.sh` returns 2xx        | Warn: offline                            |
| Orphaned store      | All store entries referenced by a keg         | Warn: suggest `mt purge --store-orphans` |
| Missing kegs        | All DB keg paths exist on disk                | Error: suggest reinstall                 |
| Broken symlinks     | All symlinks in bin/, lib/ etc. resolve       | Warn: suggest `mt purge --housekeeping`  |
| Disk space          | > 1 GB free on prefix volume                  | Warn: low disk space                     |
| Post-install DSL    | All installed post_install formulae parseable | Warn: unsupported construct              |

Exits with code 0 (all OK), 1 (warnings found), or 2 (errors found).

### `mt purge`

Unified housekeeping and full-wipe command. A scope flag selects what to remove — `mt purge` with no scope is an error.

```bash
# Housekeeping
mt purge --store-orphans                 # refcount-0 store blobs (was: mt gc)
mt purge --unused-deps                   # orphaned dep kegs    (was: mt autoremove)
mt purge --cache=30                      # cache files older than N days
mt purge --stale-casks                   # cache + Caskroom for uninstalled casks
mt purge --housekeeping                  # all four safe scopes at once

# Destructive (typed-confirm unless --yes)
mt purge --downloads                     # wipe {cache}/downloads entirely
mt purge --old-versions                  # remove non-latest Cellar versions
mt purge --wipe                          # nuclear: every malt artefact on disk

# Combine, preview, gate
mt purge --store-orphans --cache=7 --dry-run
mt purge --wipe --backup ~/snapshot.txt --remove-binary --yes
```

| Scope             | Removes                                                 | Confirm gate        |
| ----------------- | ------------------------------------------------------- | ------------------- |
| `--store-orphans` | Refcount-0 blobs in `{prefix}/store`                    | none                |
| `--unused-deps`   | Indirect-install kegs no other package needs            | none                |
| `--cache[=DAYS]`  | Cache files older than DAYS (default 30)                | none                |
| `--downloads`     | Entire `{cache}/downloads` directory                    | type `downloads`    |
| `--stale-casks`   | Cask cache + Caskroom entries for uninstalled casks     | none                |
| `--old-versions`  | Non-latest version directories in `{prefix}/Cellar`     | type `old-versions` |
| `--housekeeping`  | = `--store-orphans --unused-deps --cache --stale-casks` | none                |
| `--wipe`          | Every malt artefact on disk (mutually exclusive)        | type `purge`        |

| Shared flag             | Description                                                      |
| ----------------------- | ---------------------------------------------------------------- |
| `--dry-run`, `-n`       | Preview every removal without touching disk                      |
| `--yes`, `-y`           | Skip every typed-confirmation prompt                             |
| `--quiet`, `-q`         | Suppress per-item output                                         |
| `--backup`, `-b` _path_ | Write a `mt restore`-compatible manifest **before** any deletion |

| `--wipe`-only flag | Description                                                                  |
| ------------------ | ---------------------------------------------------------------------------- |
| `--keep-cache`     | Preserve the cache directory (downloaded bottles stay on disk for reinstall) |
| `--remove-binary`  | Also unlink `/usr/local/bin/{mt,malt}` (opt-in — they live outside prefix)   |

`--wipe` cannot be combined with any other scope flag — it already supersedes them. For everything except `--wipe`, multiple scopes can be passed in a single invocation and run sequentially under one lock acquisition.

Acquires `{prefix}/db/malt.lock` before any destructive scope runs so concurrent malt processes cannot race; for `--wipe`, the lock is released before removing the `db/` directory itself. Honours `MALT_PREFIX` and `MALT_CACHE`, so pointing those at a throwaway path is the safe way to test the command end-to-end.

Use `mt uninstall <name>` for per-package removal — `mt purge` deals exclusively with housekeeping artefacts and full uninstalls.

### `mt tap` / `mt untap`

Manage taps explicitly. Taps are auto-resolved during install, so this is optional.

```bash
mt tap <user>/<repo>                    # register a tap
mt tap                                  # list registered taps
mt untap <user>/<repo>                  # remove a tap
```

### `mt migrate`

Import an existing Homebrew installation.

```bash
mt migrate
mt migrate --dry-run
```

Scans the Homebrew Cellar, resolves each installed package via the API, and installs it through malt. Does **not** modify the Homebrew installation. Packages with `post_install` hooks are executed via the native DSL interpreter; unsupported scripts fall back to `--use-system-ruby` or are skipped with a report.

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

### `mt services`

Manage long-running background processes via launchd. Equivalent to `brew services`.

```bash
mt services list                         # show registered services + runtime state
mt services start postgresql@16          # bootstrap into the user launchd domain
mt services stop  postgresql@16
mt services restart postgresql@16
mt services status postgresql@16         # combined DB + launchctl state
mt services logs postgresql@16 --tail 50 # last 50 lines of stdout
mt services logs postgresql@16 --stderr  # read stderr instead
```

| Subcommand | Description                                                                |
| ---------- | -------------------------------------------------------------------------- |
| `list`     | Show every registered service with `running` / `loaded` / `stopped`        |
| `start`    | Generate and `launchctl bootstrap` the service into `gui/<uid>`            |
| `stop`     | `launchctl bootout` the service                                            |
| `restart`  | `stop` then `start`                                                        |
| `status`   | Combined DB record + live `launchctl list` state                           |
| `logs`     | Tail `stdout.log` (or `stderr.log` with `--stderr`); `--tail N` sets count |

Services are registered automatically when an installed formula carries a `service` block (e.g. `postgresql@16`, `redis`). State lives at `{prefix}/var/malt/services/<name>/` (plist + log files) and in the SQLite `services` table. Currently macOS-only — Linux/Windows return `OsNotSupported`.

### `mt bundle`

Group-install and export sets of packages. Drop-in for `brew bundle`: reads existing `Brewfile`s with no conversion.

```bash
mt bundle install                            # ./Brewfile or ./Maltfile.json
mt bundle install path/to/Brewfile           # explicit file
mt bundle install --dry-run                  # print what would happen
mt bundle create                             # snapshot installed → ./Brewfile
mt bundle create --format json my.json       # JSON output
mt bundle export                             # print current install to stdout
mt bundle export --format json my-bundle     # named bundle, JSON
mt bundle list                               # registered bundles
mt bundle remove devtools                    # unregister (does not uninstall)
mt bundle import path/to/Brewfile            # register without installing
```

| Subcommand | Description                                                                |
| ---------- | -------------------------------------------------------------------------- |
| `install`  | Install every member; idempotent — already-installed members are skipped   |
| `create`   | Write the currently-installed set to a bundle file                         |
| `list`     | List bundles registered in the database                                    |
| `remove`   | Unregister a bundle (use `--purge` to also uninstall its members)          |
| `export`   | Print bundle (or current install) to stdout in `brewfile` or `json` format |
| `import`   | Register a bundle definition without installing                            |

| Flag               | Description                                           |
| ------------------ | ----------------------------------------------------- |
| `--dry-run`        | Print every member action without forking             |
| `--format <fmt>`   | `brewfile` (default) or `json`                        |
| `--from-installed` | (`create`) populate from currently-installed packages |
| `--purge`          | (`remove`) also uninstall each member                 |

**Bundlefile lookup order** (when no path is given): `./Brewfile` → `./Maltfile.json` → `~/.config/malt/Brewfile` → `~/.config/malt/Maltfile.json`.

**Brewfile compatibility**: malt parses the standard directive set (`tap`, `brew`, `cask`, `mas`, `vscode`) including hash options (`version:`, `restart_service:`, `link:`) and Ruby symbols (`restart_service: :changed`). Conditionals (`if OS.mac?`) and `do … end` blocks are rejected with a clear error pointing to `Maltfile.json` for power-user cases.

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

```text
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

Bottles are stored by their SHA256 hash. The same bottle is never downloaded or extracted twice. Multiple installed kegs can reference the same store entry. Store entries are immutable — only `mt purge --store-orphans` removes them.

Kegs in `Cellar/` are materialized from `store/` via APFS `clonefile()`, which creates a copy-on-write clone at zero disk cost. On non-APFS volumes, a regular recursive copy is used as fallback.

### Download Pipeline

Each bottle download is a single-pass pipeline:

```text
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

### Post-Install DSL Interpreter

Some packages aren't really installed the moment their files hit disk. They ship a `post_install` block that creates symlinks, sets up man pages, generates caches, or writes config files the binary expects to find at runtime. Skip that step and the package extracts fine but isn't usable. malt runs these scripts natively — no Ruby runtime required.

malt includes a native Zig interpreter for the Ruby subset used in `post_install` blocks. It adds under 80 KB to the binary and activates only for formulae that define the method.

- **Parses and evaluates** Ruby source in a sandboxed context bound to the formula's Cellar and prefix paths
- **Covers** Pathname ops, FileUtils, string interpolation, `inreplace`, `Dir.glob`, `if`/`unless`, `.each`/`.select`/`.map`, `Formula["name"]` cross-lookup, `ENV` access, `%w[]` arrays, `&&`/`||`/`!`, and more
- **Enforces write boundaries** — any filesystem mutation targeting a path outside the formula's Cellar prefix or the malt prefix is rejected outright
- **Falls back cleanly** — unsupported constructs are logged and the user is directed to `--use-system-ruby`
- **Fetches source on demand** — if the homebrew-core tap isn't cloned locally, the `.rb` source is fetched directly from GitHub

```text
Execution cascade:

  Formula has post_install?
    |
    yes --> Try native DSL interpreter
    |         |
    |         success --> done (package fully configured)
    |         |
    |         unsupported construct --> --use-system-ruby set?
    |                                     |
    |                                     yes --> delegate to Ruby subprocess
    |                                     no  --> skip with clear message
    |
    no --> done (no post_install needed)
```

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
- **Pre-flight checks** — dependencies resolved, disk space verified, and link conflicts detected before any download begins.
- **Link conflict detection** — all target symlink paths scanned before creating any links. Conflicts abort the operation with a clear report.
- **Atomic installs** — the 9-step protocol uses `errdefer` at every stage. Interrupted installs leave no partial state.
- **Concurrent access** — an advisory file lock with a 30-second timeout prevents concurrent mutations. Read-only commands (`list`, `info`, `search`) do not acquire the lock.
- **Upgrade rollback** — new version is fully installed and verified before the old version is touched. On failure, old symlinks are restored.
- **Store immutability** — store entries are never modified after commit. Patching happens on the Cellar clone. Only `mt purge --store-orphans` deletes store entries.
- **DSL path sandboxing** — the post_install interpreter validates every mutating filesystem operation (write, rm, chmod, symlink) against the formula's Cellar prefix and the malt prefix. Paths containing `..` or resolving outside the sandbox via symlinks are rejected immediately.

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

For commands not implemented by malt, malt checks if `brew` is installed and silently delegates the command to it.

If `brew` is not found, malt prints:

```text
malt: '<cmd>' is not a malt command and brew was not found.
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
| **malt** | 3.3 MB |
| nanobrew | 1.4 MB |
| zerobrew | 8.6 MB |
| bru | 1.8 MB |
<!-- BENCH:SIZE:END -->

<!-- BENCH:COLD:START -->
### Cold Install

| Package | malt | nanobrew | zerobrew | bru | Homebrew |
| ------- | ---- | -------- | -------- | --- | -------- |
| **tree** (0 deps) | 0.695s | 0.631s | 2.030s | 0.806s‡ | 4.444s |
| **wget** (6 deps) | 5.434s | 6.822s | 6.697s | 0.769s‡ | 4.319s |
| **ffmpeg** (11 deps) | 4.226s | 3.510s | 6.822s | 3.748s‡ | 20.516s |
<!-- BENCH:COLD:END -->

<!-- BENCH:WARM:START -->
### Warm Install

| Package | malt | nanobrew | zerobrew | bru |
| ------- | ---- | -------- | -------- | --- |
| **tree** (0 deps) | 0.007s | 0.005s | 0.340s | 0.047s |
| **wget** (6 deps) | 0.029s | 0.636s | 0.722s | 0.100s |
| **ffmpeg** (11 deps) | 0.085s | 1.079s | 2.731s | 1.220s |
<!-- BENCH:WARM:END -->

> [!NOTE]
> Benchmarks on Apple Silicon (GitHub Actions macos-14), 2026-04-14. Auto-updated weekly via [benchmark workflow](.github/workflows/benchmark.yml).

### Why warm matters more than cold

Every package is installed _cold_ exactly once per machine — the first time you type `mt install ffmpeg` on a fresh checkout. Everything after that — upgrades, reinstalls, dev-environment rebuilds (devbox, nix-style), CI cache restores, post-cleanup reinstalls — is a _warm_ install against the existing store. In a realistic developer workflow the ratio is roughly **1 cold : 10+ warm** over a machine's lifetime, so the warm row is where the minutes actually add up.

On that row, malt is the fastest tool measured across packages with dependencies — the common case (`wget` has 6 deps, `ffmpeg` has 11 — most useful packages do). Warm `tree` (0 deps) is within 1 ms of nanobrew, effectively tied. Cold installs are competitive but represent a one-time cost you pay per package, not an ongoing one.

Put plainly: the number that matters after your first day using malt is the warm row, and on that row malt is the fastest tool measured here.

### Reading the numbers

malt trades a few ms against correctness and features that the lighter tools skip:

- **SQLite state (~1.5 MB of the 3 MB binary)** — ACID writes, reverse-dep queries (`mt uses openssl@3`), linker conflict detection, atomic rollback. nanobrew and bru use a flat `state.json`.
- **Native `post_install` interpreter** — runs Homebrew post-install blocks in Zig, no Ruby subprocess. bru and zerobrew skip post_install entirely; nanobrew regex-scrapes a handful of patterns.
- **Ad-hoc codesign on arm64 (~15 ms/pkg)** — every Mach-O patched to rewrite `/opt/homebrew` → `MALT_PREFIX` is re-signed so `dyld` will load it.
- **Global install lock + pre-link conflict check (~3 ms)** — `flock` on `db/malt.lock` + a symlink-tree walk refusing to overwrite another keg's files.

**Methodology.** `BENCH_TRUE_COLD=1` wipes each tool's prefix between cold and warm runs, so "cold" really means "no bottle in the store." See [`scripts/bench.sh`](scripts/bench.sh). One caveat: bru keeps its download cache under `~/.bru/` and `~/Library/Caches/bru/`, outside the wiped prefix, so bru's cold numbers reflect warm cache + materialise rather than a real network fetch. bru's warm row is apples-to-apples.

---

## Contributing

Contributions are welcome. Please open an issue to discuss before submitting large changes.

## License

malt is licensed under the [MIT License](LICENSE).

Third-party components and upstream projects — including Homebrew (BSD-2-Clause) and homebrew-core (BSD-2-Clause) — are acknowledged in the [LICENSE](LICENSE) file.
