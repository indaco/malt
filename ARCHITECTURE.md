# Architecture

How malt is built and what it guarantees. For installing and using malt, see the [README](README.md).

malt's behaviour follows from a small number of design choices - each one a direct consequence of wanting safe concurrency and interruption survival.

## Its own prefix

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

## Content-addressable store

Bottles are stored by their SHA256. The same bottle is never downloaded or extracted twice; multiple installed kegs reference the same store entry. Store entries are immutable - only `mt purge --store-orphans` removes them. Kegs in `Cellar/` are materialized via APFS `clonefile()`, which creates a copy-on-write clone at zero disk cost; non-APFS volumes fall back to a recursive copy.

This is what makes `mt rollback` an instant operation: every previously installed bottle is still in the store, so reverting is unlink → re-clone → DB update, with no re-download.

## Streaming download pipeline

Each bottle download is a single-pass pipeline:

```text
Network (HTTPS from GHCR CDN)
    ├──► SHA256 hasher (streaming - computed as chunks arrive)
    └──► gzip/zstd decompressor
            └──► tar extractor
                    └──► filesystem write to tmp/
```

No intermediate archive file is written to disk. The SHA256 is verified against the Homebrew API manifest immediately after the stream completes; on mismatch, the extracted directory is deleted before any commit happens.

## Mach-O patching

Homebrew bottles contain hardcoded `/opt/homebrew/Cellar/...` paths in Mach-O load commands. malt corrects them in four steps:

1. Parse headers with struct-aware parsing (not raw byte scanning).
2. Identify every relevant load command (`LC_ID_DYLIB`, `LC_LOAD_DYLIB`, `LC_RPATH`, etc.).
3. Rewrite paths in-place and pad the remaining space with null bytes.
4. On arm64, ad-hoc codesign the patched binary via `codesign --force --sign -`.

Text files (`.pc` configs, shell scripts) containing `@@HOMEBREW_PREFIX@@` or `@@HOMEBREW_CELLAR@@` placeholders are patched the same way. Patching always happens on the Cellar copy, never the store original - if it fails, the Cellar copy is deleted and the store entry stays pristine for retry.

## The post_install interpreter

When a formula defines `post_install`, malt tries its native interpreter first. It parses and evaluates the Ruby subset those blocks actually use:

- `Pathname` operations, `FileUtils`, `inreplace`, `Dir.glob`
- string interpolation, `%w[]` arrays, the boolean operators
- control flow: `if`/`unless`, `.each`/`.select`/`.map`
- `Formula["name"]` cross-lookup, `ENV` access

Source for `homebrew-core` formulas is fetched on demand from GitHub if the tap isn't cloned locally.

Homebrew v6 is migrating formulae from these Ruby blocks to a declarative `post_install_steps` array. malt runs those steps natively as well - across install, upgrade, and migrate - so packages keep configuring themselves as upstream converts.

Casks declare the same step schema as `preflight_steps` / `postflight_steps` / `uninstall_preflight_steps` / `uninstall_postflight_steps` (Homebrew v7). `mt install --cask` runs the preflight over the staged artefact before anything is placed and the postflight once the cask is recorded; `mt uninstall`, `mt upgrade` and `mt rollback` run the steps stored at install time, so they match the version on disk, and drop the symlinks a cask declared for removal. Cask steps are confined to the Caskroom, the malt prefix, `$HOME/Library` and the applications directory, and may never remove or relocate those roots, their top-level directories, or anything under `Keychains`, `Mail`, `Messages`, `Safari`, `Accounts`, `Mobile Documents` and `CloudStorage`; steps that need `sudo` are reported and skipped, never escalated. `terminate_process` and `delete_keychain_certificate` act on the user session as upstream defines them and are not confined. A failed uninstall preflight keeps the cask on disk; `mt uninstall --force` continues past it. `mt install --dry-run` lists the steps a cask would run and which ones malt refuses; `mt upgrade --dry-run` does not, and `mt uninstall --dry-run` stops before them.

Every mutating filesystem operation - write, rm, chmod, symlink - is validated against the formula's Cellar prefix and the malt prefix; paths containing `..` or resolving outside the sandbox via symlinks are rejected immediately.

When the interpreter hits an unsupported construct, the user is directed to `--use-system-ruby`, which delegates to a sandboxed Ruby subprocess scoped to the formula's cellar, with:

- a scrubbed environment
- `RLIMIT_CPU`/`AS`/`FSIZE` caps
- terminal escape sequences filtered from child output

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

## Atomic install protocol

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

## Safety and security

malt's correctness rests on a few load-bearing properties:

- **SHA256 verification.** Streaming hash computed during download, verified before extraction. No unverified data touches the store.
- **Tar entry pre-scan.** Every entry's name and symlink target are validated before any byte is written. The 512-byte tar header is checksum-verified per entry. Hardlinks are applied via `linkat(..., 0)`, which refuses to follow a symlink - so a hostile tarball cannot land a hardlink inside the keg via a symlink to `/etc/passwd`.
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
- **Boundary validation.** `MALT_PREFIX`, `MALT_CACHE`, launchd service declarations, install-script checksums, and HTTP redirects fail-closed on malformed or suspicious input - no silent HTTPS→HTTP downgrades, no `/bin/sh` in service argv, no `..` in prefix paths. A cask that declares no `sha256` is refused rather than treated as opted out; only an API cask's explicit `sha256 :no_check` skips verification. Tap and local `.rb` packages must pin a 64 lowercase-hex `sha256`; one that declares `sha256 :no_check` installs only with `--allow-unpinned`, with a warning, and never as a `.pkg`. A manifest URL must be `https://` unless a digest already pins the bytes it returns - so the handful of upstream packages still served over plaintext keep installing, while one that hash-verifies nothing is refused outright.
- **Trusted verifier.** `mt version update` refuses a `cosign` that resolves inside `/opt/malt`, which packages can write to. A shim dropped there cannot rubber-stamp a malicious update.
- **Posture visibility.** `mt doctor` flags world- or group-writable paths and unexpected ownership under `/opt/malt`, so multi-user machines see their attack surface at a glance.

## Inside the binary

malt's binary is small because it ships only five subsystems and the glue between them:

- **SQLite.** ACID writes, reverse-dependency queries, linker-conflict detection, atomic rollback after a failed upgrade. Survives `kill -9` mid-write.
- **Native `post_install` interpreter.** A Ruby-subset interpreter in Zig - only activates for the formulas (`node`, `openssl`, …) that won't configure without it.
- **Mach-O patching with arm64 ad-hoc codesign.** Rewrites `/opt/homebrew` → `MALT_PREFIX` and re-signs so `dyld` loads the result on modern macOS.
- **Install lock.** `flock` on `db/malt.lock` plus a symlink-tree walk, acquired by every mutating command, so two invocations - or a Ctrl-C'd install - can't corrupt state.
- **`sandbox-exec` profile.** The opt-in `--use-system-ruby` path runs formula scripts in a deny-default sandbox (caps and escape-filtering as above).

All five run per-install. The warm install times in the [benchmarks](README.md#benchmarks) are their combined wall-clock cost.

The interactive dashboard (`mt tui`) is the one piece that doesn't run per-install - it's compiled into the same binary instead of shipping as a companion tool, and costs only about 300 KB to keep there.
