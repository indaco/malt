# AGENTS.md

Instructions for AI coding agents that work in this repository. Human readers: start
with [CONTRIBUTING.md](CONTRIBUTING.md). It explains the _why_ of all the rules below.
This file is the executable subset: exact commands, hard invariants, and the rules that
agents most frequently get wrong. The [pre-PR checklist](#before-you-open-the-pr) at the
end is the short form.

AI-assisted PRs are welcome. The contributor is responsible for the diff: read it,
understand it, and accept it as your own work.

## Project shape

malt is a Homebrew-compatible package manager written in **Zig 0.16**, for **macOS
only**. It is ~4 MB and starts in ~3 ms. The install benchmarks in `README.md` are the
published baseline. These numbers are the product, not trivia. If a change makes the
binary larger or moves the benchmarks, give the reason in the PR, with the numbers
before and after. Compare each new dependency against these numbers.

Do not port to Linux or Windows. Mach-O patching, APFS clonefile, launchd,
`sandbox-exec`, and the bottle ecosystem are all platform-specific. The macOS-only
constraint is deliberate.

## Verify before proposing a diff

```bash
just fmt                              # zig fmt + shfmt on shell scripts
just test                             # unit tests + cheap static regression guards
./scripts/lint-spawn-invariants.sh    # argv-only spawn lint
```

`just test` runs `zig build test` and adds the static guards. Use it instead of
`zig build test`. To see all available targets, run `just --list`.

All existing tests must pass. If a test fails, fix it or report it. This also applies to
a test that looks flaky or not related to your change. Do not describe a red suite as
green.

If tests fail with a GitHub API rate-limit error, they have no authentication. They are
not broken. Export a token and run them again before you make a conclusion:

```bash
export MALT_GITHUB_TOKEN="$(gh auth token)"
```

Also, run or update these items for the parts that the diff touches:

| Diff touches                                                                        | Also run or update                                                                              |
| ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| sandbox, pins, plist validator, `install.sh`, `--use-system-ruby`, spawn call sites | `./scripts/smokes/smoke_security.sh` (~10 s, offline)                                           |
| `scripts/install.sh`                                                                | `./scripts/test/install_sh_test.sh`                                                             |
| any help text or CLI surface                                                        | `just man-gen`, then commit `man/malt.1`                                                        |
| a new or changed CLI flag                                                           | `src/cli/help.zig` and all three shells in `src/cli/completions.zig`                            |
| a new environment variable                                                          | the _Environment variables_ table in `README.md`                                                |
| anything in `scripts/**`                                                            | `shellcheck` and `shfmt -i 2` on the changed scripts                                            |
| install / extract / download paths                                                  | `just regressions` (needs network and a token)                                                  |
| behaviour an existing script already covers                                         | that script under `scripts/e2e/`, `scripts/smokes/`, `scripts/test/`, or `scripts/regressions/` |
| install, parse, network, or concurrency paths                                       | `./scripts/bench.sh`: compare against the baselines in `README.md`                              |

Do not claim that a check passed if you did not run it. If a check cannot run in your
environment, say so in the PR. Do not stay silent.

## Hard invariants

A diff that breaks one of these invariants is wrong. It is not a design discussion. If
you think that the constraint itself is wrong, open an issue before you write code.

**Argv-only spawn.** Each subprocess goes through argv-style APIs
(`fs_compat.Child.init(argv, allocator)`). No `sh -c <string>`, no `/bin/sh`, no shell
interpolation. This also applies to comments, because the lint scans them too. The only
exception is the rejection list in `src/core/services/plist.zig`, which exists to refuse
them. `tests/spawn_invariant_test.zig` and `scripts/lint-spawn-invariants.sh` enforce
this rule.

**A new CLI flag goes to four places.** The parser, `src/cli/help.zig`, all three shells
in `src/cli/completions.zig` (bash, zsh, fish), and the regenerated `man/malt.1`.
`tests/flag_drift_test.zig` gets the truth from the parsers and fails `zig build test`
on drift. Thus, a flag that is only partly connected cannot merge.

**Do the work in-process.** Use `std.fs`, `std.posix`, `std.crypto`, and `std.tar`
before you use a subprocess. malt copies, hashes, extracts, links, and patches Mach-O
binaries in Zig on purpose. Thus, malt does not depend on the `cp`, `shasum`, or `tar`
on `PATH`, and it does not parse their output. It gets real error values instead of exit
codes, and the spawn audit has one less call site to clear. Sometimes the platform tool
is the real interface: `sandbox-exec`, `launchctl`, the `brew` fallback, and system
Ruby. Then spawn it argv-only and keep the call site narrow.

**Formula Ruby is pinned.** malt executes downloaded source only if its SHA256 matches
`src/core/pins_manifest.txt` for the pinned commit in `src/core/pins.zig`. No manifest
entry, no execution. The pin is frozen, because upstream has migrated all Ruby
`post_install` blocks to declarative `post_install_steps`. Thus, nobody regenerates the
manifest now.

**Service declarations are validated.** Formula `service:` blocks go through
`plist_mod.validate` before launchd sees them. Do not add bypasses.

**The diff contains only the change.** Plans, task notes, scratch files, analysis
documents, and build artefacts stay out of the repository. `git status` must show only
the files that the change needs. Keep planning documents local. `docs/` is gitignored on
purpose.

**No traceability numbers in the artefacts.** Issue numbers, bug IDs, task IDs, and
internal document references go in the PR conversation. Do not put them in commit
messages, PR bodies, or code comments. Name regression scripts after the behaviour that
they pin, not after a ticket.

## Tests

**Work test-first.** Write the test and run it. Make sure that it fails for the reason
that you expect. Then write the implementation that makes it pass. A test that you write
after the code passes because it has the shape of the current code. It pins the
implementation, not the intent. It does not find the regression that you wrote it for.

New behaviour needs new tests. Changed behaviour needs updated tests. "Obvious" is not an
exception: each new flag, subcommand, and error path needs a pinning test.

- **Unit tests** are inline `test` blocks next to the code that they test, in `src/`.
- **Integration tests** are separate files in `tests/`, one for each subsystem.
- **Each edge case gets its own test case.** Edge cases are the most important tests:
  empty input, boundary values, off-by-one limits, malformed and hostile data,
  permission and I/O failure, interrupted or concurrent access, and the error branch of
  each `try`. The happy path is the least likely to break. A suite that covers only the
  happy path tells you nothing.
- **When you fix a bug, ask if it can occur again.** If it can, add a script under
  `scripts/regressions/`. Name it after the behaviour that it pins.
- A test that cannot fail when the logic changes is not a test. Encode _why_ the
  behaviour is important, not only that the current output is the current output.

## Where code goes

- `src/cli/`: command implementations, flag parsing, user-facing output
- `src/core/`: package-manager logic. It stays a leaf: no `cli/*` or `ui/*` imports, and
  no user-facing strings. `src/core/forge.zig` is the model. A new forge is a new enum
  arm, so the compiler flags each unhandled `switch`.
- `src/ui/`, `src/tui/`: rendering and the interactive TUI
- `src/net/`, `src/db/`, `src/fs/`, `src/macho/`, `src/update/`: transport, SQLite
  state, filesystem primitives, Mach-O patching, self-update
- `tests/`: cross-module integration tests
- `scripts/regressions/`: one script for each fixed bug

Write idiomatic Zig 0.16 and follow the patterns that are already in the file that you
edit: explicit error sets, `defer` / `errdefer`, `anytype` writers, allocator threading
instead of global state, and `std.posix` / `std.Io` / `std.crypto` instead of libc
wrappers. Use `StaticStringMap` and an exhaustive `switch` instead of chains of string
comparisons.

Keep comments short. A comment explains _why_ you made a non-obvious choice. Not all code
needs a comment. A comment that repeats the code, or describes implementation detail
that the reader can see, is noise. Delete it.

## Out of scope

Do not write this code. Open an issue instead. These boundaries are settled, and
maintainers close PRs against them without a long discussion.

- Linux or Windows support
- Brewfile `do … end` blocks and Ruby conditionals such as `if OS.mac?` (the escape
  hatch is `Maltfile.json`)
- `post_install` constructs outside the documented Ruby subset in `src/core/dsl/` (the
  escape hatch is `--use-system-ruby`)
- Mac App Store (`mas`) and VSCode (`vscode`) install support

## Branches, commits, PRs

- Use a branch prefix that matches the change: `feat/`, `fix/`, `refactor/`, `perf/`,
  `chore/`, `docs/`, `test/`. Do not use `wip/` or `ui/`.
- Use a [Conventional Commits](https://www.conventionalcommits.org/) header
  (`type(scope): subject`). The subject states the value delivered, not the
  implementation. The body explains _why_, not _what_.
- Do not add `Co-Authored-By` or any AI attribution trailer to commits.
- PRs target `main`, also fixes for the current release. Never target `release/*`.
- malt squash-merges PRs, so the PR title becomes the `git log` entry. Use a
  Conventional Commits header of fewer than 70 characters.
- The PR body uses the repository template. It describes the user-visible change or the
  safety property that you added, not each file. Fill all sections. Write `- None` under
  _Related Issue_ and _Notes for Reviewers_ when nothing applies.
- For all changes larger than a typo or a one-line fix, open an issue first.

## Before you open the PR

- [ ] All acceptance criteria in the request are met, not only most of them
- [ ] `just fmt`, `just test`, and `./scripts/lint-spawn-invariants.sh` pass
- [ ] Extra checks for the surfaces this diff touches (see the table above) were run
- [ ] Tests were written first and observed failing before the implementation landed
- [ ] New behaviour has new tests; changed behaviour has updated tests
- [ ] Edge cases and error branches are covered, not just the happy path
- [ ] Anything that could regress has a script under `scripts/regressions/`
- [ ] New or changed flags reached help, all three completions, and `man/malt.1`
- [ ] New environment variables reached the README table
- [ ] Scripts covering the touched behaviour pass (`e2e`, `smokes`, `test`, `regressions`)
- [ ] Nothing shells out that `std` could have done in-process
- [ ] Binary size and the `scripts/bench.sh` numbers held - or the PR says why they moved
- [ ] The diff contains only the change: no plans, scratch files, or build artefacts
- [ ] Comments explain _why_, and there are no leftover narration comments
- [ ] No issue, bug, task, or document numbers in commits, PR body, or comments
- [ ] No attribution trailers in commit messages
- [ ] Branch prefix, commit headers, and PR title follow Conventional Commits
- [ ] PR body fills every template section
