# malt

**A fast, drop-in Homebrew alternative for macOS. Warm installs in milliseconds. `post_install` scripts that actually run. Full operational surface beyond install and uninstall.**

Reuses every formula, bottle, cask, tap, and `Brewfile` in the existing ecosystem; installs to its own prefix; ~3 MB single binary; ~3 ms cold start. Designed by a human and implemented by AI.

![macOS only](https://img.shields.io/badge/platform-macOS-blue)
![Version](https://img.shields.io/github/v/tag/indaco/malt?label=version&sort=semver&color=4c1)
![Coverage](.github/badges/coverage.svg)
![Zig 0.16.x](https://img.shields.io/badge/zig-0.16.x-orange)
![License](https://img.shields.io/badge/license-MIT-green)
[![Signed by cosign](https://img.shields.io/badge/signed-cosign-brightgreen?logo=sigstore&logoColor=white)](#safety-and-security)
[![Built with Devbox](https://www.jetify.com/img/devbox/shield_galaxy.svg)](https://www.jetify.com/devbox/docs/contributor-quickstart/)

<p align="center">
  <b><a href="#why-malt-exists">Why malt</a></b> &middot;
  <b><a href="#features">Features</a></b> &middot;
  <b><a href="#installation">Install</a></b> &middot;
  <b><a href="#first-commands">First commands</a></b> &middot;
  <b><a href="#command-reference">Reference</a></b> &middot;
  <b><a href="#safety-and-security">Security</a></b> &middot;
  <b><a href="#architecture">Architecture</a></b> &middot;
  <b><a href="#benchmarks">Benchmarks</a></b>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/demo.gif" alt="malt install jq tree ripgrep - demo" width="800">
</p>

> [!IMPORTANT]
> **malt is under active development.** The CLI surface is settled and significant breaking changes are unlikely - bugs are still likely.
>
> If you hit one, please [open an issue](https://github.com/indaco/malt/issues/new). User-reported bugs jump the queue and ship in patch releases.

## Why malt exists

Three observations shape malt.

**`post_install` is where most alternative Homebrew clients quietly give up.** A surprising number of formulas don't finish installing the moment their files hit disk: they ship a `post_install` block - symlinks, man pages, config files, service registration - that the binary expects to find at runtime. Other clients tend to skip these scripts or pattern-match a handful of well-known cases. malt ships a built-in Zig interpreter for the Ruby subset these blocks use, so packages like `node`, `openssl`, `fontconfig`, and `docbook` are fully configured by the time the install returns.

**Cold installs happen once. Warm installs happen forever.** The first `brew install ffmpeg` on a fresh checkout is a one-time cost. Every reinstall, upgrade, devbox/nix-style rebuild, and CI cache restore after it is a _warm_ install against an existing store. The ratio over a developer's working life is roughly 1 cold to 10+ warm - the warm row is where the minutes compound. malt's warm `ffmpeg` install finishes in **31 ms**.

**A package manager is also a piece of infrastructure on your machine.** It runs as your user, writes to a privileged-ish prefix, downloads code from the internet, and patches Mach-O headers. It deserves the posture of any other root-adjacent tool: SHA256 streaming, atomic installs, advisory locking, sandboxed subprocesses, cosign-verified releases. malt's binary is ~3 MB and starts in ~3 ms - none of the safety properties are paid for in startup time.

malt installs to `/opt/malt`, never touches Homebrew's files, reads existing `Brewfile`s without conversion, and transparently delegates anything it doesn't implement to `brew` if it's installed. It is a client for the Homebrew registry, not a fork.

The implementation is a study in human-directed AI: design, architecture, and every merged change reviewed by a human; every commit of Zig produced by AI ([Claude Code](https://claude.ai/code) and [ruflo](https://github.com/ruvnet/ruflo)). The fragile thing about AI-generated code isn't the first commit - it's the tenth. malt has been refactored end-to-end more than once - install protocol, `post_install` interpreter, Mach-O patcher - each round steered by ADRs and security review the model wouldn't have written on its own. The repository, the test suite, and the running tool are the evidence on offer.

## Features

The full surface area at a glance.

- **Drop-in for Homebrew workflows.** Installs formulas, casks, tap formulas, and `user/tap/formula` shortcuts; reads existing `Brewfile`s with no conversion; `mt shellenv` is a drop-in for `eval "$(brew shellenv)"`; `mt services` is a drop-in for `brew services`. Installs to `/opt/malt`, never touches Homebrew's files.
- **Native `post_install`.** A built-in Zig interpreter runs Homebrew `post_install` scripts natively - `node`, `openssl`, `fontconfig`, `docbook` are fully configured by the time the install returns. Unsupported constructs are reported; `--use-system-ruby` delegates to a sandboxed Ruby subprocess. See [Architecture](#architecture) for the fallback flow.
- **Content-addressable store.** Bottles indexed by SHA256; the same bottle is never downloaded or extracted twice. Kegs in `Cellar/` are APFS `clonefile()` copies. Reinstalls and rollbacks cost no bytes and no network.
- **Atomic install protocol.** New versions verified before old versions are touched; `mt rollback --to <version>` reverts from the store with no re-download. Streaming SHA256 + parallel downloads + a 30 s advisory file lock against concurrent mutations.
- **Ephemeral run.** `mt run <pkg> -- <args...>` extracts and `execvp`s without a permanent install; `--keep` caches the bottle for next time.
- **Full operational surface.** Services, bundle installs, doctor, purge, backup/restore, migrate, and reverse-dependency queries - see [Command reference](#command-reference) for the full surface.
- **Scriptable.** `--json` and `--output-format=ndjson` everywhere it makes sense; orthogonal flags. `--quiet`, `--verbose`, `--debug`, `--dry-run`, `--offline` are global. `NO_COLOR`, `MALT_NO_EMOJI`, `MALT_PROGRESS`, `MALT_THEME` for shaping output.
- **Signed, verifiable releases.** Every release is cosign-signed keyless via GitHub OIDC; `install.sh` and `mt version update` verify the signature before trusting the SHA256 checksum. See [Safety and security](#safety-and-security) for the full supply-chain story.
- **Sandboxed `post_install`.** The `--use-system-ruby` path runs inside a `sandbox-exec` profile scoped to the formula's cellar; the native interpreter validates every mutating operation against the Cellar/malt prefix.

> [!NOTE]
> **Compatibility note.** "Drop-in" covers the directives a typical `Brewfile` uses - `tap`, `brew`, `cask`, `mas`, and `vscode` (the last two round-trip through the parser but are not yet installed by malt) - plus hash options and Ruby symbols. It does _not_ cover Ruby `do … end` blocks or conditionals like `if OS.mac?`. Both raise a clear error. macOS only - Linux and Windows are out of scope.

## Installation

Three install paths - pick the one that matches your setup.

### One-liner script

The script downloads the latest release, verifies the SHA256 checksum **and a cosign keyless signature** against the GitHub Actions workflow that produced it, installs the binary to `/usr/local/bin/`, and creates `/opt/malt` with proper ownership.

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash
```

The script needs [`cosign`](https://docs.sigstore.dev/cosign/system_config/installation/) on your `PATH`. To bypass verification (not recommended), set `MALT_ALLOW_UNVERIFIED=1`. If no release matches your platform, the script falls back to building from source.

To verify `install.sh` itself out of band, pin to a release tag and compare its SHA256 against the release notes:

```bash
curl -fsSL "https://raw.githubusercontent.com/indaco/malt/v0.5.1/scripts/install.sh" -o install.sh
shasum -a 256 install.sh
bash install.sh
```

### Via Homebrew

malt is published as a Homebrew cask:

```bash
brew install --cask indaco/tap/malt
```

The qualified `<tap>/<cask>` shorthand taps implicitly. Upgrade with `brew upgrade --cask malt`. `mt version update` detects a Homebrew-managed install and points you at `brew upgrade --cask malt` instead.

### From source

Clone the repo and run the install script. It detects the local checkout and builds from source automatically:

```bash
git clone https://github.com/indaco/malt.git
cd malt
./scripts/install.sh
```

Building requires [Zig 0.16.x](https://ziglang.org/download/) and produces `malt` in `zig-out/bin/` with `mt` next to it as a symlink to `malt`. For development builds (debug, tests, universal binary), see [Development builds](#development-builds).

## First commands

Make malt's binaries discoverable in new shells before starting. `mt shellenv` is a drop-in for `eval "$(brew shellenv)"`:

```bash
echo 'eval "$(mt shellenv)"' >> ~/.zshrc          # or ~/.bashrc
mt shellenv fish | source                          # fish: set -gx, not export
```

Then a first session looks like this:

```bash
mt install jq wget ripgrep        # parallel downloads, single lock
mt list --versions                # see what landed
mt info ripgrep                   # version, tap, cellar path, pinned status
mt outdated                       # what has updates available
mt upgrade ripgrep                # atomic; old version is restored on failure
```

`mt` and `malt` are the same binary - `mt` is a symlink to `malt` and ships with every install method. Additional aliases: `remove` for `uninstall`, `ls` for `list`. Anywhere a flag accepts `--formula` or `--cask`, it also accepts `--formulae` or `--casks` - pick whichever reads more naturally.

If you typed something malt doesn't implement, malt checks for `brew` and silently delegates. If `brew` isn't installed:

```text
malt: '<cmd>' is not a malt command and brew was not found.
Install Homebrew: https://brew.sh
```

## Command reference

Commands grouped by what you're doing. Every command works with `malt` or `mt`, accepts `--help` for the full flag list, and supports `--quiet`, `--dry-run` (where mutating), and `--json` (where applicable). See [Global flags](#global-flags) for the cross-cutting set.

At a glance - `malt -h`:

```text
malt - a fast, drop-in Homebrew alternative for macOS.
Warm installs in milliseconds. post_install scripts that actually run.
Full operational surface beyond install and uninstall.

Usage: malt <command> [options] [arguments]
       mt <command> [options] [arguments]    (alias)

Commands:
  install       Install formulas, casks, or tap formulas
  reinstall     Wipe and re-materialise an installed package
  uninstall     Remove installed packages
  upgrade       Upgrade installed packages
  update        Refresh metadata cache
  outdated      List packages with newer versions available
  list          List installed packages
  info          Show detailed package information
  search        Search formulas and casks
  uses          Show installed packages that depend on a formula
  deps          Show what a formula depends on (forward of `uses`)
  which         Resolve a prefix binary (or path) to its keg
  doctor        System health check
  tap/untap     Manage taps
  migrate       Import existing Homebrew installation
  rollback      Revert a package to its previous version
  link          Create symlinks for an installed keg
  unlink        Remove symlinks (keg stays installed)
  pin           Protect an installed formula or cask from `upgrade`
  unpin         Lift the pin so `upgrade` resumes touching it
  run           Run a package binary without installing
  completions   Generate shell completion scripts (bash, zsh, fish)
  shellenv      Print PATH/MANPATH/HOMEBREW_PREFIX exports for shell init
  backup        Dump installed packages to a restorable text file
  restore       Reinstall every package listed in a backup file
  purge         Housekeeping or full wipe (--store-orphans, --unused-deps,
                --cache, --downloads, --stale-casks, --old-versions,
                --housekeeping, --wipe)
  cleanup       Shorthand for `purge --housekeeping`
  services      Manage long-running launchd services (start/stop/status/logs)
  bundle        Install or export a Brewfile/Maltfile.json set of packages
  version       Show version (use 'version update' to self-update)
```

### Get and remove software

`mt install` installs formulas, casks, and tap formulas, with auto-detection for the common case:

```bash
mt install wget                          # auto-detect formula or cask
mt install --cask firefox                # explicit cask
mt install user/tap/formula              # inline tap, no separate tap step
mt install openssl@3                     # versioned formula
mt install jq wget ripgrep               # parallel downloads, single lock
mt install --only-dependencies wget      # transitive deps only
mt install --local ./hello.rb            # local Ruby formula (see "Local formulas")
mt install --dry-run jq                  # preview without installing
```

Other flags: `--force` (overwrite existing), `--use-system-ruby[=<name>,…]` (delegate `post_install` to system Ruby, sandboxed, per-formula), `--quiet`/`-q`, `--json`.

`mt reinstall <pkg>` is the discoverable peer of `mt install --force`: refuses if the package isn't installed, wipes and re-materialises the existing keg or cask. Transitive dependencies are not reinstalled. Global flags (`--json`, `--quiet`, `--dry-run`) pass through.

`mt run <pkg> -- <args...>` runs a binary without a permanent install. Useful for one-off invocations:

```bash
mt run jq -- --version
mt run --keep ripgrep -- --help          # cache the bottle for next run
```

`--keep` extracts under `{cache}/run/<sha256>/` so subsequent calls skip the download. The cache is wiped by `mt purge --cache`.

`mt uninstall` removes a package, refusing if dependents exist or, for casks, if the application is running. `--force` (`-f`) bypasses both checks. `--cask` forces cask uninstall. Store entries are preserved for `mt purge --store-orphans`.

`mt migrate` imports an existing Homebrew installation by scanning the Cellar and reinstalling each package through malt. It never modifies the Homebrew install. Packages with `post_install` are executed via the native interpreter; unsupported scripts fall back to `--use-system-ruby` or are skipped with a report. `--dry-run` previews. `--parallel` runs the per-keg work concurrently (4 workers by default; tune with `MALT_MIGRATE_PARALLEL_WORKERS=N`) and records each success in `{prefix}/cache/migrate.progress.json`, so a re-run after a crash or `^C` resumes where it stopped.

### Stay current

Three commands form the upgrade loop:

```bash
mt update                                # refresh API cache + drop outdated snapshot
mt update --check                        # write a fresh outdated snapshot only

mt outdated                              # list packages with newer versions
mt outdated --pinned-only                # CVE watch on held-back versions
mt outdated --refresh                    # bypass the cached snapshot

mt upgrade <name>                        # upgrade a specific formula or cask
mt upgrade --formula                     # all outdated formulas
mt upgrade --cask                        # all outdated casks
mt upgrade --pinned --dry-run            # audit pinned drift without mutating
mt upgrade --force <name>                # bypass a pin for one upgrade
```

`mt outdated` reads from a cached snapshot when one exists (24 h TTL by default; `MALT_OUTDATED_MAX_AGE=<hours>` to override, `0` to always recompute). The snapshot is filtered through the live DB at read time, so an uninstalled or manually-upgraded keg can never appear. A stale read warns and recommends `mt update --check`. Snapshots are auto-refreshed after any full live recompute. Add `--json` for machine output.

`mt upgrade` installs the new version, verifies it, switches symlinks atomically, and only removes the old version after success. On failure, the old version is restored.

`mt pin <name>` / `mt unpin <name>` hold a package at its current version. Pinned packages are skipped by `mt upgrade` with a "pinned, skipped" line; `mt list --pinned` inspects.

`mt rollback <package>` reverts a formula to its previous version. The store retains every previously installed bottle, so rollback unlinks → re-clones → updates the DB without re-downloading. `--dry-run` previews.

### Inspect what's installed

```bash
mt list                                  # all installed packages
mt list --versions --formula             # narrow + show versions
mt list --pinned                         # held-back versions only
mt list --json

mt info wget                             # version, tap, cellar path, pinned status
mt info --cask firefox

mt search ripgrep                        # brew-parity: queries the Homebrew API
mt search ripgrep --formula              # narrow
mt search ripgrep --installed            # local DB only; no network
mt search ripgrep --all                  # local + API, merged

mt uses openssl@3                        # direct dependents
mt uses --recursive openssl@3            # full transitive closure
mt deps ffmpeg                           # direct deps (forward of `uses`)
mt deps --recursive ffmpeg               # full forward closure
mt deps --installed -r node@20           # restrict to locally-resolved kegs
mt which jq                              # reverse lookup: bin -> keg-path
```

`mt which` accepts a bare name (resolved through `{prefix}/bin/<name>`) or an absolute path to a malt-managed symlink. Output is `<name> <version> <keg-path>` (or `{"name", "version", "keg"}` with `--json`). It's read-only and offline; exits non-zero with a clear message when the binary is not owned by malt.

`mt search` matches `brew search` by default - it queries the Homebrew API and ranks substring matches across formulas and casks. `--installed` flips it to a local-DB scan over `kegs.name` and `casks.token` (no network), `--all` runs both passes and merges results deduped, and `--api` is the explicit form of the default. `--offline` (or `MALT_OFFLINE=1`) collapses every scope into `--installed`, so a plane-mode user gets an answer instead of a connect timeout. `--json`, `--formula`, and `--cask` compose with every scope.

`mt deps` is the forward symmetric of `mt uses`: "_what does X depend on?_" instead of "_who depends on X?_". Installed kegs read from the local DB; uninstalled formulas walk the upstream API. `--installed` is offline-safe. `--json` emits one entry per visited node, preserving graph shape on recursive walks.

### Maintain malt

`mt doctor` runs a battery of health checks: SQLite integrity, directory layout, stale advisory locks, APFS volume detection, Homebrew API reachability, store/keg consistency, broken symlinks, low disk space, and post-install DSL coverage. It exits 0 (OK), 1 (warnings), 2 (errors).

```bash
mt doctor
mt doctor --fix                          # repair safe-class warnings
mt doctor --fix --dry-run                # preview the repair plan
mt doctor --post-install-status          # check DSL support per installed formula
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
| Broken symlinks     | All symlinks in bin/, lib/ etc. resolve       | Warn: suggest `mt cleanup`               |
| Disk space          | > 1 GB free on prefix volume                  | Warn: low disk space                     |
| Post-install DSL    | All installed post_install formulae parseable | Warn: unsupported construct              |

`--fix` repairs only the **safe** classes - actions that are reversible and never touch user data: stale advisory locks (recorded PID is dead), broken symlinks under `bin/`, `lib/`, `include/`, `share/`, `sbin/`, and orphaned store entries. Dangerous classes (corrupt DB, missing kegs, missing prefix directories, weak permissions, unpatched Mach-O placeholders) keep their inline manual remediation hint.

`mt purge` is the housekeeping and full-wipe entry point. A scope flag is required.

```bash
# Safe scopes
mt purge --store-orphans                 # refcount-0 store blobs
mt purge --unused-deps                   # orphaned dep kegs
mt purge --cache=30                      # cache files older than N days (default 30)
mt purge --stale-casks                   # cache + Caskroom for uninstalled casks
mt purge --housekeeping                  # all four safe scopes

# Destructive
mt purge --downloads                     # wipe {cache}/downloads
mt purge --old-versions                  # remove non-latest Cellar versions
mt purge --wipe                          # remove every malt artefact on disk
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

Shared flags: `--dry-run`/`-n` (preview), `--yes`/`-y` (skip typed-confirm), `--quiet`/`-q`, `--backup`/`-b <path>` (write a `mt restore`-compatible manifest before any deletion). `--wipe`-only flags: `--keep-cache` (preserve downloaded bottles), `--remove-binary` (also unlink `/usr/local/bin/{mt,malt}`).

Structured output for scripts: `mt --json purge --<scope>...` emits a single summary object on stdout (`version`, `dry_run`, `scopes`, `totals`, `time_ms`); `mt --output-format=ndjson purge ...` streams `scope_started` / `scope_completed` / `purge_complete` events, one per line. Stderr stays the human surface in either mode.

`--wipe` cannot combine with any other scope. Every other scope can run together under one lock acquisition. `mt purge` honours `MALT_PREFIX` and `MALT_CACHE`, so pointing those at a throwaway path is the safe way to test the command end-to-end. For per-package removal, use `mt uninstall`.

`mt cleanup` is a Homebrew-shaped alias for `mt purge --housekeeping`: the safe daily-driver scope (`--store-orphans --unused-deps --cache --stale-casks`). Trailing flags pass through unchanged (`mt cleanup --dry-run`, `mt cleanup --cache=7 --yes`), so weekly muscle memory works while the full scope menu stays under `mt purge`.

`mt link <formula>` and `mt unlink <formula>` manage the prefix symlinks. `link` reports conflicts and aborts unless `--overwrite`/`--force`/`-f` is passed. `unlink` removes symlinks from `bin/`, `lib/`, etc. and the `opt/` symlink, but leaves the keg installed.

### Background services

`mt services` is a drop-in for `brew services`:

```bash
mt services list                         # registered services + runtime state
mt services start postgresql@16          # launchctl bootstrap into gui/<uid>
mt services stop postgresql@16
mt services restart postgresql@16
mt services status postgresql@16
mt services logs postgresql@16 --tail 50
mt services logs postgresql@16 --stderr
mt services logs postgresql@16 -f        # tail and follow until SIGINT
```

Services are registered automatically when an installed formula carries a `service` block (e.g. `postgresql@16`, `redis`). Plist + log files live at `{prefix}/var/malt/services/<name>/`; runtime state in the SQLite `services` table. macOS-only - Linux/Windows return `OsNotSupported`.

### Reproducible setups

`mt bundle` is a drop-in for `brew bundle`, with no Brewfile conversion:

```bash
mt bundle install                        # ./Brewfile or ./Maltfile.json
mt bundle install path/to/Brewfile
mt bundle install --dry-run
mt bundle cleanup                        # remove direct packages absent from Brewfile
mt bundle cleanup --yes                  # skip the typed confirmation
mt bundle create                         # snapshot installed -> ./Brewfile
mt bundle create --format json my.json
mt bundle export                         # print to stdout
mt bundle list                           # registered bundles
mt bundle remove devtools                # unregister; --purge also uninstalls
mt bundle import path/to/Brewfile        # register without installing
```

Lookup order (no path given): `./Brewfile` → `./Maltfile.json` → `~/.config/malt/Brewfile` → `~/.config/malt/Maltfile.json`. Brewfile parsing covers `tap`, `brew`, `cask`, `mas`, `vscode`, plus hash options (`version:`, `restart_service:`, `link:`) and Ruby symbols (`restart_service: :changed`). Conditionals (`if OS.mac?`) and `do … end` blocks are rejected with a clear error pointing to `Maltfile.json`.

`mt backup` and `mt restore` cover the simpler case - a plain-text manifest of directly-installed packages, easy to hand-edit or check into dotfiles:

```bash
mt backup                                # writes malt-backup-<timestamp>.txt to cwd
mt backup -o my-setup.txt                # custom path; "-o -" writes to stdout
mt backup --versions                     # pin each entry to its installed version

mt restore my-setup.txt
mt restore my-setup.txt --dry-run
mt restore my-setup.txt --force
```

Only directly-installed packages are recorded; transitive dependencies are resolved on restore. The file format is one entry per line (`formula <name>` / `cask <token>`) with `#` comments. Restore batches into two `mt install` invocations, so dependency resolution, parallel downloads, and atomic install all apply. Lines with a `@<version>` suffix install at that version.

### Custom sources

```bash
mt tap user/repo                                  # register a tap
mt tap                                            # list registered taps
mt tap user/repo --repo owner/exact-repo          # prefixless GitHub repo
mt tap user/repo --repo owner/exact-repo --force  # rebind to a new repo
mt untap user/repo                                # remove a tap
```

Taps are auto-resolved during install (`mt install user/repo/formula`), so this is optional unless you want the explicit Homebrew-style workflow.

#### Supported forges

A tap can live on any of three forges. GitHub is the default; the others
register with an explicit `--host` (which always needs an explicit `--repo`,
since the `homebrew-<repo>` convention is GitHub-only).

| Forge                      | Hosts                                     | Register with                                                                               | Token env var         |
| -------------------------- | ----------------------------------------- | ------------------------------------------------------------------------------------------- | --------------------- |
| GitHub                     | `github.com`                              | `mt tap user/repo` (resolves `homebrew-repo`), or `--repo owner/repo` for a prefixless repo | `MALT_GITHUB_TOKEN`   |
| GitLab (incl. self-hosted) | `gitlab.com`, `gitlab.gnome.org`, custom  | `mt tap <slug> --host <host> --repo <owner>/<repo>`                                         | `MALT_GITLAB_TOKEN`   |
| Codeberg / Forgejo / Gitea | `codeberg.org`, self-hosted Forgejo/Gitea | `mt tap <slug> --host <host> --repo <owner>/<repo>`                                         | `MALT_CODEBERG_TOKEN` |

`gitlab.*` and `codeberg.org` auto-classify from the host. A custom domain that
doesn't reveal its provider (a self-hosted GitLab like `code.acme.com`, or a
Forgejo/Gitea instance) needs `--forge gitlab` or `--forge codeberg` so malt
knows which API to speak. See the [environment variables](#environment-variables)
table for what each token is sent as.

```bash
# GitLab — --host requires an explicit --repo
mt tap grp/tap --host gitlab.com --repo grp/homebrew-tap
mt tap grp/tap --url https://gitlab.com/grp/homebrew-tap   # same, from a full URL

# Self-hosted GitLab on a domain the host can't classify
mt tap acme/tap --host code.acme.com --forge gitlab --repo acme/tap

# Codeberg, and self-hosted Forgejo/Gitea
mt tap org/tap --host codeberg.org --repo org/homebrew-tap
mt tap org/tap --host git.acme.com --forge codeberg --repo org/tap
```

A non-GitHub tap registers unpinned; `mt tap --refresh <slug>` pins its current
HEAD. `mt doctor` lists every registered tap with the forge host it resolves
against, so you can confirm a `--host` registration landed where you intended.

#### Pinning caveat: prefer release assets over generated archives

GitLab `/-/archive/` and Gitea `/archive/` tarballs are **regenerated
server-side** — their gzip framing can change across a forge upgrade even when
the file contents don't. A tap formula that pins the `sha256` of such an archive
can therefore break on a forge upgrade. Prefer a **release-asset** URL (an
uploaded tarball, whose bytes are immutable) over a `/-/archive/` or `/archive/`
URL when you pin a `sha256`. If a pinned archive's digest later mismatches, malt
reports the usual `Sha256Mismatch`; on a generated-archive URL that often means
the forge re-generated the tarball rather than that the download is corrupt —
re-pin against a stable release asset.

### Manage malt

```bash
mt version                               # show current version
mt version update                        # interactive self-update
mt version update --check                # check only, no download
mt version update --yes                  # non-interactive (CI / scripts)
mt version update --cleanup              # remove stale .old + orphaned staging files

eval "$(mt shellenv)"                    # PATH/MANPATH; auto-detect from $SHELL
mt shellenv fish | source                # fish needs `set -gx`

eval "$(malt completions zsh)"           # run AFTER `compinit`
malt completions bash > /usr/local/etc/bash_completion.d/malt
malt completions fish > ~/.config/fish/completions/malt.fish
```

`mt version update` queries the GitHub releases API, verifies the release with cosign and SHA256 against the same trust anchor as `install.sh`, and atomically replaces the running binary. The previous binary is preserved at `<target>.old`; accumulated `.old` files (and any orphaned `.malt-update-<pid>` staging files from killed updates) can be cleaned with `--cleanup`, which makes no network calls. Homebrew-installed malt detects the brew receipt and points you at `brew upgrade --cask malt` instead of overwriting it.

To bypass cosign (strongly discouraged), `install.sh` accepts `MALT_ALLOW_UNVERIFIED=1`. `mt version update` requires both the env var **and** `--no-verify`, because update is the command that runs repeatedly:

```bash
MALT_ALLOW_UNVERIFIED=1 mt version update --no-verify
```

`mt shellenv` exports `HOMEBREW_PREFIX`, `HOMEBREW_CELLAR`, `HOMEBREW_REPOSITORY` (so brew-aware scripts keep sniffing) and prepends malt's `bin`, `sbin`, `share/man`, `share/info` onto `PATH`, `MANPATH`, `INFOPATH`. With no argument the shell is detected from `$SHELL`; an unrecognised `$SHELL` fails closed.

`mt completions` prints a completion script for `bash`, `zsh`, or `fish` to stdout, covering subcommands (for both `malt` and `mt`), per-command flags, global flags, and the positional shell name for `completions` itself. Unknown shells exit non-zero.

### Global flags

| Flag              | Description                                                                                                      |
| ----------------- | ---------------------------------------------------------------------------------------------------------------- |
| `--verbose`, `-v` | Verbose output                                                                                                   |
| `--debug`         | Surface every DSL diagnostic (implies verbose); pair with issue reports                                          |
| `--quiet`, `-q`   | Suppress non-error output                                                                                        |
| `--json`          | JSON output (read commands; also emits per-package `post_install` status lines)                                  |
| `--dry-run`       | Preview without executing                                                                                        |
| `--offline`       | Serve every fetch from the snapshot cache; fail fast with `OfflineRequired` on a miss (mirrors `MALT_OFFLINE=1`) |
| `--help`, `-h`    | Show help                                                                                                        |
| `--version`       | Show version                                                                                                     |

### Environment variables

| Variable                        | Description                                                                                                                                              | Default                        |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| `MALT_PREFIX`                   | Override install prefix                                                                                                                                  | `/opt/malt`                    |
| `MALT_CACHE`                    | Override cache directory                                                                                                                                 | `{prefix}/cache`               |
| `NO_COLOR`                      | Disable colored output                                                                                                                                   | unset                          |
| `MALT_NO_EMOJI`                 | Disable emoji in output                                                                                                                                  | unset                          |
| `MALT_NO_VERSION_NOTIFIER`      | Set to `1` to suppress the "newer malt available" notice                                                                                                 | unset                          |
| `MALT_PROGRESS`                 | Progress reporter for `install`/`upgrade`/`migrate`: `tty`, `plain`, or `none` (`CI=true` or `GITHUB_ACTIONS=true` flip the default to `plain`)          | `tty`                          |
| `MALT_THEME`                    | Force the output palette: `light`, `dark`, or `auto` (detects via OSC 11)                                                                                | `auto`                         |
| `HOMEBREW_GITHUB_API_TOKEN`     | GitHub token for higher API rate limits                                                                                                                  | unset                          |
| `MALT_GITHUB_TOKEN`             | GitHub token sent as `Authorization: Bearer` on tap `/commits/HEAD` calls only                                                                           | unset                          |
| `MALT_GITLAB_TOKEN`             | GitLab token (PAT) sent as `PRIVATE-TOKEN` on tap commit + raw `.rb` calls for GitLab-hosted taps                                                        | unset                          |
| `MALT_CODEBERG_TOKEN`           | Codeberg/Forgejo (Gitea) token sent as `Authorization: token` on tap commit + raw `.rb` calls; covers Codeberg and self-hosted Forgejo/Gitea             | unset                          |
| `MALT_HTTP_IDLE_TIMEOUT_SECS`   | HTTP idle (no-progress) read timeout in seconds (clamped to `[5, 600]`)                                                                                  | `30`                           |
| `MALT_API_DOMAIN`               | Override metadata API base URL; HTTPS only; falls back to `HOMEBREW_API_DOMAIN`                                                                          | `https://formulae.brew.sh/api` |
| `MALT_BOTTLE_DOMAIN`            | Override bottle registry base URL; HTTPS only; falls back to `HOMEBREW_BOTTLE_DOMAIN`                                                                    | `https://ghcr.io`              |
| `MALT_OFFLINE`                  | Set to `1`/`true` to route every fetch through the snapshot cache; misses surface `OfflineRequired` instead of stalling on connect (mirrors `--offline`) | unset                          |
| `MALT_MIGRATE_PARALLEL_WORKERS` | Worker count for `mt migrate --parallel` (clamped to `[1, 32]`)                                                                                          | `4`                            |
| `MALT_OUTDATED_MAX_AGE`         | TTL in hours for the `outdated.json` snapshot                                                                                                            | `24`                           |
| `MALT_ALLOW_RAW_POST_INSTALL`   | Disable terminal escape filter on ruby `post_install` output                                                                                             | unset                          |
| `MALT_ALLOW_UNVERIFIED`         | Skip cosign signature check in `install.sh` (use only when cosign is unavailable)                                                                        | unset                          |
| `MALT_ALLOW_UNVERIFIED_SOURCE`  | Allow `install.sh` to clone `main` when no release tag resolves                                                                                          | unset                          |

## Safety and security

malt's correctness rests on a few load-bearing properties:

- **SHA256 verification.** Streaming hash computed during download, verified before extraction. No unverified data touches the store.
- **Tar entry pre-scan.** Every entry's name **and symlink target** are validated before any byte is written; the 512-byte tar header is checksum-verified per entry; hardlinks are applied via `linkat(..., 0)`, which refuses to follow a symlink. A hostile tarball cannot land a hardlink inside the keg via a symlink to `/etc/passwd`.
- **Pre-flight checks.** Dependencies resolved, disk space verified, link conflicts detected before any download begins.
- **Atomic installs.** The 9-step protocol uses `errdefer` at every stage. Interrupted installs leave no partial state.
- **Concurrent access.** A 30-second-timeout advisory file lock prevents concurrent mutations. Read-only commands don't acquire it.
- **Upgrade rollback.** New version is fully installed and verified before the old version is touched.
- **Store immutability.** Store entries are never modified after commit. Patching happens on the Cellar clone.
- **Mach-O parser hardening.** Section offsets and string-table indices are validated against the slice using overflow-checked arithmetic, so a bottle with crafted load commands can't wrap an integer into a bounds-bypass.
- **DSL path sandboxing.** Every mutating operation in the post_install interpreter is validated against the Cellar/malt prefix; `..` and symlink-escape paths are rejected.
- **DSL `system` is argv-only.** The interpreter's `system` builtin spawns with an argv slice and pins the executable - never `/bin/sh -c`, never PATH-resolved. A formula that writes `system "rm", arg` cannot reach the parent shell.

The supply-chain story:

- **Signed releases.** Every release is cosign-signed keyless via GitHub OIDC; `install.sh` verifies the signature before trusting the SHA256 checksum. A leaked GitHub token is not enough to ship a malicious malt binary.
- **Pinned third-party source.** `homebrew-core` and third-party taps are pinned to a specific commit SHA. Formula Ruby source is SHA256-verified against an embedded manifest at that commit. A rewritten upstream branch cannot substitute a formula's bottle URL mid-install. Advance a tap pin explicitly with `mt tap --refresh user/repo`.
- **Sandboxed `post_install`.** The opt-in `--use-system-ruby` path runs inside a `sandbox-exec` profile scoped to the formula's cellar. Hostile formulas can affect their own install prefix and nothing else.
- **Boundary validation.** `MALT_PREFIX`, launchd service declarations, install-script checksums, and HTTP redirects fail-closed on malformed or suspicious input - no silent HTTPS→HTTP downgrades, no `/bin/sh` in service argv, no `..` in prefix paths.
- **Posture visibility.** `mt doctor` flags world- or group-writable paths and unexpected ownership under `/opt/malt`, so multi-user machines see their attack surface at a glance.

### Local formulas: the trust boundary

`mt install --local ./formula.rb` deserves its own paragraph because it is a code-execution surface in a way the rest of malt isn't. The `.rb` file names the archive URL and SHA256 of what ends up on your system - installing one trusts that file. Use it for your own formulas, for experimenting with upstream changes before they land in a tap, or for private in-house packages. Do not use it for a `.rb` you did not read.

malt prints the canonical realpath on every install so an attentive reader notices surprises like `/tmp/...`. A leading `./`, `/`, `~/`, or any embedded slash combined with a `.rb` suffix auto-detects as a local path; the same warning fires either way. Bare filenames (e.g. `wget.rb`) are _not_ auto-detected - pass `--local` to disambiguate. The archive URL must be `https://`; plaintext HTTP, `file://`, `ftp://`, and `data:` are rejected before any download. The SHA256 check uses constant-time compare. An extra ⚠ line fires if the `.rb` is world-writable or owned by a different user. Combining `--local` with `--cask`, `--formula`, or `--use-system-ruby` is refused up front.

For local installs, only the bottle-style `version` + `url` + `sha256` triple (optionally inside `on_macos` / `on_arm` / `on_intel`) is read. `depends_on` and `post_install` are _not_ evaluated; if you need either, publish the formula to a tap and install via `mt install user/tap/formula`. Archive formats: `.tar.gz`, `.tgz`, `.tar.xz`, `.zip`. The formula name comes from the file's basename - `hello.rb` installs `hello`. A minimal compatible `.rb`:

```ruby
class Hello < Formula
  version "1.2.3"
  on_macos do
    on_arm do
      url "https://example.com/hello-#{version}-arm64.tar.gz"
      sha256 "aaaa…"   # 64 hex chars
    end
    on_intel do
      url "https://example.com/hello-#{version}-x86_64.tar.gz"
      sha256 "bbbb…"
    end
  end
end
```

A flat `url` / `sha256` at the top level works for single-arch archives. See `scripts/fixtures/local_formulae/hello.rb` for a runnable example.

`--use-system-ruby` is also worth a word here. It is **per-formula** by design. The bare flag works only when installing a single package (`mt install jq --use-system-ruby`); multi-package installs must scope it (`mt install jq wget --use-system-ruby=jq`). `mt migrate` rejects the bare form entirely. This is deliberate: it prevents one package's failing `post_install` from silently widening the trust boundary across an entire batch.

## Architecture

malt's behaviour follows from a small number of design choices - each one a direct consequence of wanting safe concurrency and interruption survival.

### Its own prefix

malt installs to `/opt/malt` and never touches Homebrew. The path is short on purpose: Mach-O load command patching needs room to replace the original Homebrew path in-place, and `/opt/malt` always fits.

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

### Content-addressable store

Bottles are stored by their SHA256. The same bottle is never downloaded or extracted twice; multiple installed kegs reference the same store entry. Store entries are immutable - only `mt purge --store-orphans` removes them. Kegs in `Cellar/` are materialized via APFS `clonefile()`, which creates a copy-on-write clone at zero disk cost; non-APFS volumes fall back to a recursive copy.

This is what makes `mt rollback` an instant operation: every previously installed bottle is still in the store, so reverting is unlink → re-clone → DB update, with no re-download.

### Streaming download pipeline

Each bottle download is a single-pass pipeline:

```text
Network (HTTPS from GHCR CDN)
    ├──► SHA256 hasher (streaming - computed as chunks arrive)
    └──► gzip/zstd decompressor
            └──► tar extractor
                    └──► filesystem write to tmp/
```

No intermediate archive file is written to disk. The SHA256 is verified against the Homebrew API manifest immediately after the stream completes; on mismatch, the extracted directory is deleted before any commit happens.

### Mach-O patching

Homebrew bottles contain hardcoded `/opt/homebrew/Cellar/...` paths in Mach-O load commands. malt parses headers using struct-aware parsing (not raw byte scanning), identifies all relevant load commands (`LC_ID_DYLIB`, `LC_LOAD_DYLIB`, `LC_RPATH`, etc.), rewrites paths in-place, and pads the remaining space with null bytes. On arm64, every patched binary is ad-hoc codesigned via `codesign --force --sign -`. Text files (`.pc` configs, shell scripts) containing `@@HOMEBREW_PREFIX@@` or `@@HOMEBREW_CELLAR@@` placeholders are also patched. Patching always happens on the Cellar copy, never the store original; if it fails, the Cellar copy is deleted and the store entry remains pristine for retry.

### The post_install interpreter

When a formula defines `post_install`, malt tries the native interpreter first. The interpreter parses and evaluates the Ruby subset used in these blocks: `Pathname` operations, `FileUtils`, string interpolation, `inreplace`, `Dir.glob`, `if`/`unless`, `.each`/`.select`/`.map`, `Formula["name"]` cross-lookup, `ENV` access, `%w[]` arrays, the boolean operators. It only activates for formulas that define the method. Source for `homebrew-core` formulas is fetched on demand from GitHub if the tap isn't cloned locally.

Every mutating filesystem operation - write, rm, chmod, symlink - is validated against the formula's Cellar prefix and the malt prefix. Paths containing `..` or resolving outside the sandbox via symlinks are rejected immediately. When the interpreter hits an unsupported construct, the user is directed to `--use-system-ruby`, which delegates to a sandboxed Ruby subprocess scoped to the formula's cellar, with a scrubbed environment, `RLIMIT_CPU`/`AS`/`FSIZE` caps, and terminal escape sequences filtered from child output.

```text
Formula has post_install?
  │
  ├── yes → Try native DSL interpreter
  │           │
  │           ├── success → done (package fully configured)
  │           │
  │           └── unsupported construct → --use-system-ruby set?
  │                                         │
  │                                         ├── yes → delegate to sandboxed Ruby subprocess
  │                                         └── no  → skip with clear message
  │
  └── no  → done (no post_install needed)
```

### Atomic install protocol

Every install follows nine steps. Failure at any step triggers cleanup of that step only - no prior state is modified.

1. **Acquire lock** - exclusive advisory lock on `db/malt.lock`
2. **Pre-flight** - resolve dependencies, check disk space, detect link conflicts
3. **Download** - fetch bottles from GHCR CDN with streaming SHA256 verification
4. **Extract** - decompress and untar to `tmp/`
5. **Commit to store** - atomic rename from `tmp/` to `store/`
6. **Materialize** - APFS clonefile from `store/` to `Cellar/`, patch Mach-O, codesign
7. **Link** - create symlinks in `bin/`, `lib/`, etc., record in DB
8. **DB commit** - insert into kegs, dependencies, links tables in a single transaction
9. **Release lock** - clean up tmp files

Upgrades follow the same protocol on the new version before anything is removed from the old; on failure, the old symlinks are restored. Read-only commands (`list`, `info`, `search`) do not acquire the lock.

## Development builds

For hacking on malt itself - debug builds, the test suite, and a universal binary.

```bash
# Requires Zig 0.16.x
zig build                                # debug build
zig build -Doptimize=ReleaseSafe         # release build (~3 MB)
zig build test                           # run tests
zig build universal                      # universal binary (arm64 + x86_64 via lipo)
```

For installing malt from a local checkout (the end-user path), see [From source](#from-source) under Install.

## Benchmarks

Install times on macOS 14 (Apple Silicon).

<!-- BENCH:COLD:START -->

### Cold Install (median ±σ)

| Package              | malt         | nanobrew     | zerobrew      | Homebrew      |
| -------------------- | ------------ | ------------ | ------------- | ------------- |
| **tree** (0 deps)    | 0.664±0.109s | 0.719±0.038s | 1.673±0.084s  | 3.991±0.176s  |
| **wget** (6 deps)    | 3.337±0.131s | 4.090±0.557s | 7.858±0.357s  | 4.781±0.401s  |
| **ffmpeg** (11 deps) | 4.181±0.496s | 4.784±0.528s | 11.930±1.818s | 30.164±1.690s |

<!-- BENCH:COLD:END -->

<!-- BENCH:WARM:START -->

### Warm Install

| Package              | malt   | nanobrew | zerobrew |
| -------------------- | ------ | -------- | -------- |
| **tree** (0 deps)    | 0.008s | 0.012s   | 0.273s   |
| **wget** (6 deps)    | 0.012s | 0.016s   | 0.846s   |
| **ffmpeg** (11 deps) | 0.060s | 0.031s   | 5.490s   |

<!-- BENCH:WARM:END -->

<!-- BENCH:SIZE:START -->

### Binary Size

| Tool     | Size   |
| -------- | ------ |
| **malt** | 3.6 MB |
| nanobrew | 2.6 MB |
| zerobrew | 8.7 MB |

<!-- BENCH:SIZE:END -->

Apple Silicon (GitHub Actions macos-14), 2026-06-01. Auto-updated weekly via the [benchmark workflow](.github/workflows/benchmark.yml).

### Inside the binary

malt's binary is small because it ships only five subsystems and the glue between them:

- **SQLite.** ACID writes, reverse-dependency queries (`mt uses openssl@3`), linker-conflict detection before any symlink is created, atomic rollback after a failed upgrade. Survives `kill -9` mid-write.
- **Native `post_install` interpreter.** A Ruby-subset interpreter in Zig - lexer, parser, AST, builtins for `String` and `Pathname`. Only activates for formulas that define `post_install`. Packages like `node`, `openssl`, `fontconfig`, and `docbook` are fully configured by the time the install returns.
- **Mach-O patching with arm64 ad-hoc codesign.** Every binary patched to rewrite `/opt/homebrew` → `MALT_PREFIX` is re-signed so `dyld` will load it on modern macOS.
- **Install lock.** `flock` on `db/malt.lock` plus a symlink-tree walk that refuses to overwrite another keg's files, acquired by every mutating command. Two concurrent malt invocations - or a Ctrl-C'd install - cannot corrupt state.
- **`sandbox-exec` profile.** The opt-in `--use-system-ruby` path runs every formula script inside a deny-default sandbox with a scrubbed environment, `RLIMIT_CPU`/`AS`/`FSIZE` caps, and terminal-escape filtering on child output.

All five run per-install. The warm row above is their combined wall-clock cost.

### Methodology

Each cell is the **median of 5 rounds** (`BENCH_ROUNDS=5`, the default in [`scripts/bench.sh`](scripts/bench.sh)) - more robust to single-run jitter than a mean. Override with `BENCH_ROUNDS=N`. Every run also emits per-tool `_min` and `_stddev` keys to `$GITHUB_OUTPUT` and prints them in the local terminal summary.

A cold sample here starts from a wiped install prefix for every tool, so the first round exercises the full download → extract → link → db-write path. Some benchmark scripts define "cold" as an uninstall/reinstall, which keeps the download cache warm; the two definitions can produce different absolute cold numbers for the same tool on the same hardware.

`BENCH_TRUE_COLD=1` wipes each tool's install prefix **and** its bottle download cache before every cold sample, so "cold" really means "no bottle anywhere on disk." malt, nanobrew, and zerobrew keep their download cache inside their install prefix, so the single prefix wipe takes both. Homebrew's cache lives outside the prefix (`~/Library/Caches/Homebrew/downloads`) and is therefore wiped explicitly per target formula and its transitive deps via `brew --cache`. Without this symmetry, local brew numbers come out 5–25× faster than CI's because brew reuses bottles cached by earlier rounds.

Each package bench opens with a discarded warmup round - every tool runs one install/uninstall pair whose timings are thrown away - so DNS, TLS session cache, TCP congestion window, and disk caches are populated before timing starts. The measured rounds rotate tool order (round _r_ starts with `tools[r mod N]`), so no single tool reliably eats the "cold network" slot or benefits from the warmest one.

`scripts/bench.sh` `git fetch`es nanobrew and zerobrew before each build so the comparison is always malt-today vs. each peer's latest commit, not a weeks-old snapshot. Set `BENCH_SKIP_UPDATE=1` to pin whatever is already checked out.

Each tool is built using the release flags its upstream ships with: malt `ReleaseSafe` (matches [`.goreleaser.yaml`](.goreleaser.yaml)), nanobrew `ReleaseFast`, zerobrew `cargo build --release`. Binary sizes may differ from the numbers shown on each tool's own repo - the gap is almost always version drift, not a flag difference.

To reproduce locally, `./scripts/local-bench.sh` runs the four CI phases (tree, wget, ffmpeg, stress-test) in order. Add `--clean` to wipe `/tmp` bench state afterwards. For iterative work, `scripts/bench.sh <pkg>` directly - `SKIP_BUILD=1` reuses existing binaries; `SKIP_OTHERS=1` / `SKIP_BREW=1` skip peer comparisons.

## Contributing

Contributions are welcome. Please open an issue to discuss before submitting large changes. See [CONTRIBUTING](CONTRIBUTING.md).

## License

malt is licensed under the [MIT License](LICENSE). Third-party components and upstream projects - including Homebrew (BSD-2-Clause) and homebrew-core (BSD-2-Clause) - are acknowledged in the [LICENSE](LICENSE) file.
