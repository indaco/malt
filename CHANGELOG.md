# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The changelog is generated and managed by [sley](https://github.com/indaco/sley).

## v0.8.0 - 2026-04-20

### Highlights

The native DSL grows up, self-update becomes as trustworthy as the install script, and malt finally renders correctly on light terminals.

- **More of your toolchain installs end-to-end without touching Ruby.** v0.4.0 shipped the native interpreter; this release is the one where it actually covers the packages people install every day. `mt install zig` no longer trips a parse error on `llvm@21`. `openssl@3`, `gnupg`, `ca-certificates`, `libidn2` now run their post-install logic inline in Zig — the same work that used to require spawning a Ruby subprocess, with all the latency and ambient-trust cost that implied. And when a formula does reach for something the interpreter doesn't speak yet, you get a specific `--use-system-ruby=<name>` hint instead of a silent skip that pretended to succeed. "post_install completed" now means exactly that.
- **`mt version update` closes its own trust gap.** Every release is now verified with cosign keyless signatures over `checksums.txt` (pinned to the release workflow identity) and SHA256 against the verified manifest before a single byte lands on disk — the same posture `install.sh` has had since v0.6.0. The binary swap itself is rename-based and atomic with a `.old` rollback, so a mid-flight failure can no longer leave a half-written executable. And when malt was installed through Homebrew, the updater steps aside and points at `brew upgrade --cask malt` rather than quietly desyncing Homebrew's install receipts.
- **Light terminals render legibly.** A semantic palette spans four cells — dark vs. light × truecolor vs. basic — detected once at startup via OSC 11, with `COLORFGBG` and `MALT_THEME` fallbacks and every color pinned to WCAG AA contrast by unit test. Dark-terminal output is byte-identical to before; light-terminal users stop losing the `⚠` warn icon, the `--local` security warning, and `mt info` meta rows into the background.
- **The rough edges you would have hit otherwise.** Post-install no longer reads silent fallbacks as success, gains a `--debug` flag that prints every DSL diagnostic, and emits structured per-package `post_install` status under `--json`. The release smoke job can now tell "tag exists but the asset hasn't propagated yet" apart from "the release is missing", so cold-release lag stops tripping false alarms.

---

### 🚀 Enhancements

- **update:** defer self-update to brew for Homebrew-managed installs ([3879e10](https://github.com/indaco/malt/commit/3879e10)) ([#98](https://github.com/indaco/malt/pull/98))
- **update:** atomic rename-based binary swap with .old rollback ([b488d5e](https://github.com/indaco/malt/commit/b488d5e)) ([#97](https://github.com/indaco/malt/pull/97))
- **update:** verify releases with cosign + SHA256 before installing ([743196a](https://github.com/indaco/malt/commit/743196a)) ([#96](https://github.com/indaco/malt/pull/96))
- **update:** add SHA256 and cosign verification primitives ([0680186](https://github.com/indaco/malt/commit/0680186)) ([#95](https://github.com/indaco/malt/pull/95))
- **update:** classify install origin so self-update can respect brew ([6b873f9](https://github.com/indaco/malt/commit/6b873f9)) ([#93](https://github.com/indaco/malt/pull/93))
- **dsl:** module constants, Set.new, pkgetc + CI corpus + backlog dashboard ([fcc0620](https://github.com/indaco/malt/commit/fcc0620)) ([#92](https://github.com/indaco/malt/pull/92))
- **dsl:** comparison operators, .blank?, if-as-rvalue + corpus smoke ([82b3a04](https://github.com/indaco/malt/commit/82b3a04)) ([#91](https://github.com/indaco/malt/pull/91))
- **dsl:** shovel operator (<<) on Array and String ([1a2c7c4](https://github.com/indaco/malt/commit/1a2c7c4)) ([#90](https://github.com/indaco/malt/pull/90))
- **dsl:** Enumerable methods on hash receivers (.map/.each/.select/.reject) ([c7efb4d](https://github.com/indaco/malt/commit/c7efb4d)) ([#89](https://github.com/indaco/malt/pull/89))
- **dsl:** Version-style accessors on strings (.major/.minor/.patch/.to_i) ([6363afb](https://github.com/indaco/malt/commit/6363afb)) ([#88](https://github.com/indaco/malt/pull/88))
- **dsl:** def and return with sibling-helper extraction ([917e6f1](https://github.com/indaco/malt/commit/917e6f1)) ([#87](https://github.com/indaco/malt/pull/87))
- **ui:** semantic palette for light + dark terminals ([c0eb98f](https://github.com/indaco/malt/commit/c0eb98f)) ([#83](https://github.com/indaco/malt/pull/83))

### 🩹 Fixes

- **purge:** run unused-deps before store-orphans in housekeeping ([57f756b](https://github.com/indaco/malt/commit/57f756b)) ([#106](https://github.com/indaco/malt/pull/106))
- **github:** make bug report form label parse cleanly ([2777172](https://github.com/indaco/malt/commit/2777172)) ([#105](https://github.com/indaco/malt/pull/105))
- **ui:** light palette — meta info recedes, basic variants align ([2017220](https://github.com/indaco/malt/commit/2017220)) ([#102](https://github.com/indaco/malt/pull/102))
- **dsl:** harden post_install DSL — block-pass, ::, diagnostics ([4cc6d01](https://github.com/indaco/malt/commit/4cc6d01)) ([#86](https://github.com/indaco/malt/pull/86))
- **release:** widen smoke wait and distinguish lag from missing release ([9f3514e](https://github.com/indaco/malt/commit/9f3514e)) ([#81](https://github.com/indaco/malt/pull/81))

### 💅 Refactors

- **update:** extract release-asset selection into src/update/release.zig ([fdbf2b1](https://github.com/indaco/malt/commit/fdbf2b1)) ([#94](https://github.com/indaco/malt/pull/94))

### 📖 Documentation

- **readme:** use the qualified tap form in the brew-install hint ([e16a375](https://github.com/indaco/malt/commit/e16a375)) ([#101](https://github.com/indaco/malt/pull/101))
- **update:** document cosign verification, brew guard, and bypass asymmetry ([ca1435c](https://github.com/indaco/malt/commit/ca1435c)) ([#99](https://github.com/indaco/malt/pull/99))

### 🏡 Chores

- update coverage badge ([6685ce6](https://github.com/indaco/malt/commit/6685ce6)) ([#104](https://github.com/indaco/malt/pull/104))
- **github:** add issue forms and PR template ([5d03683](https://github.com/indaco/malt/commit/5d03683)) ([#103](https://github.com/indaco/malt/pull/103))
- **update:** tighten idioms, fill test gaps, add --cleanup ([4b2612e](https://github.com/indaco/malt/commit/4b2612e)) ([#100](https://github.com/indaco/malt/pull/100))

### 🤖 CI

- **release:** trigger the release workflow on tag push ([4a0ee06](https://github.com/indaco/malt/commit/4a0ee06)) ([#82](https://github.com/indaco/malt/pull/82))

### Other

- update benchmark results 2026-04-20 ([fa7db3a](https://github.com/indaco/malt/commit/fa7db3a))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.7.0 - 2026-04-18

### 🚀 Enhancements

- **install:** install formulas from a local .rb file ([6d66d1e](https://github.com/indaco/malt/commit/6d66d1e)) ([#78](https://github.com/indaco/malt/pull/78))

### 🩹 Fixes

- **cask:** hash multi-chunk downloads correctly ([524c52d](https://github.com/indaco/malt/commit/524c52d)) ([#80](https://github.com/indaco/malt/pull/80))
- **install:** install revisioned formulas at versioned_revision dir ([e05f041](https://github.com/indaco/malt/commit/e05f041)) ([#79](https://github.com/indaco/malt/pull/79))
- **install:** widen API retry budget for cold-release propagation ([635c801](https://github.com/indaco/malt/commit/635c801)) ([#76](https://github.com/indaco/malt/pull/76))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.6.2 - 2026-04-18

### 🩹 Fixes

- **install:** restore source-fallback after API failure ([0526027](https://github.com/indaco/malt/commit/0526027)) ([#75](https://github.com/indaco/malt/pull/75))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.6.1 - 2026-04-18

### Highlights

This release is the follow-through on v0.6's security pass: the fail-closed gates it
introduced were correctly wired, but silently empty in practice. Plus a rough edge in the install UX.

- **`post_install` actually runs for the packages that need it.** The allowlist that authorizes malt to execute a formula's Ruby `post_install` shipped empty in v0.6, so side effects like `ca-certificates` rebuilding the cert bundle, `openssl@3` wiring its cert store, or `node` configuring npm were silently skipped on every install. `scripts/gen-pins.sh` now enumerates every formula in homebrew-core with `post_install_defined` straight from the Homebrew API, and a parallel hashing bug that made every entry mismatch at runtime is fixed. A monthly CI workflow opens an auto-PR to refresh the pin, and a drift guard on every PR fails if the manifest falls out of sync. "Fail-closed" now means something.
- **Tap installs feel like everything else.** `malt install user/tap/formula` used to sit silent until the archive landed - no progress bar, no feedback. It now streams through the same progress renderer as formula bottles and cask DMGs.

---

### 🩹 Fixes

- **pins:** authorize post_install for common TLS + language formulas ([1acbaba](https://github.com/indaco/malt/commit/1acbaba)) ([#70](https://github.com/indaco/malt/pull/70))
- **install:** show progress bar for tap installs ([645c74b](https://github.com/indaco/malt/commit/645c74b)) ([#69](https://github.com/indaco/malt/pull/69))

### ✅ Tests

- **release:** smoke the live release install end-to-end ([116f817](https://github.com/indaco/malt/commit/116f817)) ([#68](https://github.com/indaco/malt/pull/68))

### 🤖 CI

- **release:** disable zig-cache so poisoned entries can't block a release ([54192e0](https://github.com/indaco/malt/commit/54192e0)) ([#72](https://github.com/indaco/malt/pull/72))
- **release:** run the live-install smoke in-sequence, not on a parallel trigger ([65922e0](https://github.com/indaco/malt/commit/65922e0)) ([#71](https://github.com/indaco/malt/pull/71))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.6.0 - 2026-04-17

### Highlights

This release is a security pass. Every path from curl … | bash through malt install has been tightened against a concrete threat.

- **Release signing closes the install-path trust gap.** Every GitHub release is now signed keyless via cosign/Sigstore, and install.sh verifies the signature against the signing workflow's identity before it trusts the checksum. The build-from-source fallback clones at a tagged release instead of whatever main happens to point at. Together these close the last "just trust whatever HTTPS returned" step on the install path - a compromised GitHub token is no longer enough to ship a malicious malt binary.
- **post_install runs in a real sandbox.** The --use-system-ruby path - previously a full Ruby interpreter running with your UID and no containment - now runs inside a sandbox-exec profile confined to the formula's own cellar, with a scrubbed environment, resource limits, and terminal escape sequences filtered before they hit your scrollback. A hostile formula's blast radius shrinks from "your home directory" to "its own install prefix." The flag is also per-formula now, so one package's post_install failing can't silently widen the trust boundary for the rest of an install batch.
- **Third-party formula sources are pinned.** Ruby formulas from homebrew-core are SHA256-verified against an embedded manifest at a specific pinned commit. Third-party taps (malt tap user/repo) pin their HEAD commit at tap time; advancing the pin is an explicit `malt tap --refresh`. A force-pushed tap or a rewritten branch cannot swap a formula's bottle URL out from under malt.
- **Boundary validation, everywhere.** `MALT_PREFIX`, launchd service definitions, the install script's checksum paths, and the HTTP client's redirect chain all fail-closed on malformed or suspicious input. Malformed prefixes exit with a clear error; hostile service blocks can't launch /bin/sh at login; HTTPS requests can't be silently downgraded to plaintext mid-chain.
- **Posture visibility in malt doctor.** Weak permissions on `/opt/malt` - world-writable files, group-writable directories, paths owned by an unexpected user - now show up as warnings with a count and a short list. Multi-user machines can see their attack surface at a glance.
- **Lock-in for what was already clean.** The argv-only spawn convention (no `sh -c` anywhere in the codebase) and the install script's fail-closed checksum behavior are now covered by regression tests and CI gates, so neither can quietly drift.

---

### 🚀 Enhancements

- **security:** pin third-party taps to a commit SHA ([a02a2aa](https://github.com/indaco/malt/commit/a02a2aa)) ([#64](https://github.com/indaco/malt/pull/64))
- **security:** audit /opt/malt permissions in malt doctor ([0386e02](https://github.com/indaco/malt/commit/0386e02)) ([#63](https://github.com/indaco/malt/pull/63))
- **security:** filter terminal escapes from ruby post_install output ([c162bdf](https://github.com/indaco/malt/commit/c162bdf)) ([#62](https://github.com/indaco/malt/pull/62))
- **security:** refuse https → http redirect downgrades ([e4a6250](https://github.com/indaco/malt/commit/e4a6250)) ([#61](https://github.com/indaco/malt/pull/61))
- **security:** pin install.sh source fallback to a release tag ([cc5f697](https://github.com/indaco/malt/commit/cc5f697)) ([#60](https://github.com/indaco/malt/pull/60))
- **security:** validate MALT_PREFIX at the env boundary ([ba6c786](https://github.com/indaco/malt/commit/ba6c786)) ([#59](https://github.com/indaco/malt/pull/59))
- **security:** harden post-install pipeline and service declarations ([b9be902](https://github.com/indaco/malt/commit/b9be902)) ([#58](https://github.com/indaco/malt/pull/58))

### 🩹 Fixes

- **doctor:** match the rest of malt's UI palette ([de612d4](https://github.com/indaco/malt/commit/de612d4)) ([#66](https://github.com/indaco/malt/pull/66))

### 📖 Documentation

- **readme:** document the new security surface ([83ed26a](https://github.com/indaco/malt/commit/83ed26a)) ([#65](https://github.com/indaco/malt/pull/65))

### 🏡 Chores

- normalize scripts and lint on pre push hook ([675f94b](https://github.com/indaco/malt/commit/675f94b)) ([#56](https://github.com/indaco/malt/pull/56))

### 🤖 CI

- **release:** run goreleaser before publishing release notes ([cb3bde5](https://github.com/indaco/malt/commit/cb3bde5)) ([#67](https://github.com/indaco/malt/pull/67))
- **release:** sign artifacts with cosign keyless ([387aedc](https://github.com/indaco/malt/commit/387aedc)) ([#57](https://github.com/indaco/malt/pull/57))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.5.1 - 2026-04-16

### 🩹 Fixes

- **cli:** make --version and --help/-h dispatch as commands ([f56a965](https://github.com/indaco/malt/commit/f56a965)) ([#55](https://github.com/indaco/malt/pull/55))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.5.0 - 2026-04-16

### 🚀 Enhancements

- **upgrade:** dim already-at-latest lines so real work pops ([883a9cf](https://github.com/indaco/malt/commit/883a9cf)) ([#48](https://github.com/indaco/malt/pull/48))

### 🩹 Fixes

- **install:** collapse keg-only "not linking" line into ✓ suffix ([10ba32e](https://github.com/indaco/malt/commit/10ba32e)) ([#53](https://github.com/indaco/malt/pull/53))
- **install:** verify checksum, support env prefix override ([e42bede](https://github.com/indaco/malt/commit/e42bede)) ([#51](https://github.com/indaco/malt/pull/51))
- **upgrade:** skip "Upgrading…" line when dry-running ([f80f9d1](https://github.com/indaco/malt/commit/f80f9d1)) ([#49](https://github.com/indaco/malt/pull/49))
- **tests:** run zig build test without deadlocking ([6f8b49b](https://github.com/indaco/malt/commit/6f8b49b)) ([#47](https://github.com/indaco/malt/pull/47))
- **install:** heal dep opt/ symlinks so bottled binaries keep loading ([95ce71d](https://github.com/indaco/malt/commit/95ce71d)) ([#46](https://github.com/indaco/malt/pull/46))

### 📖 Documentation

- **readme:** add version badge ([ec90dee](https://github.com/indaco/malt/commit/ec90dee))
- add polished-output bullet and extend demo with info ([fe89ee3](https://github.com/indaco/malt/commit/fe89ee3)) ([#52](https://github.com/indaco/malt/pull/52))

### 🏡 Chores

- update coverage badge ([c2e4813](https://github.com/indaco/malt/commit/c2e4813))
- **bench:** drop bru from benchmark comparison ([8c001ed](https://github.com/indaco/malt/commit/8c001ed)) ([#50](https://github.com/indaco/malt/pull/50))
- **info:** cleaner output with bold header and aligned dim keys ([1d203dd](https://github.com/indaco/malt/commit/1d203dd)) ([#45](https://github.com/indaco/malt/pull/45))
- migrate to Zig 0.16 with faster installs and a smaller release binary ([d9bb663](https://github.com/indaco/malt/commit/d9bb663)) ([#44](https://github.com/indaco/malt/pull/44))

### 🤖 CI

- **bench:** make benchmark numbers fair and noise-visible ([6aae849](https://github.com/indaco/malt/commit/6aae849)) ([#54](https://github.com/indaco/malt/pull/54))

### Other

- update benchmark results 2026-04-16 ([7bd11be](https://github.com/indaco/malt/commit/7bd11be))
- update benchmark results 2026-04-16 ([12bad7e](https://github.com/indaco/malt/commit/12bad7e))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.4.1 - 2026-04-15

### 🩹 Fixes

- **cli:** exit non-zero on every user-facing failure ([e7993d6](https://github.com/indaco/malt/commit/e7993d6)) ([#41](https://github.com/indaco/malt/pull/41))
- **json:** escape strings in --json output ([0a1f0d6](https://github.com/indaco/malt/commit/0a1f0d6)) ([#40](https://github.com/indaco/malt/pull/40))
- **help:** send --help output to stdout ([3b336ae](https://github.com/indaco/malt/commit/3b336ae)) ([#38](https://github.com/indaco/malt/pull/38))
- **rollback:** exit non-zero on failure ([568763c](https://github.com/indaco/malt/commit/568763c)) ([#37](https://github.com/indaco/malt/pull/37))

### 💅 Refactors

- **cli:** drop redundant flag re-parsing ([f00d9a1](https://github.com/indaco/malt/commit/f00d9a1)) ([#42](https://github.com/indaco/malt/pull/42))

### 📖 Documentation

- **readme:** note --casks / --formulae plural aliases ([25c0c9e](https://github.com/indaco/malt/commit/25c0c9e)) ([#43](https://github.com/indaco/malt/pull/43))

### 🤖 CI

- bypass zig test-runner deadlock by running test binaries directly ([18733e8](https://github.com/indaco/malt/commit/18733e8)) ([#39](https://github.com/indaco/malt/pull/39))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.4.0 - 2026-04-15

### Highlights

- **Native Zig interpreter for Homebrew `post_install`.** The defining change in this release. Most Homebrew-compatible clients either skip `post_install` entirely or shell out to Ruby. malt now runs those blocks inline in Zig, so packages like `node`, `openssl`, `fontconfig`, and `docbook` arrive fully configured — no Ruby subprocess, no "install succeeded but nothing works" surprises. When a block uses a construct outside the interpreter's vocabulary, `--use-system-ruby` falls through to whatever Ruby is already on the box; no hard dependency.
- **Discovery catches up to brew.** `mt search` now returns every formula and cask whose name contains the query (not just exact matches). `mt info` shows full Homebrew metadata for packages that aren't installed locally, and both work on a completely fresh machine. New `mt uses <formula>` answers "what depends on this?" with an optional `--recursive` mode for the full transitive closure.
- **Two install paths that used to silently fail now work.** User taps can ship `.zip` archives — HashiCorp's lineup (terraform, consul, vault) and anything following the same release shape. Inline `user/tap/formula` installs route correctly, and `mt untap` actually untaps.
- **Homebrew parity for a real workflow.** `mt services` manages long-running launchd services (start / stop / status / logs). `mt bundle` installs and exports Brewfile / Maltfile.json sets.
- **Self-update, finally.** `mt version update` was broken end-to-end since the first release: the asset matcher missed every GoReleaser tarball, a shared stack buffer turned the on-disk copy into a no-op, and the binary layout inside the archive didn't match the code's expectations. All three are fixed, with tests. Every distribution path (script, Homebrew, release tarball, `zig build`) now ships both `malt` and `mt`.
- **Housekeeping, hardened.** `mt purge` replaces the scattered `cleanup` / `gc` / `autoremove` commands with a single scope-gated command. Mach-O parsing is overflow-safe. The Zig codebase received a hardening pass across allocators, error paths, and arg handling.

### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **uses:** reverse-dependency query command ([83171e6](https://github.com/indaco/malt/commit/83171e6)) ([#34](https://github.com/indaco/malt/pull/34))
- **install:** support .zip archives for tap formulae ([5adc5ba](https://github.com/indaco/malt/commit/5adc5ba)) ([#32](https://github.com/indaco/malt/pull/32))
- **search:** match brew's substring behavior ([cf4b51f](https://github.com/indaco/malt/commit/cf4b51f)) ([#29](https://github.com/indaco/malt/pull/29))
- add `mt services` and `mt bundle` (Homebrew parity) ([5601d5c](https://github.com/indaco/malt/commit/5601d5c)) ([#20](https://github.com/indaco/malt/pull/20))
- **dsl:** native Zig interpreter for post_install blocks ([c86a8d7](https://github.com/indaco/malt/commit/c86a8d7)) ([#19](https://github.com/indaco/malt/pull/19))
- **install:** --use-system-ruby post_install stopgap ([7ebb542](https://github.com/indaco/malt/commit/7ebb542)) ([#18](https://github.com/indaco/malt/pull/18))

### 🩹 Fixes

- **version-update:** make self-update actually replace the binary ([9254b57](https://github.com/indaco/malt/commit/9254b57)) ([#35](https://github.com/indaco/malt/pull/35))
- **info:** brew-style output on fresh machines ([d1d379b](https://github.com/indaco/malt/commit/d1d379b))
- mt install user/tap/formula + untap ([e194971](https://github.com/indaco/malt/commit/e194971)) ([#28](https://github.com/indaco/malt/pull/28))
- **core:** overflow-safe Mach-O parsing + system tar extraction ([96567bf](https://github.com/indaco/malt/commit/96567bf)) ([#17](https://github.com/indaco/malt/pull/17))

### 💅 Refactors

- dedupe list --json emission ([5ceebd8](https://github.com/indaco/malt/commit/5ceebd8)) ([#27](https://github.com/indaco/malt/pull/27))
- zig hardening pass ([cb468a0](https://github.com/indaco/malt/commit/cb468a0)) ([#25](https://github.com/indaco/malt/pull/25))
- unify housekeeping commands under `mt purge` ([559dab6](https://github.com/indaco/malt/commit/559dab6)) ([#21](https://github.com/indaco/malt/pull/21))

### 📖 Documentation

- document bru cache caveat via Methodology callout ([3caece9](https://github.com/indaco/malt/commit/3caece9)) ([#36](https://github.com/indaco/malt/pull/36))
- correct cold start timing in README ([b6414cb](https://github.com/indaco/malt/commit/b6414cb)) ([#33](https://github.com/indaco/malt/pull/33))
- tighten README and normalize binary size units ([5bcee31](https://github.com/indaco/malt/commit/5bcee31)) ([#24](https://github.com/indaco/malt/pull/24))
- **justfile:** clarify bench env var usage ([44035a9](https://github.com/indaco/malt/commit/44035a9))

### 🏡 Chores

- update .gitignore ([ab4e340](https://github.com/indaco/malt/commit/ab4e340))

### 🤖 CI

- drop unused binary artifact upload ([50288e4](https://github.com/indaco/malt/commit/50288e4)) ([#31](https://github.com/indaco/malt/pull/31))
- **benchmark:** only commit README updates when running on main ([69aa746](https://github.com/indaco/malt/commit/69aa746)) ([#26](https://github.com/indaco/malt/pull/26))
- run only on zig source changes ([9e33f36](https://github.com/indaco/malt/commit/9e33f36))

### Other

- update benchmark results 2026-04-14 ([a578f69](https://github.com/indaco/malt/commit/a578f69))
- update benchmark results 2026-04-13 ([fffa8bf](https://github.com/indaco/malt/commit/fffa8bf))
- update benchmark results 2026-04-13 ([368680e](https://github.com/indaco/malt/commit/368680e))
- update benchmark results 2026-04-12 ([17d48e3](https://github.com/indaco/malt/commit/17d48e3))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.3.1 - 2026-04-12

### 🩹 Fixes

- **core/deps:** free orphaned dep strings in resolve BFS ([8c137d2](https://github.com/indaco/malt/commit/8c137d2)) ([#15](https://github.com/indaco/malt/pull/15))

### 📖 Documentation

- **readme:** fix callouts types ([00e8664](https://github.com/indaco/malt/commit/00e8664))
- **readme:** use INFO callouts on the benchmark section ([f7bbb69](https://github.com/indaco/malt/commit/f7bbb69))
- **readme:** fix typos in github callouts types ([e7209f0](https://github.com/indaco/malt/commit/e7209f0))

### ✅ Tests

- raise code coverage ([6d6e4e3](https://github.com/indaco/malt/commit/6d6e4e3)) ([#16](https://github.com/indaco/malt/pull/16))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.3.0 - 2026-04-11

### 🚀 Enhancements

- **cli:** add `mt purge` to wipe a malt installation ([a70ccae](https://github.com/indaco/malt/commit/a70ccae)) ([#10](https://github.com/indaco/malt/pull/10))
- **cli:** add backup and restore commands ([16ac579](https://github.com/indaco/malt/commit/16ac579)) ([#7](https://github.com/indaco/malt/pull/7))
- **cli:** add `completions` command for bash, zsh, and fish ([6393b06](https://github.com/indaco/malt/commit/6393b06)) ([#5](https://github.com/indaco/malt/pull/5))
- **install:** download progress bars and materialize spinner ([9a265ad](https://github.com/indaco/malt/commit/9a265ad)) ([#4](https://github.com/indaco/malt/pull/4))

### 🩹 Fixes

- multi-package install correctness sweep ([ea64fc4](https://github.com/indaco/malt/commit/ea64fc4)) ([#11](https://github.com/indaco/malt/pull/11))
- **cli:** honour global --dry-run flag in subcommands ([75da6a6](https://github.com/indaco/malt/commit/75da6a6)) ([#6](https://github.com/indaco/malt/pull/6))

### 📖 Documentation

- **readme:** add demo gif and recording tape ([ab8176e](https://github.com/indaco/malt/commit/ab8176e))
- **readme:** added mt backup and mt restore sections ([fcef76b](https://github.com/indaco/malt/commit/fcef76b)) ([#9](https://github.com/indaco/malt/pull/9))

### ⚡ Performance

- faster warm installs, cleaner install pipeline ([06962ec](https://github.com/indaco/malt/commit/06962ec)) ([#13](https://github.com/indaco/malt/pull/13))

### 🎨 Styling

- **readme:** reformat benchmark tables ([24dc7b2](https://github.com/indaco/malt/commit/24dc7b2))

### 🏡 Chores

- add code coverage tooling (kcov + Codecov) ([f7721f9](https://github.com/indaco/malt/commit/f7721f9)) ([#12](https://github.com/indaco/malt/pull/12))
- **justfile:** add `install` recipe delegating to scripts/install.sh ([4d1fc81](https://github.com/indaco/malt/commit/4d1fc81))
- **devbox:** reuse justfile recipes in shell scripts ([64c1b9d](https://github.com/indaco/malt/commit/64c1b9d)) ([#8](https://github.com/indaco/malt/pull/8))

### Other

- update benchmark results 2026-04-11 ([d78c146](https://github.com/indaco/malt/commit/d78c146))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.2.1 - 2026-04-09

### 🩹 Fixes

- **cellar:** always substitute @@HOMEBREW\_\*@@ placeholders in text files ([bbc4cc1](https://github.com/indaco/malt/commit/bbc4cc1)) ([#3](https://github.com/indaco/malt/pull/3))
- **cellar:** resolve nested directory in keg after bottle extraction ([47426a2](https://github.com/indaco/malt/commit/47426a2)) ([#2](https://github.com/indaco/malt/pull/2))

**Full Changelog:** [v0.2.0...v0.2.1](https://github.com/indaco/malt/compare/v0.2.0...v0.2.1)

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.2.0 - 2026-04-09

### 🚀 Enhancements

- cask command parity for info, outdated, cleanup ([64cac0c](https://github.com/indaco/malt/commit/64cac0c)) ([#1](https://github.com/indaco/malt/pull/1))

### Other

- update benchmark results 2026-04-09 ([71ef557](https://github.com/indaco/malt/commit/71ef557))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.1.1 - 2026-04-09

### 🩹 Fixes

- **search:** consistent TUI output and working JSON mode ([1b3daaf](https://github.com/indaco/malt/commit/1b3daaf))
- **net:** use streamRemaining for HTTP body reads ([cbab4bc](https://github.com/indaco/malt/commit/cbab4bc))

### 🤖 CI

- replace deprecated archives.format with archives.formats in goreleaser config ([8ad73e0](https://github.com/indaco/malt/commit/8ad73e0))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.1.0 - 2026-04-09

### 🏡 Chores

- Initial Release

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
