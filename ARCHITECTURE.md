# Architecture

This document describes how malt is built and what it guarantees. For install and use, refer to the [README](README.md).

A small number of design choices control the behaviour of malt. Each choice comes from two requirements: safe concurrency, and recovery after an interruption.

## Its own prefix

malt installs to `/opt/malt` and does not change Homebrew. The path is short on purpose. Mach-O load command patching replaces the original Homebrew path in place, and the new path must fit in the same space. `/opt/malt` always fits.

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

## Content-addressable store

malt stores bottles by their SHA256. Thus, malt never downloads or extracts the same bottle two times. Many installed kegs can refer to the same store entry. Store entries are immutable, and only `mt purge --store-orphans` removes them. malt makes the kegs in `Cellar/` with APFS `clonefile()`. This makes a copy-on-write clone that uses no additional disk space. On a volume that is not APFS, malt makes a recursive copy instead.

Thus, `mt rollback` completes immediately. All previously installed bottles are still in the store. A rollback is unlink → clone again → DB update, with no new download.

## Streaming download pipeline

Each bottle download is a single-pass pipeline:

```text
Network (HTTPS from GHCR CDN)
    ├──► SHA256 hasher (streaming - computed as chunks arrive)
    └──► gzip/zstd decompressor
            └──► tar extractor
                    └──► filesystem write to tmp/
```

malt does not write an intermediate archive file to disk. When the stream completes, malt verifies the SHA256 against the Homebrew API manifest. If the SHA256 does not match, malt deletes the extracted directory before a commit occurs.

## Mach-O patching

Homebrew bottles contain hardcoded `/opt/homebrew/Cellar/...` paths in Mach-O load commands. malt corrects them in four steps:

1. Parse the headers with struct-aware parsing, not with raw byte scans.
2. Find all relevant load commands (`LC_ID_DYLIB`, `LC_LOAD_DYLIB`, `LC_RPATH`, and others).
3. Write the new paths in place and fill the remaining space with null bytes.
4. On arm64, apply an ad-hoc codesign to the patched binary with `codesign --force --sign -`.

Text files (`.pc` configs, shell scripts) can contain `@@HOMEBREW_PREFIX@@` or `@@HOMEBREW_CELLAR@@` placeholders. malt patches them in the same way. malt always patches the Cellar copy, never the original in the store. If the patch fails, malt deletes the Cellar copy. The store entry stays unchanged for a new attempt.

## Post-install and flight steps

Most alternative clients stop when the files are in place. malt also runs the configuration that a package declares. It supports the two forms that Homebrew supports.

### Declarative steps

Homebrew v6 added a declarative `post_install_steps` array for formulae, and homebrew-core now uses it everywhere. malt runs these steps natively during install, upgrade, and migrate. If a formula declares steps, malt configures it with only these steps. malt does not run its Ruby `post_install`, if there is one.

Casks declare the same step schema as `preflight_steps`, `postflight_steps`, `uninstall_preflight_steps`, and `uninstall_postflight_steps` (Homebrew v7).

- **Install.** `mt install --cask` runs the preflight steps on the staged artefact before it puts files in place. It runs the postflight steps after it records the cask.
- **Uninstall, upgrade, rollback.** `mt uninstall`, `mt upgrade`, and `mt rollback` run the steps that malt stored at install time. Thus, the steps match the version on disk. These commands also remove the symlinks that a cask declared for removal.
- **Confinement.** Cask steps can change only the Caskroom, the malt prefix, `$HOME/Library`, and the applications directory. They cannot remove or move these roots or their top-level directories. They also cannot remove or move anything under `Keychains`, `Mail`, `Messages`, `Safari`, `Accounts`, `Mobile Documents`, and `CloudStorage`.
- **No privilege escalation.** malt reports and skips steps that need `sudo`. It never escalates.
- **Unconfined steps.** `terminate_process` and `delete_keychain_certificate` act on the user session as upstream defines them. malt does not confine them.
- **Failures.** If an uninstall preflight fails, the cask stays on disk. `mt uninstall --force` continues after the failure.
- **Dry runs.** `mt install --dry-run` lists the steps that a cask would run and the steps that malt refuses. `mt upgrade --dry-run` does not list them. `mt uninstall --dry-run` stops before the steps.

### Ruby `post_install`

Homebrew 7 deprecates the Ruby `post_install` hook and recommends `post_install_steps`, but it still runs the hook. homebrew-core has migrated, but many third-party taps have not. For these formulae, malt tries its native interpreter first. The interpreter parses and evaluates the Ruby subset that these blocks use:

- `Pathname` operations, `FileUtils`, `inreplace`, `Dir.glob`
- string interpolation, `%w[]` arrays, the boolean operators
- control flow: `if`/`unless`, `.each`/`.select`/`.map`
- `Formula["name"]` cross-lookup, `ENV` access

If the `homebrew-core` tap is not cloned locally, malt gets the formula source from GitHub when it needs it.

malt validates each filesystem operation that makes a change (write, rm, chmod, symlink). The path must be in the Cellar prefix of the formula or in the malt prefix. malt immediately rejects paths that contain `..` and paths that resolve outside the sandbox through symlinks.

If the interpreter finds an unsupported construct, malt tells the user to use `--use-system-ruby`. This flag sends the block to a sandboxed Ruby subprocess. The sandbox is limited to the cellar of the formula and has:

- a clean environment
- `RLIMIT_CPU`/`AS`/`FSIZE` limits
- a filter that removes terminal escape sequences from child output

```text
Formula declares post_install_steps?
  │
  ├── yes → run the declarative steps natively → done
  │
  └── no  → Formula has a Ruby post_install?
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
              └── no  → done (no post-install needed)
```

## Atomic install protocol

Each install has nine steps. If a step fails, malt cleans up only that step. No prior state changes.

1. **Acquire lock**: get an exclusive advisory lock on `db/malt.lock`.
2. **Pre-flight**: resolve dependencies, check disk space, and find link conflicts.
3. **Download**: get bottles from the GHCR CDN with streaming SHA256 verification.
4. **Extract**: decompress and untar to `tmp/`.
5. **Commit to store**: rename atomically from `tmp/` to `store/`.
6. **Materialize**: clone from `store/` to `Cellar/` with APFS clonefile, patch Mach-O, and codesign.
7. **Link**: make symlinks in `bin/`, `lib/`, and other directories, and record them in the DB.
8. **DB commit**: write to the kegs, dependencies, and links tables in one transaction.
9. **Release lock**: clean up the tmp files.

An upgrade runs the same protocol on the new version before it removes anything from the old version. If the upgrade fails, malt restores the old symlinks. Read-only commands (`list`, `info`, `search`) do not get the lock.

## Safety and security

The correctness of malt depends on these properties:

- **SHA256 verification.** malt calculates the hash during the download and verifies it before extraction. No unverified data gets into the store.
- **Tar entry pre-scan.** malt validates the name and symlink target of each entry before it writes a byte. It verifies the checksum of each 512-byte tar header. malt applies hardlinks with `linkat(..., 0)`, which does not follow a symlink. Thus, a hostile tarball cannot use a symlink to `/etc/passwd` to put a hardlink inside the keg.
- **Pre-flight checks.** Before a download starts, malt resolves dependencies, verifies disk space, and finds link conflicts.
- **Atomic installs.** The 9-step protocol uses `errdefer` at each stage. An interrupted install leaves no partial state.
- **Concurrent access.** An advisory file lock with a 30-second timeout prevents concurrent changes. Read-only commands do not get the lock.
- **Upgrade rollback.** malt fully installs and verifies the new version before it changes the old version.
- **Store immutability.** malt never changes a store entry after the commit. Patches apply to the Cellar clone.
- **Mach-O parser hardening.** malt validates section offsets and string-table indices against the slice with overflow-checked arithmetic. Thus, a bottle with crafted load commands cannot cause an integer wrap that bypasses a bounds check.
- **DSL path sandboxing.** malt validates each change operation in the post_install interpreter against the Cellar and malt prefixes. It rejects `..` paths and paths that escape through symlinks.
- **DSL `system` is argv-only.** The `system` builtin of the interpreter starts the process with an argv slice and a fixed executable. It never uses `/bin/sh -c` and never resolves the executable through PATH. Thus, a formula that writes `system "rm", arg` cannot get to the parent shell.

These properties protect the supply chain:

- **Signed releases.** Each release has a keyless cosign signature through GitHub OIDC. `install.sh` verifies the signature before it trusts the SHA256 checksum. Thus, a leaked GitHub token is not sufficient to ship a malicious malt binary.
- **Pinned third-party source.** malt pins `homebrew-core` and third-party taps to a specific commit SHA. It verifies the SHA256 of the formula Ruby source against an embedded manifest at that commit. Thus, a rewritten upstream branch cannot change the bottle URL of a formula during an install. To move a tap pin forward, run `mt tap --refresh user/repo`.
- **Sandboxed `post_install`.** The opt-in `--use-system-ruby` path runs in a `sandbox-exec` profile that is limited to the cellar of the formula. A hostile formula can change only its own install prefix.
- **Boundary validation.** `MALT_PREFIX`, `MALT_CACHE`, launchd service declarations, install-script checksums, and HTTP redirects fail closed on malformed or suspicious input. malt does not downgrade from HTTPS to HTTP. It does not accept `/bin/sh` in service argv or `..` in prefix paths.
- **Checksum rules.** malt refuses a cask that declares no `sha256`, and does not treat it as opted out. Only the explicit `sha256 :no_check` of an API cask skips verification. Tap and local `.rb` packages must pin a `sha256` of 64 lowercase hex characters. A package that declares `sha256 :no_check` installs only with `--allow-unpinned`, with a warning, and never as a `.pkg`.
- **HTTPS manifest URLs.** A manifest URL must use `https://`, unless a digest already pins the bytes that it returns. Thus, the few upstream packages that still use plaintext continue to install. But malt refuses a package if no hash verifies it.
- **Trusted verifier.** `mt version update` refuses a `cosign` that resolves inside `/opt/malt`, because packages can write to that directory. Thus, a shim in that directory cannot approve a malicious update.
- **Posture visibility.** `mt doctor` shows world-writable or group-writable paths and unexpected ownership under `/opt/malt`. Thus, on a multi-user machine, you can quickly see the attack surface.

## Inside the binary

The malt binary is small because it contains only five subsystems and the code that connects them:

- **SQLite.** ACID writes, reverse-dependency queries, linker-conflict detection, and atomic rollback after a failed upgrade. The database stays correct after `kill -9` during a write.
- **Native post-install.** A step executor for the Homebrew declarative steps, and a Ruby-subset interpreter in Zig for the taps that still ship `post_install` blocks.
- **Mach-O patching with arm64 ad-hoc codesign.** malt changes `/opt/homebrew` to `MALT_PREFIX` and signs the result again. Thus, `dyld` loads the result on modern macOS.
- **Install lock.** `flock` on `db/malt.lock` and a symlink-tree walk. Each command that makes changes gets the lock. Thus, two concurrent commands, or an install that you stop with Ctrl-C, cannot corrupt the state.
- **`sandbox-exec` profile.** The opt-in `--use-system-ruby` path runs formula scripts in a deny-default sandbox, with the limits and escape filter described above.

All five subsystems run on each install. The warm install times in the [benchmarks](README.md#benchmarks) are their combined wall-clock cost.

The interactive dashboard (`mt tui`) is the only part that does not run on each install. It is compiled into the same binary and is not a separate tool. It adds only about 300 KB.
