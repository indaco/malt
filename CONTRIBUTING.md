# Contributing

malt is a Homebrew-compatible package manager written in Zig. These notes
capture invariants and security rules that every patch is expected to
honour. If a change can't satisfy one of them, raise the trade-off in
the PR rather than silently relaxing the rule.

## Security invariants

### Argv-only spawn

Every Zig-side subprocess is spawned through argv-style APIs —
`fs_compat.Child.init(argv, allocator)` (which forwards to
`std.process.spawn`). **No `sh -c <string>`, no `/bin/sh`, no shell
interpolation.** Building argv as a static `[_][]const u8{ … }` is the
norm; anything that looks like a shell command string in a spawn call
site is a security regression.

- Enforcement: `scripts/lint-spawn-invariants.sh` runs in CI.
- Local guard: `tests/spawn_invariant_test.zig` walks `src/` and fails
  `zig build test` on violations.
- Legitimate exceptions: only the rejection list in
  `src/core/services/plist.zig` names `/bin/sh`-style paths, because
  it's the validator that _refuses_ them in formula-declared services.

### Ruby post_install sandbox

The `--use-system-ruby` path runs in a macOS `sandbox-exec` profile
that denies network, denies writes outside the formula's cellar and
`MALT_PREFIX/{etc,var,share,opt}`, strips the environment down to
`HOME`, a minimal `PATH`, `MALT_PREFIX`, and `TMPDIR`, and applies
`RLIMIT_CPU`/`RLIMIT_AS`/`RLIMIT_FSIZE` to the child. See
`src/core/sandbox/macos.zig`. The flag is per-formula — a bare
`--use-system-ruby` only works when a single package is being
installed, and is rejected outright on `migrate`.

### Homebrew-core pin

Formula Ruby source fetched over the wire is checked against
`src/core/pins_manifest.txt` and executed only if the SHA256 matches
the pinned `homebrew-core` commit in `src/core/pins.zig`. No manifest
entry = no execution. Regenerate both with `scripts/gen-pins.sh` when
bumping the pin.

### Service declarations

Formula `service:` blocks flow through `plist_mod.validate` before
launchd ever sees them: `program_args[0]` must live under the
formula's own cellar or `MALT_PREFIX/opt/<formula>`, interpreter
shebangs (`/bin/sh` etc.) are refused as the leading executable,
argv length / per-arg length are capped, and NUL bytes are rejected.

### Release signing

Releases are signed keyless via cosign in the goreleaser workflow;
`scripts/install.sh` re-verifies the signature before the SHA check.
Fail-closed: no signature, no install (bypass requires explicit
`MALT_ALLOW_UNVERIFIED=1`). The
`scripts/test/install_sh_test.sh` suite locks the fail-closed paths
against regression.

## Build & test

```bash
zig build                                        # Debug binary
zig build -Doptimize=ReleaseSafe                 # release-equivalent binary
zig build test                                   # unit tests
./scripts/lint-spawn-invariants.sh               # argv-only lint
./scripts/test/install_sh_test.sh                # install.sh regression
./scripts/local-bench.sh                         # full bench suite (slow)
./scripts/e2e/smoke_test.sh                      # CLI smoke coverage
./scripts/e2e/smoke_security.sh                  # security-surface smoke
```

After any change that touches the items in the **Security invariants**
section above — sandbox, pins, plist validator, install.sh,
`--use-system-ruby`, argv-only spawn — run `./scripts/e2e/smoke_security.sh`
before opening the PR. It's the single entry point that exercises every
protection end-to-end (flag scoping, argv-only lint, pins-manifest
shape, install.sh fail-closed suite) in ~10 seconds, fully offline.

## Coding conventions

Follow the idiomatic-Zig patterns already present in the file you're
editing: explicit error sets, `defer` / `errdefer` for cleanup,
`anytype` writers, allocator threading over global state. Keep
comments short and focused on _why_ a non-obvious choice was made —
don't restate the code.
