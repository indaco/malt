# Contributing

malt is a Homebrew-compatible package manager written in Zig. These notes capture how to land a change and the invariants every patch is expected to honour. If a change can't satisfy one of those invariants, raise the trade-off in the PR rather than silently relaxing the rule.

## How to contribute

For anything beyond a typo or a one-line fix, **open an issue first**. A short conversation up front saves a long conversation in PR review. If you're not sure whether a change is non-trivial, opening an issue is always the safer call.

**Branch naming.** Use a [Conventional Commits](https://www.conventionalcommits.org/) prefix that matches the change: `feat/`, `fix/`, `refactor/`, `perf/`, `chore/`, `docs/`, `test/`. Avoid ad-hoc prefixes like `wip/` or `ui/`.

**Commit messages.** Conventional Commits header (`type(scope): subject`); body terse and focused on _why_, not _what_. The recent `git log` is the canonical example - match the style of `perf(install): short-circuit when keg already present` and `feat(cli/doctor): --fix for safe warning classes`.

**Pull requests.** PRs are squash-merged into `main`, so the squash subject is what shows up in `git log` - write the PR title with that in mind (Conventional Commits header, under 70 chars). The PR description should focus on the user-visible behaviour change or the safety property added; avoid file-by-file changelogs (the diff already shows that).

**Where PRs go.** Open every PR against `main`, including bug fixes against the latest release. malt maintains a `release/X.Y` branch as the patch line for the current minor; the maintainer cherry-picks user-visible fixes from `main` onto it. Don't target `release/*` branches directly - it makes the next minor a regression risk and bypasses the gate.

> [!NOTE]
> **AI-assisted contributions are welcome.** malt itself is human-directed AI implementation, so PRs written with Claude, Copilot, or similar tools are fine - provided you've read the diff, understand what the patch does, and stand behind it as your own work. Treat the AI as a collaborator, not a release valve.

## Out of scope

These are repeatedly-stated boundaries; PRs against them will be closed without a long discussion. If the constraint feels wrong, open an issue _before_ writing code.

- **Linux and Windows support.** macOS-only is a deliberate constraint - Mach-O patching, APFS clonefile, launchd, sandbox-exec, and the Homebrew bottle ecosystem are all platform-specific. Cross-platform PRs will not be merged.
- **Brewfile `do … end` blocks and Ruby conditionals (`if OS.mac?`).** The Brewfile parser is intentionally narrow. The escape hatch for power users is `Maltfile.json`, which has full structural expressiveness.
- **`post_install` constructs outside the documented Ruby subset.** The native interpreter covers a defined slice of Ruby (see `src/core/dsl/`). Adding ad-hoc constructs case-by-case grows the trust surface; the supported escape hatch is `--use-system-ruby`, which runs in the sandbox profile.
- **Mac App Store (`mas`) and VSCode (`vscode`) install support.** Those directives parse so existing `Brewfile`s round-trip cleanly, but malt does not install Mac App Store apps or VSCode extensions and has no near-term plan to.

## Before you submit

Run these locally before opening the PR. Most are fast.

```bash
zig build                                        # debug build
zig build test                                   # unit tests
./scripts/lint-spawn-invariants.sh               # argv-only lint
```

> [!IMPORTANT]
> If your change touches anything in [Security invariants](#security-invariants) below - sandbox, pins, plist validator, `install.sh`, `--use-system-ruby`, or argv-only spawn - also run `./scripts/smokes/smoke_security.sh` (~10 seconds, fully offline) before opening the PR. This is the single entry point that exercises every protection end-to-end - flag scoping, argv-only lint, pins-manifest shape, `install.sh` fail-closed suite - and it's the gate that catches regressions before they reach CI.

If your change touches `scripts/install.sh` specifically, also run `./scripts/test/install_sh_test.sh`.

The CI pipeline runs the full slate (including `local-bench.sh` and the smoke suites) on every PR; running locally first just shortens the feedback loop.

## Pointers before you start

- **`README.md`** - the public face of the project. Read `## Why malt exists` and `## Architecture` so your design proposals don't contradict choices that are already load-bearing.
- **`docs/`** - design notes, security audits, and the post_install DSL coverage doc live here. Skim the file most relevant to your change.
- **`docs/plan/` and `docs/design/`** - ADRs and longer design write-ups. If you're proposing something architectural, check whether there's already an ADR on the topic.

## Security invariants

### Argv-only spawn

Every Zig-side subprocess is spawned through argv-style APIs - `fs_compat.Child.init(argv, allocator)` (which forwards to `std.process.spawn`). **No `sh -c <string>`, no `/bin/sh`, no shell interpolation.** Building argv as a static `[_][]const u8{ … }` is the norm; anything that looks like a shell command string in a spawn call site is a security regression.

- Enforcement: `scripts/lint-spawn-invariants.sh` runs in CI.
- Local guard: `tests/spawn_invariant_test.zig` walks `src/` and fails `zig build test` on violations.
- Legitimate exceptions: only the rejection list in `src/core/services/plist.zig` names `/bin/sh`-style paths, because it's the validator that _refuses_ them in formula-declared services.

### Ruby post_install sandbox

The `--use-system-ruby` path runs in a macOS `sandbox-exec` profile that denies network, denies writes outside the formula's cellar and `MALT_PREFIX/{etc,var,share,opt}`, strips the environment down to `HOME`, a minimal `PATH`, `MALT_PREFIX`, and `TMPDIR`, and applies `RLIMIT_CPU`/`RLIMIT_AS`/`RLIMIT_FSIZE` to the child. See `src/core/sandbox/macos.zig`. The flag is per-formula - a bare `--use-system-ruby` only works when a single package is being installed, and is rejected outright on `migrate`.

### Homebrew-core pin

Formula Ruby source fetched over the wire is checked against `src/core/pins_manifest.txt` and executed only if the SHA256 matches the pinned `homebrew-core` commit in `src/core/pins.zig`. No manifest entry = no execution. Regenerate both with `scripts/gen-pins.sh` when bumping the pin.

### Service declarations

Formula `service:` blocks flow through `plist_mod.validate` before launchd ever sees them: `program_args[0]` must live under the formula's own cellar or `MALT_PREFIX/opt/<formula>`, interpreter shebangs (`/bin/sh` etc.) are refused as the leading executable, argv length / per-arg length are capped, and NUL bytes are rejected.

### Release signing

Releases are signed keyless via cosign in the goreleaser workflow; `scripts/install.sh` re-verifies the signature before the SHA check. Fail-closed: no signature, no install (bypass requires explicit `MALT_ALLOW_UNVERIFIED=1`). The `scripts/test/install_sh_test.sh` suite locks the fail-closed paths against regression.

## Build & test

```bash
zig build                                        # Debug binary
zig build -Doptimize=ReleaseSafe                 # release-equivalent binary
zig build test                                   # unit tests
./scripts/lint-spawn-invariants.sh               # argv-only lint
./scripts/test/install_sh_test.sh                # install.sh regression
./scripts/local-bench.sh                         # full bench suite (slow)
./scripts/smokes/smoke_test.sh                   # CLI smoke coverage
./scripts/smokes/smoke_security.sh               # security-surface smoke
```

For the pre-PR subset, see [Before you submit](#before-you-submit).

## Coding conventions

Follow the idiomatic-Zig patterns already present in the file you're editing: explicit error sets, `defer` / `errdefer` for cleanup, `anytype` writers, allocator threading over global state. Keep comments short and focused on _why_ a non-obvious choice was made - don't restate the code.

**Tests.** Inline `test` blocks colocated with the code they exercise (in `src/*.zig`) for pure unit tests; cross-module integration tests live in `tests/`. New behaviour - every new flag, subcommand, or error path - lands with a pinning test. "Obvious" is not an exception.

**Binary size and startup time.** malt is ~3 MB and starts in ~3 ms; both numbers are part of the value proposition. New code that materially moves either should justify the cost in the PR description.

## License

malt is [MIT-licensed](LICENSE). By submitting a contribution, you agree that it is licensed under the same terms.
