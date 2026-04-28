# malt

**A fast, drop-in Homebrew alternative for macOS. Warm installs in milliseconds. `post_install` scripts that actually run.**

Reuses every formula, bottle, cask, tap, and `Brewfile` in the existing ecosystem; installs to its own prefix; ~3 MB single binary; ~3 ms cold start. Designed by a human and implemented by AI.

![macOS only](https://img.shields.io/badge/platform-macOS-blue)
![Version](https://img.shields.io/github/v/tag/indaco/malt?label=version&sort=semver&color=4c1)
![Coverage](.github/badges/coverage.svg)
![Zig 0.16.x](https://img.shields.io/badge/zig-0.16.x-orange)
![License](https://img.shields.io/badge/license-MIT-green)
[![Signed by cosign](https://img.shields.io/badge/signed-cosign-brightgreen?logo=sigstore&logoColor=white)](#security)
[![Built with Devbox](https://www.jetify.com/img/devbox/shield_galaxy.svg)](https://www.jetify.com/devbox/docs/contributor-quickstart/)

<p align="center">
  <b><a href="#why-malt-exists">Why malt</a></b> &middot;
  <b><a href="#features">Features</a></b> &middot;
  <b><a href="#install-and-first-commands">Install</a></b> &middot;
  <b><a href="#command-reference">Reference</a></b> &middot;
  <b><a href="#architecture">Architecture</a></b> &middot;
  <b><a href="#benchmarks">Benchmarks</a></b>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/demo.gif" alt="malt install jq tree ripgrep - demo" width="800">
</p>

## Why malt exists

Three observations shape malt.

**`post_install` is where most alternative Homebrew clients quietly give up.** A surprising number of formulas don't really finish installing the moment their files hit disk. They ship a `post_install` block - symlinks, man pages, config files, service registration - that the binary expects to find at runtime. Skip it and the package extracts fine but isn't actually usable. Other clients tend to either skip these scripts entirely or pattern-match a handful of well-known cases. malt ships a built-in Zig interpreter for the Ruby subset these blocks use, so packages like `node`, `openssl`, `fontconfig`, and `docbook` are fully configured by the time the install returns. Coverage isn't 100% - when the interpreter hits something it doesn't support, `--use-system-ruby` delegates to a sandboxed Ruby subprocess, and the absence of either path is _reported_, not silently ignored.

**Cold installs happen once. Warm installs happen forever.** The first `brew install ffmpeg` on a fresh checkout is a one-time cost. Every reinstall, upgrade, devbox/nix-style rebuild, and CI cache restore after it is a _warm_ install against an existing store. Over a developer's working life the ratio is roughly 1 cold to 10+ warm - so the warm row is where the minutes actually compound. malt is fast on both axes, but the warm gap is the one that shows up in daily use: `tree` (0 deps) in **12 ms**, `wget` (6 deps) in **7 ms**, `ffmpeg` (11 deps) in **24 ms**. Most warm installs finish before you've finished reading the output line.

**A package manager is also a piece of infrastructure on your machine.** It runs as your user, writes to a privileged-ish prefix, downloads code from the internet, and patches Mach-O headers. It deserves the posture of any other root-adjacent tool: streaming SHA256 before extraction, atomic installs with full rollback on failure, an advisory lock against concurrent mutations, sandboxed subprocesses for the opt-in Ruby path, and cosign-verified releases pinned to their build workflow. malt's binary is ~3 MB and starts in ~3 ms. None of the safety properties are paid for in startup time.

malt installs to `/opt/malt`, never touches Homebrew's files, reads existing `Brewfile`s without conversion, and transparently delegates anything it doesn't implement to `brew` if it's installed. It is a client for the Homebrew registry, not a fork.

## How malt is built

malt is a study in human-directed AI implementation. The design, architecture, threat model, and every merged change were directed and reviewed by a human. The implementation - every commit of Zig - was produced by AI ([Claude Code](https://claude.ai/code) and [ruflo](https://github.com/ruvnet/ruflo)).

The fragile thing about AI-generated code isn't the first commit - it's the tenth. malt has been refactored end-to-end more than once: the install protocol, the post_install interpreter, the Mach-O patcher. Every round was steered by design notes, ADRs, and security review the model wouldn't have written on its own. malt has a SQLite schema with referential integrity, a 9-step install protocol with a global advisory lock, a streaming download pipeline that hashes and decompresses concurrently, a Mach-O parser that rewrites load commands and re-codesigns on arm64, and a sandboxed interpreter for a subset of Ruby. The benchmarks below say what it does on those parts. The repository, the test suite, and the running tool are the evidence on offer.

## Features

If you're scanning rather than reading, here is the surface area in one place.

- **Drop-in for Homebrew workflows** - installs formulas, casks, tap formulas, and inline tap shortcuts (`user/tap/formula`); reads existing `Brewfile`s with no conversion; `mt shellenv` is a drop-in for `eval "$(brew shellenv)"`; `mt services` is a drop-in for `brew services`.
- **Native `post_install` execution** - a built-in Zig interpreter runs Homebrew `post_install` scripts natively, so packages actually work after install.
- **System Ruby fallback** - `--use-system-ruby` (per-formula by design) delegates to any installed Ruby for the handful of scripts the interpreter doesn't cover.
- **Isolated prefix** - installs to `/opt/malt`, never touches Homebrew's files; both managers can coexist on the same machine.
- **Content-addressable, deduplicated store** - bottles indexed by SHA256; the same bottle is never downloaded or extracted twice across versions or kegs.
- **Parallel downloads** - multiple packages fetch simultaneously under one lock.
- **Brew fallback** - anything malt doesn't implement is silently delegated to `brew` if installed.
- **Atomic upgrades + instant rollback** - new version verified before old is touched; `mt rollback` reverts from the store with no re-download.
- **Ephemeral run** - `mt run <pkg> -- <args...>` launches a binary without a permanent install; `--keep` caches the bottle for next time.
- **Background services** - `mt services` manages launchd processes (`bootstrap`, `bootout`, `status`, `logs --tail/-f`).
- **Bundles + plain-text backups** - `mt bundle` for Brewfile/Maltfile workflows, `mt backup` / `mt restore` for hand-editable manifests.
- **Polished output** - readable by default; `--json` everywhere it makes sense; `NO_COLOR`, `MALT_NO_EMOJI`, `MALT_THEME` for shaping output.
- **Path-sandboxed `post_install`** - every mutating filesystem op in the interpreter is validated against the formula's Cellar and the malt prefix.
- **Safe under concurrency** - a 30 s advisory file lock prevents concurrent mutations; read-only commands don't acquire it.
- **Signed, verifiable releases** - every release is cosign-signed keyless via GitHub OIDC; `install.sh` and `mt version update` verify the signature before trusting the SHA256 checksum.

> [!NOTE]
> **Compatibility note.** "Drop-in" covers the directives a typical `Brewfile` uses - `tap`, `brew`, `cask`, `mas`, and `vscode` (the last two round-trip through the parser but are not yet installed by malt) - plus hash options and Ruby symbols. It does _not_ cover Ruby `do … end` blocks or conditionals like `if OS.mac?`. Both raise a clear error; the conditional error points to `Maltfile.json` for the power-user case. macOS only - Linux and Windows are out of scope.

## Install and first commands

Three install paths - pick the one that matches your setup.

### One-liner script (recommended)

The script downloads the latest release, verifies the SHA256 checksum **and a cosign keyless signature** against the GitHub Actions workflow that produced it, installs the binary to `/usr/local/bin/`, and creates `/opt/malt` with proper ownership.

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash
```

The script needs [`cosign`](https://docs.sigstore.dev/cosign/system_config/installation/) on your `PATH`. To bypass verification (not recommended), set `MALT_ALLOW_UNVERIFIED=1`. If no release matches your platform, the script falls back to building from source.

Once `install.sh` runs, every subsequent download is re-verified with cosign - the trust anchor shifts from "whatever HTTPS returned" to the Sigstore-pinned workflow identity. To verify `install.sh` itself out of band, pin to a release tag and compare its SHA256 against the release notes:

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

The qualified `<tap>/<cask>` shorthand taps implicitly. Upgrade with `brew upgrade --cask malt`. malt's own `mt version update` detects Homebrew installs and defers to `brew` automatically - overwriting a brew-managed binary would corrupt its install receipt.

### From source

Clone the repo and run the install script. It detects the local checkout and builds from source automatically:

```bash
git clone https://github.com/indaco/malt.git
cd malt
./scripts/install.sh
```

Building requires [Zig 0.16.x](https://ziglang.org/download/) and produces both `malt` and `mt` (a built-in alias) in `zig-out/bin/`. For development builds (debug, tests, universal binary), see [Development builds](#development-builds).

### First commands

After install, make malt's binaries discoverable in new shells. `mt shellenv` is a drop-in for `eval "$(brew shellenv)"`:

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

`mt` and `malt` are the same binary; both names ship with every install method. Additional aliases: `remove` for `uninstall`, `ls` for `list`. Anywhere a flag accepts `--formula` or `--cask`, it also accepts `--formulae` or `--casks` - pick whichever reads more naturally.

If you typed something malt doesn't implement, malt checks for `brew` and silently delegates. If `brew` isn't installed:

```text
malt: '<cmd>' is not a malt command and brew was not found.
Install Homebrew: https://brew.sh
```

## Safety and security

The correctness story rests on a few load-bearing properties:

- **SHA256 verification.** Streaming hash computed during download, verified before extraction. No unverified data touches the store.
- **Pre-flight checks.** Dependencies resolved, disk space verified, link conflicts detected before any download begins.
- **Atomic installs.** The 9-step protocol uses `errdefer` at every stage. Interrupted installs leave no partial state.
- **Concurrent access.** A 30-second-timeout advisory file lock prevents concurrent mutations. Read-only commands don't acquire it.
- **Upgrade rollback.** New version is fully installed and verified before the old version is touched.
- **Store immutability.** Store entries are never modified after commit. Patching happens on the Cellar clone.
- **DSL path sandboxing.** Every mutating operation in the post_install interpreter is validated against the Cellar/malt prefix; `..` and symlink-escape paths are rejected.

The supply-chain story:

- **Signed releases.** Every release is cosign-signed keyless via GitHub OIDC; `install.sh` verifies the signature before trusting the SHA256 checksum. A leaked GitHub token is not enough to ship a malicious malt binary.
- **Pinned third-party source.** `homebrew-core` and third-party taps are pinned to a specific commit SHA. Formula Ruby source is SHA256-verified against an embedded manifest at that commit. A rewritten upstream branch cannot substitute a formula's bottle URL mid-install. Advance a tap pin explicitly with `mt tap --refresh user/repo`.
- **Sandboxed `post_install`.** The opt-in `--use-system-ruby` path runs inside a `sandbox-exec` profile scoped to the formula's cellar. Hostile formulas can affect their own install prefix and nothing else.
- **Boundary validation.** `MALT_PREFIX`, launchd service declarations, install-script checksums, and HTTP redirects fail-closed on malformed or suspicious input - no silent HTTPS→HTTP downgrades, no `/bin/sh` in service argv, no `..` in prefix paths.
- **Posture visibility.** `mt doctor` flags world- or group-writable paths and unexpected ownership under `/opt/malt`, so multi-user machines see their attack surface at a glance.

## Local formulas: the trust boundary

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

## Command reference

Commands grouped by what you're doing. Every command works with `malt` or `mt`, accepts `--help` for the full flag list, and supports `--quiet`, `--dry-run` (where mutating), and `--json` (where applicable). See [Global flags](#global-flags) for the cross-cutting set.

At a glance - `malt -h`:

```text
malt - a fast macOS package manager (Homebrew-compatible)

Usage: malt <command> [options] [arguments]
       mt <command> [options] [arguments]    (alias)

Commands:
  install       Install formulas, casks, or tap formulas
  uninstall     Remove installed packages
  upgrade       Upgrade installed packages
  update        Refresh metadata cache
  outdated      List packages with newer versions available
  list          List installed packages
  info          Show detailed package information
  search        Search formulas and casks
  uses          Show installed packages that depend on a formula
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

`mt run <pkg> -- <args...>` runs a binary without a permanent install. Useful for one-off invocations:

```bash
mt run jq -- --version
mt run --keep ripgrep -- --help          # cache the bottle for next run
```

`--keep` extracts under `{cache}/run/<sha256>/` so subsequent calls skip the download. The cache is wiped by `mt purge --cache`.

`mt uninstall` removes a package, refusing if dependents exist or, for casks, if the application is running. `--force` (`-f`) bypasses both checks. `--cask` forces cask uninstall. Store entries are preserved for `mt purge --store-orphans`.

`mt migrate` imports an existing Homebrew installation by scanning the Cellar and reinstalling each package through malt. It never modifies the Homebrew install. Packages with `post_install` are executed via the native interpreter; unsupported scripts fall back to `--use-system-ruby` or are skipped with a report. `--dry-run` previews.

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

mt search ripgrep                        # search formulas + casks
mt search ripgrep --formula              # narrow

mt uses openssl@3                        # direct dependents
mt uses --recursive openssl@3            # full transitive closure
mt which jq                              # reverse lookup: bin -> keg-path
```

`mt which` accepts a bare name (resolved through `{prefix}/bin/<name>`) or an absolute path to a malt-managed symlink. Output is `<name> <version> <keg-path>` (or `{"name", "version", "keg"}` with `--json`). It's read-only and offline; exits non-zero with a clear message when the binary is not owned by malt.

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
| Broken symlinks     | All symlinks in bin/, lib/ etc. resolve       | Warn: suggest `mt purge --housekeeping`  |
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

`--wipe` cannot combine with any other scope. Every other scope can run together under one lock acquisition. `mt purge` honours `MALT_PREFIX` and `MALT_CACHE`, so pointing those at a throwaway path is the safe way to test the command end-to-end. For per-package removal, use `mt uninstall`.

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
mt tap user/repo                         # register a tap
mt tap                                   # list registered taps
mt untap user/repo                       # remove a tap
```

Taps are auto-resolved during install (`mt install user/repo/formula`), so this is optional unless you want the explicit Homebrew-style workflow.

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

| Flag              | Description                                                                     |
| ----------------- | ------------------------------------------------------------------------------- |
| `--verbose`, `-v` | Verbose output                                                                  |
| `--debug`         | Surface every DSL diagnostic (implies verbose); pair with issue reports         |
| `--quiet`, `-q`   | Suppress non-error output                                                       |
| `--json`          | JSON output (read commands; also emits per-package `post_install` status lines) |
| `--dry-run`       | Preview without executing                                                       |
| `--help`, `-h`    | Show help                                                                       |
| `--version`       | Show version                                                                    |

### Environment variables

| Variable                       | Description                                                                       | Default          |
| ------------------------------ | --------------------------------------------------------------------------------- | ---------------- |
| `MALT_PREFIX`                  | Override install prefix                                                           | `/opt/malt`      |
| `MALT_CACHE`                   | Override cache directory                                                          | `{prefix}/cache` |
| `NO_COLOR`                     | Disable colored output                                                            | unset            |
| `MALT_NO_EMOJI`                | Disable emoji in output                                                           | unset            |
| `MALT_THEME`                   | Force the output palette: `light`, `dark`, or `auto` (detects via OSC 11)         | `auto`           |
| `HOMEBREW_GITHUB_API_TOKEN`    | GitHub token for higher API rate limits                                           | unset            |
| `MALT_GITHUB_TOKEN`            | GitHub token sent as `Authorization: Bearer` on tap `/commits/HEAD` calls only    | unset            |
| `MALT_OUTDATED_MAX_AGE`        | TTL in hours for the `outdated.json` snapshot                                     | `24`             |
| `MALT_ALLOW_UNVERIFIED`        | Skip cosign signature check in `install.sh` (use only when cosign is unavailable) | unset            |
| `MALT_ALLOW_UNVERIFIED_SOURCE` | Allow `install.sh` to clone `main` when no release tag resolves                   | unset            |
| `MALT_ALLOW_RAW_POST_INSTALL`  | Disable terminal escape filter on ruby `post_install` output                      | unset            |

## Architecture

malt's behaviour follows from a small number of design choices. None of them are exotic; they're the ordinary choices for a package manager that wants to be safe under concurrency and survive interruption.

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

When a formula defines `post_install`, malt tries the native interpreter first. The interpreter parses and evaluates the Ruby subset used in these blocks: `Pathname` operations, `FileUtils`, string interpolation, `inreplace`, `Dir.glob`, `if`/`unless`, `.each`/`.select`/`.map`, `Formula["name"]` cross-lookup, `ENV` access, `%w[]` arrays, the boolean operators. It adds under 80 KB to the binary and only activates for formulas that define the method. Source for `homebrew-core` formulas is fetched on demand from GitHub if the tap isn't cloned locally.

Every mutating filesystem operation - write, rm, chmod, symlink - is validated against the formula's Cellar prefix and the malt prefix. Paths containing `..` or resolving outside the sandbox via symlinks are rejected immediately. When the interpreter hits a construct it doesn't support, the situation isn't silent: the user is directed to `--use-system-ruby`, which delegates to a sandboxed Ruby subprocess scoped to the formula's cellar, with a scrubbed environment, `RLIMIT_CPU`/`AS`/`FSIZE` caps, and terminal escape sequences filtered from child output.

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

Install times on macOS 14 (Apple Silicon), comparing malt against other Homebrew-compatible package managers.

<!-- BENCH:SIZE:START -->

### Binary size

| Tool     | Size   |
| -------- | ------ |
| **malt** | 3.2 MB |
| nanobrew | 2.6 MB |
| zerobrew | 8.6 MB |

<!-- BENCH:SIZE:END -->

<!-- BENCH:COLD:START -->

### Cold install (median ±σ)

| Package              | malt         | nanobrew     | zerobrew     | Homebrew      |
| -------------------- | ------------ | ------------ | ------------ | ------------- |
| **tree** (0 deps)    | 0.730±0.062s | 0.796±0.076s | 1.131±0.038s | 3.338±0.200s  |
| **wget** (6 deps)    | 2.827±0.201s | 3.074±0.344s | 4.899±0.108s | 3.387±0.110s  |
| **ffmpeg** (11 deps) | 3.319±0.254s | 2.807±0.364s | 5.494±0.175s | 15.615±0.532s |

<!-- BENCH:COLD:END -->

<!-- BENCH:WARM:START -->

### Warm install

| Package              | malt   | nanobrew | zerobrew |
| -------------------- | ------ | -------- | -------- |
| **tree** (0 deps)    | 0.012s | 0.013s   | 0.235s   |
| **wget** (6 deps)    | 0.007s | 0.010s   | 0.633s   |
| **ffmpeg** (11 deps) | 0.024s | 0.015s   | 2.196s   |

<!-- BENCH:WARM:END -->

Apple Silicon (GitHub Actions macos-14), 2026-04-28. Auto-updated weekly via the [benchmark workflow](.github/workflows/benchmark.yml).

### What's in the 3 MB

malt is a few hundred kilobytes heavier than the lightest Homebrew alternative on the table, and on cold installs that mass shows up as a few hundred milliseconds of extra work. Both costs are deliberate. They pay for engineering that lighter clients leave out:

- **A real database (~1.5 MB of the 3 MB binary).** SQLite gives malt ACID writes, reverse-dependency queries (`mt uses openssl@3`), linker-conflict detection before any symlink is created, and atomic rollback after a failed upgrade. A flat JSON state file is smaller; it also can't survive an interrupted write.
- **A native `post_install` interpreter.** Running a Ruby subset in Zig means `node`, `openssl`, `fontconfig`, `docbook`, and the rest of the formulas that ship `post_install` blocks are actually configured by the time the install returns - no Ruby subprocess required. Without this, those packages extract fine but aren't usable.
- **Mach-O patching with arm64 ad-hoc codesign (~15 ms/pkg).** Every binary patched to rewrite `/opt/homebrew` → `MALT_PREFIX` is re-signed so `dyld` will load it. Skip this and the binaries fail to launch on modern macOS.
- **Global install lock + pre-link conflict check (~3 ms).** `flock` on `db/malt.lock` plus a symlink-tree walk that refuses to overwrite another keg's files. This is what keeps two concurrent malt invocations - or an Ctrl-C'd install - from corrupting state.

On the warm row, where the cost of these features is amortized to near zero, malt is at the fast end of the comparison set: every warm install in the table finishes in under 25 ms, with `wget` at 7 ms and `tree` within a millisecond of the lightest peer.

### Methodology

Each cell is the **median of 5 rounds** (`BENCH_ROUNDS=5`, the default in [`scripts/bench.sh`](scripts/bench.sh)). The median damps single-run jitter - network hiccups, launchd transients, disk-cache warm-up - without inflating the table the way a mean over a noisy sample would. Override with `BENCH_ROUNDS=N`. Every run also emits per-tool `_min` and `_stddev` keys to `$GITHUB_OUTPUT` and prints them in the local terminal summary.

A cold sample here starts from a wiped install prefix for every tool, so the first round exercises the full download → extract → link → db-write path. Some benchmark scripts define "cold" as an uninstall/reinstall, which keeps the download cache warm; the two definitions can produce different absolute cold numbers for the same tool on the same hardware.

`BENCH_TRUE_COLD=1` wipes each tool's install prefix **and** its bottle download cache before every cold sample, so "cold" really means "no bottle anywhere on disk." malt, nanobrew, and zerobrew keep their download cache inside their install prefix, so the single prefix wipe takes both. Homebrew's cache lives outside the prefix (`~/Library/Caches/Homebrew/downloads`) and is therefore wiped explicitly per target formula and its transitive deps via `brew --cache`. Without this symmetry, local brew numbers come out 5–25× faster than CI's because brew reuses bottles cached by earlier rounds.

Each package bench opens with a discarded warmup round - every tool runs one install/uninstall pair whose timings are thrown away - so DNS, TLS session cache, TCP congestion window, and disk caches are populated before timing starts. The measured rounds rotate tool order (round _r_ starts with `tools[r mod N]`), so no single tool reliably eats the "cold network" slot or benefits from the warmest one.

`scripts/bench.sh` `git fetch`es nanobrew and zerobrew before each build so the comparison is always malt-today vs. each peer's latest commit, not a weeks-old snapshot. Set `BENCH_SKIP_UPDATE=1` to pin whatever is already checked out.

Each tool is built using the release flags its upstream ships with: malt `ReleaseSafe` (matches [`.goreleaser.yaml`](.goreleaser.yaml)), nanobrew `ReleaseFast`, zerobrew `cargo build --release`. Binary sizes may differ from the numbers shown on each tool's own repo - the gap is almost always version drift, not a flag difference.

To reproduce locally, `./scripts/local-bench.sh` runs the four CI phases (tree, wget, ffmpeg, stress-test) in order. Add `--clean` to wipe `/tmp` bench state afterwards. For iterative work, `scripts/bench.sh <pkg>` directly - `SKIP_BUILD=1` reuses existing binaries; `SKIP_OTHERS=1` / `SKIP_BREW=1` skip peer comparisons.

bru previously appeared in this table but was dropped: upstream pins Zig 0.15.2 and relies on `std.heap.ThreadSafeAllocator`, which was removed in Zig 0.16 (what malt and nanobrew now build on). It will be re-added once upstream catches up.

## Contributing

Contributions are welcome. Please open an issue to discuss before submitting large changes.

## License

malt is licensed under the [MIT License](LICENSE). Third-party components and upstream projects - including Homebrew (BSD-2-Clause) and homebrew-core (BSD-2-Clause) - are acknowledged in the [LICENSE](LICENSE) file.
