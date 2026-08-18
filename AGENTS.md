# AGENTS.md

Instructions for AI coding agents working in this repository. Humans should read
[CONTRIBUTING.md](CONTRIBUTING.md) first - it explains the _why_ behind everything below.
This file is the executable subset: exact commands, hard invariants, and the rules
agents most often get wrong. The [pre-PR checklist](#before-you-open-the-pr) at the end
is the short form.

AI-assisted PRs are welcome. The contributor is accountable for the diff: read it,
understand it, and stand behind it as your own work.

## Project shape

malt is a Homebrew-compatible package manager written in **Zig 0.16**, targeting
**macOS only**. It is ~4 MB, starts in ~3 ms, and the install benchmarks in `README.md`
are the published baseline. Those numbers are the product, not trivia: a change that
grows the binary or moves the benchmarks needs a reason stated in the PR, with the
before-and-after numbers. Weigh every new dependency against them.

Do not port to Linux or Windows. Mach-O patching, APFS clonefile, launchd,
`sandbox-exec`, and the bottle ecosystem are all platform-specific, and the
macOS-only constraint is deliberate.

## Verify before proposing a diff

```bash
just fmt                              # zig fmt + shfmt on shell scripts
just test                             # unit tests + cheap static regression guards
./scripts/lint-spawn-invariants.sh    # argv-only spawn lint
```

`just test` wraps `zig build test` and adds the static guards; prefer it over calling
`zig build test` directly. Run `just --list` for every available target.

Every existing test must pass. If a test fails - even one that looks flaky or unrelated
to your change - fix it or report it. Do not describe a red suite as green.

If tests fail with a GitHub API rate-limit error, they are starved of auth, not broken.
Export a token and re-run before concluding anything:

```bash
export MALT_GITHUB_TOKEN="$(gh auth token)"
```

Additionally, depending on what the diff touches:

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
| install, parse, network, or concurrency paths                                       | `./scripts/bench.sh` - compare against the baselines in `README.md`                             |

Do not claim a check passed without running it. If a check cannot run in your
environment, say so explicitly in the PR rather than staying silent.

## Hard invariants

A diff that breaks one of these is wrong, not a design discussion. If you believe the
constraint itself is wrong, open an issue before writing code.

**Argv-only spawn.** Every subprocess goes through argv-style APIs
(`fs_compat.Child.init(argv, allocator)`). No `sh -c <string>`, no `/bin/sh`, no shell
interpolation - not even inside comments, which the lint also scans. The only exception
is the rejection list in `src/core/services/plist.zig`, which exists to refuse them.
Guarded by `tests/spawn_invariant_test.zig` and `scripts/lint-spawn-invariants.sh`.

**A new CLI flag reaches four places.** The parser, `src/cli/help.zig`, all three shells
in `src/cli/completions.zig` (bash, zsh, fish), and the regenerated `man/malt.1`.
`tests/flag_drift_test.zig` derives the truth from the parsers and fails
`zig build test` on drift, so a half-wired flag will not merge.

**Do the work in-process.** Reach for `std.fs`, `std.posix`, `std.crypto`, and
`std.tar` before reaching for a subprocess. malt copies, hashes, extracts, links, and
patches Mach-O binaries in Zig on purpose: no dependency on which `cp`, `shasum`, or
`tar` happens to be on `PATH`, no output parsing, real error values instead of exit
codes, and one less call site for the spawn audit to clear. When the platform tool
genuinely is the interface - `sandbox-exec`, `launchctl`, the `brew` fallback, system
Ruby - spawn it argv-only and keep the call site narrow.

**Formula Ruby is pinned.** Source fetched over the wire is executed only if its SHA256
matches `src/core/pins_manifest.txt` against the pinned commit in `src/core/pins.zig`.
No manifest entry, no execution. Regenerate both with `scripts/gen-pins.sh`.

**Service declarations are validated.** Formula `service:` blocks pass through
`plist_mod.validate` before launchd sees them. Do not add bypasses.

**The diff contains only the change.** Plans, task notes, scratch files, analysis
write-ups, and build artefacts stay out of the repository - `git status` should show
nothing but the files the change needs. Keep planning docs local; `docs/` is gitignored
on purpose.

**No traceability numbers in the artefacts.** Issue numbers, bug IDs, task IDs, and
internal document references belong in the PR conversation, not in commit messages, PR
bodies, or code comments. Regression scripts are named after the behaviour they pin, not
after a ticket.

## Tests

**Work test-first.** Write the test, run it, watch it fail for the reason you expect,
then write the implementation that turns it green. A test written after the code passes
because it was shaped around what the code already does - it pins the implementation
instead of the intent, and it will not catch the regression you wrote it for.

New behaviour requires new tests. Changed behaviour requires updated tests. "Obvious" is
not an exception - every new flag, subcommand, and error path lands with a pinning test.

- **Unit tests** are inline `test` blocks next to the code they exercise, in `src/`.
- **Integration tests** are separate files in `tests/`, one per subsystem.
- **Edge cases get their own cases**, and they are the point of the exercise: empty
  input, boundary values, off-by-one limits, malformed and hostile data, permission and
  I/O failure, interrupted or concurrent access, the error branch of every `try`. The
  happy path is the case least likely to break; a suite that only covers it tells you
  nothing.
- **Fixed a bug? Ask whether it can come back.** If it can, add a script under
  `scripts/regressions/` named after the behaviour it pins.
- A test that cannot fail when the logic changes is not a test. Encode _why_ the
  behaviour matters, not just that the current output is the current output.

## Where code goes

- `src/cli/` - command implementations, flag parsing, user-facing output
- `src/core/` - package-manager logic. Stays a leaf: no `cli/*` or `ui/*` imports, no
  user-facing strings. `src/core/forge.zig` is the model - adding a forge is a new enum
  arm so the compiler flags every unhandled `switch`.
- `src/ui/`, `src/tui/` - rendering and the interactive TUI
- `src/net/`, `src/db/`, `src/fs/`, `src/macho/`, `src/update/` - transport, SQLite
  state, filesystem primitives, Mach-O patching, self-update
- `tests/` - cross-module integration tests
- `scripts/regressions/` - one script per fixed bug

Write idiomatic Zig 0.16 and follow the patterns already in the file you are editing:
explicit error sets, `defer` / `errdefer`, `anytype` writers, allocator threading over
global state, `std.posix` / `std.Io` / `std.crypto` over libc wrappers. Prefer
`StaticStringMap` plus an exhaustive `switch` over chains of string comparisons.

Comments are short and explain _why_ a non-obvious choice was made. Not everything needs
one. A comment that restates the code, or narrates implementation detail the reader can
see, is noise - delete it.

## Out of scope

Do not write this code. Open an issue instead - these are settled boundaries and PRs
against them are closed without a long discussion.

- Linux or Windows support
- Brewfile `do … end` blocks and Ruby conditionals such as `if OS.mac?` (the escape
  hatch is `Maltfile.json`)
- `post_install` constructs outside the documented Ruby subset in `src/core/dsl/` (the
  escape hatch is `--use-system-ruby`)
- Mac App Store (`mas`) and VSCode (`vscode`) install support

## Branches, commits, PRs

- Branch prefix matching the change: `feat/`, `fix/`, `refactor/`, `perf/`, `chore/`,
  `docs/`, `test/`. No `wip/` or `ui/`.
- [Conventional Commits](https://www.conventionalcommits.org/) header
  (`type(scope): subject`). The subject states the value delivered, not the
  implementation; the body explains _why_, not _what_.
- Do not add `Co-Authored-By` or any AI attribution trailer to commits.
- PRs target `main`, including fixes for the current release. Never target `release/*`.
- PRs are squash-merged, so the PR title becomes the `git log` entry: Conventional
  Commits header, under 70 chars.
- The PR body uses the repo template and describes the user-visible change or the safety
  property added - not a file-by-file walkthrough. Fill every section; write `- None`
  under _Related Issue_ and _Notes for Reviewers_ when nothing applies.
- Anything beyond a typo or one-liner: open an issue first.

## Before you open the PR

- [ ] Every acceptance criterion in the request is met - not most of them
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
