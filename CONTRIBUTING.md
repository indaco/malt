# Contributing

malt is a Homebrew-compatible package manager written in Zig. This file tells you how to land a change and which invariants each patch must obey. If a change cannot obey an invariant, describe the trade-off in the PR. Do not relax the rule silently.

## How to contribute

For all changes larger than a typo or a one-line fix, **open an issue first**. A short discussion before the work prevents a long discussion in the PR review. If you are not sure that a change is trivial, open an issue.

**Branch names.** Use a [Conventional Commits](https://www.conventionalcommits.org/) prefix that matches the change: `feat/`, `fix/`, `refactor/`, `perf/`, `chore/`, `docs/`, `test/`. Do not use other prefixes such as `wip/` or `ui/`.

**Commit messages.** Use a Conventional Commits header (`type(scope): subject`). Keep the body short, and explain _why_, not _what_. The recent `git log` is the reference example. Match the style of `perf(install): short-circuit when keg already present` and `feat(cli/doctor): --fix for safe warning classes`.

**Pull requests.** malt squash-merges PRs into `main`. Thus, the squash subject is the `git log` entry. Write the PR title for that purpose: a Conventional Commits header of fewer than 70 characters. In the PR description, describe the user-visible behaviour change or the safety property that you added. Do not write a file-by-file changelog, because the diff shows that.

**Where PRs go.** Open all PRs against `main`, also bug fixes for the latest release. malt keeps a `release/X.Y` branch as the patch line for the current minor. The maintainer cherry-picks user-visible fixes from `main` to that branch. Do not target `release/*` branches directly. This makes the next minor a regression risk and skips the gate.

> [!NOTE]
> **AI-assisted contributions are welcome.** AI wrote malt with human direction. Thus, PRs written with Claude, Copilot, or similar tools are accepted. But you must read the diff, understand what the patch does, and accept it as your own work. Use the AI as a collaborator, not as a release valve. Give your agent [AGENTS.md](AGENTS.md). It contains the commands, invariants, and pre-PR checklist in a form that agents can act on.

## Out of scope

These boundaries are settled. Maintainers close PRs against them without a long discussion. If a constraint seems wrong, open an issue _before_ you write code.

- **Linux and Windows support.** malt is for macOS only, on purpose. Mach-O patching, APFS clonefile, launchd, sandbox-exec, and the Homebrew bottle ecosystem are all platform-specific. Maintainers do not merge cross-platform PRs.
- **Brewfile `do … end` blocks and Ruby conditionals (`if OS.mac?`).** The Brewfile parser is narrow on purpose. For complex setups, use `Maltfile.json`, which can express the full structure.
- **`post_install` constructs outside the documented Ruby subset.** The native interpreter supports a defined part of Ruby (refer to `src/core/dsl/`). Each additional construct makes the trust surface larger. The supported alternative is `--use-system-ruby`, which runs in the sandbox profile.
- **Mac App Store (`mas`) and VSCode (`vscode`) install support.** malt parses these directives, so existing `Brewfile`s round-trip correctly. But malt does not install Mac App Store apps or VSCode extensions, and there is no plan for it soon.

## Development environment

### Using Devbox (recommended)

[Devbox](https://www.jetify.com/devbox) pins all tools that this repository needs. Install it ([instructions](https://www.jetify.com/devbox/docs/installing_devbox/)). Then, from the repository root, run:

```bash
devbox install                                   # fetch pinned tools
devbox shell --pure                              # enter the isolated shell
```

`devbox.json` pins `zig@0.16`, `just`, `git`, `curl`, `shellcheck`, `shfmt`, and `sqlite`. These tools are sufficient to build, test, lint, and run all scripts under `scripts/`.

To see all build, test, lint, and bench targets, run `just --list`.

### Manual setup

If you do not want to use Devbox, install these tools:

- [Zig 0.16](https://ziglang.org/download/): the toolchain. Use 0.16, not `master`.
- [just](https://github.com/casey/just): the task runner for the `zig build`, lint, and bench targets.
- [shellcheck](https://www.shellcheck.net/) and [shfmt](https://github.com/mvdan/sh): necessary for the shell-script lint.
- `sqlite3`, `curl`, and `git`: standard tools, usually already on macOS.

## Before you submit

Run these commands locally before you open the PR. Most of them are fast.

```bash
zig build                                        # debug build
zig build test                                   # unit tests
./scripts/lint-spawn-invariants.sh               # argv-only lint
```

> [!IMPORTANT]
> If your change touches an item in [Security invariants](#security-invariants) below, also run `./scripts/smokes/smoke_security.sh` before you open the PR. These items are the sandbox, pins, plist validator, `install.sh`, `--use-system-ruby`, and argv-only spawn. The script takes ~10 seconds and needs no network. It is the single entry point that tests all protections end-to-end: flag scope, argv-only lint, pins-manifest shape, and the `install.sh` fail-closed suite. It finds regressions before they get to CI.

If your change touches `scripts/install.sh`, also run `./scripts/test/install_sh_test.sh`.

CI runs the full set of checks on each PR, including `local-bench.sh` and the smoke suites. A local run first only gives you faster feedback.

## Pointers before you start

- **`README.md`**: the public face of the project. Read [Why this, and what's different](README.md#why-this-and-whats-different). Thus, your design proposals do not contradict choices that other parts depend on.
- **`ARCHITECTURE.md`**: the design choices for the install protocol, the store, Mach-O patching, and the `post_install` interpreter. It also describes the safety and supply-chain model.

## Tap forges

Taps resolve against four forges: GitHub, GitLab (also self-hosted), Codeberg/Forgejo/Gitea, and Gogs. Gitea is a fork of Gogs. Gogs uses the Gitea API and `MALT_GITEA_TOKEN`, and only its pin endpoint is different. The README section [Custom sources](README.md#custom-sources) documents the user-facing matrix and the `mt tap --host` and `--url` registration forms. It also documents the token env var for each forge (`MALT_GITHUB_TOKEN`, `MALT_GITLAB_TOKEN`, `MALT_GITEA_TOKEN`). Read it before you change tap resolution.

Each forge is one arm of the enum `switch` in `src/core/forge.zig`. This file stays a pure leaf: no `cli/*` or `ui/*` imports, and no user-facing strings. A new forge is a new enum arm. Thus, the compiler flags each `switch` that does not handle it.

When you write a tap formula with a pinned `sha256`, use **release-asset** URLs. Do not use GitLab `/-/archive/` or Gitea/Gogs `/archive/` tarballs. The forge server can generate these archives again, so their digest can change after a forge upgrade, also when the contents stay the same. The result is a `Sha256Mismatch` that is not real corruption.

## Security invariants

### Argv-only spawn

malt starts each Zig-side subprocess through argv-style APIs: `fs_compat.Child.init(argv, allocator)`, which forwards to `std.process.spawn`. **No `sh -c <string>`, no `/bin/sh`, no shell interpolation.** The usual form is a static argv `[_][]const u8{ … }`. A shell command string at a spawn call site is a security regression.

- Enforcement: CI runs `scripts/lint-spawn-invariants.sh`.
- Local guard: `tests/spawn_invariant_test.zig` scans `src/` and fails `zig build test` on violations.
- Permitted exceptions: only the rejection list in `src/core/services/plist.zig` names `/bin/sh`-style paths. This file is the validator that _refuses_ them in formula-declared services.

### Ruby post_install sandbox

The `--use-system-ruby` path runs in a macOS `sandbox-exec` profile (refer to `src/core/sandbox/macos.zig`). The profile:

- denies network access
- denies writes outside the cellar of the formula and `MALT_PREFIX/{etc,var,share,opt}`
- removes all environment variables except `HOME`, a minimal `PATH`, `MALT_PREFIX`, and `TMPDIR`
- applies `RLIMIT_CPU`/`RLIMIT_AS`/`RLIMIT_FSIZE` to the child

The flag applies to one formula at a time. A bare `--use-system-ruby` works only when you install one package. `migrate` rejects it.

### Homebrew-core pin

malt checks downloaded formula Ruby source against `src/core/pins_manifest.txt`. It executes the source only if the SHA256 matches the pinned `homebrew-core` commit in `src/core/pins.zig`. No manifest entry means no execution. The pin is frozen. Upstream has migrated all Ruby `post_install` blocks to declarative `post_install_steps`, which malt runs natively. Thus, nobody regenerates the manifest now.

### Service declarations

Formula `service:` blocks go through `plist_mod.validate` before launchd sees them. The validator applies these rules:

- `program_args[0]` must be under the cellar of the formula or under `MALT_PREFIX/opt/<formula>`.
- An interpreter shebang (`/bin/sh` and others) cannot be the leading executable.
- The argv length and the length of each argument have limits.
- NUL bytes are rejected.

Some formulas ship their own launchd plist (a `service` block with only a `name`). `src/core/services/shipped_plist.zig` reads that file into the same `ServiceSpec`, which then goes through the same gate. The reader refuses by default. It has a launchd key allowlist and a limit of 64 KiB and depth 4. It accepts only the five entities that the writer emits. In addition to a `run` block, it supports one launchd feature: a `Sockets` entry of the `SecureSocketWithKey` shape, whose path launchd owns.

### Release signing

The goreleaser workflow signs releases keyless with cosign. `scripts/install.sh` verifies the signature again before the SHA check. It fails closed: no signature, no install. To skip this check, you must set `MALT_ALLOW_UNVERIFIED=1`. The `scripts/test/install_sh_test.sh` suite prevents regressions in the fail-closed paths.

## Build & test

```bash
zig build                                        # Debug binary
zig build -Doptimize=ReleaseSafe                 # release-equivalent binary
zig build universal                              # universal binary (arm64 + x86_64 via lipo)
zig build test                                   # unit tests
./scripts/lint-spawn-invariants.sh               # argv-only lint
./scripts/test/install_sh_test.sh                # install.sh regression
./scripts/local-bench.sh                         # full bench suite (slow)
./scripts/smokes/smoke_test.sh                   # CLI smoke coverage
./scripts/smokes/smoke_security.sh               # security-surface smoke
```

For the pre-PR subset, refer to [Before you submit](#before-you-submit).

## Coding conventions

Follow the idiomatic Zig patterns that are already in the file that you edit: explicit error sets, `defer` / `errdefer` for cleanup, `anytype` writers, and allocator threading instead of global state. Keep comments short. Explain _why_ you made a non-obvious choice. Do not repeat the code.

**Tests.** Put pure unit tests in inline `test` blocks next to the code that they test (in `src/*.zig`). Put cross-module integration tests in `tests/`. Each new behaviour (new flag, subcommand, or error path) needs a pinning test. "Obvious" is not an exception.

**Binary size and startup time.** malt is ~3 MB and starts in ~3 ms. Both numbers are part of the value of malt. If new code changes either number by a large amount, justify the cost in the PR description.

## License

malt uses the [MIT license](LICENSE). When you submit a contribution, you agree to license it under the same terms.
