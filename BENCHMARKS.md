# Benchmarks

Install times for malt against nanobrew, zerobrew and Homebrew, refreshed weekly by the [benchmark workflow](.github/workflows/benchmark.yml). The README shows the cold and warm tables at a glance.

<!-- BENCH:META:START -->

- Install times on macOS 14 (Apple Silicon).
- Benchmarked releases:
  - malt `0.25.0`
  - nanobrew `v0.1.213`
  - zerobrew `v0.3.5`

<!-- BENCH:META:END -->

<!-- BENCH:COLD:START -->

### Cold Install (median ±σ)

| Package              | malt         | nanobrew                | zerobrew                | Homebrew     |
| -------------------- | ------------ | ----------------------- | ----------------------- | ------------ |
| **tree** (0 deps)    | 0.516±0.027s | 0.589±0.033s            | 1.244±0.088s            | 1.341±0.195s |
| **wget** (6 deps)    | 3.225±0.328s | ⚠️ n/a (install failed) | ⚠️ n/a (install failed) | 1.496±0.194s |
| **ffmpeg** (11 deps) | 3.567±0.229s | ⚠️ n/a (install failed) | ⚠️ n/a (install failed) | 3.262±0.409s |

> ⚠️ = cell omitted. That tool's cold install failed, or exceeded the
> sanity ceiling (50 s), which reflects a regression in that tool rather
> than a comparable install time, so the number is withheld instead of
> published. malt is never omitted - a real malt slowdown stays visible.

<!-- BENCH:COLD:END -->

<!-- BENCH:WARM:START -->

### Warm Install

| Package              | malt   | nanobrew                | zerobrew                |
| -------------------- | ------ | ----------------------- | ----------------------- |
| **tree** (0 deps)    | 0.012s | 0.107s                  | 0.341s                  |
| **wget** (6 deps)    | 0.018s | ⚠️ n/a (install failed) | ⚠️ n/a (install failed) |
| **ffmpeg** (11 deps) | 0.026s | ⚠️ n/a (install failed) | ⚠️ n/a (install failed) |

<!-- BENCH:WARM:END -->

<!-- BENCH:SIZE:START -->

### Binary Size

| Tool     | Size   |
| -------- | ------ |
| **malt** | 4.7 MB |
| nanobrew | 3.5 MB |
| zerobrew | 8.7 MB |

<!-- BENCH:SIZE:END -->

> Apple Silicon (GitHub Actions macos-14), 2026-10-05. Auto-updated weekly via the [benchmark workflow](.github/workflows/benchmark.yml).

## Methodology

### What a number means

Each cell is the wall-clock time of one command, `<tool> install <pkg>`, measured from launch to exit. That covers resolving dependencies, downloading, extracting, relocating, linking, and recording the install.

A sample only counts if the package works afterwards. Once the install exits, the bench runs the package's own binary from the tool's prefix (`tree --version`, `java -version`, ...). That check is not timed. If the install exits non-zero or the binary doesn't run, the sample is a failure, not a time. So a tool can't post a fast number for a partial install, or for a bottle built for a newer macOS that won't load.

### Cold and warm

- **Cold**: the package and every dependency are absent, and the tool has no cached bottles or package metadata. Every byte comes from the network, like a fresh machine.
  - malt, nanobrew, zerobrew: the bench wipes the tool's whole prefix, which holds its caches.
  - Homebrew: the bench uninstalls the package and its whole dependency tree, then deletes those bottles from `~/Library/Caches/Homebrew` and drops the API metadata cache. Auto-update and post-install cleanup are switched off so they don't land in the timing.
- **Warm**: the package was just uninstalled, and the tool's download cache is still populated. This measures install work without the network. Homebrew has no warm column.

Uninstalling Homebrew's dependency tree would remove packages from a real install, so it only happens on CI or with `BENCH_BREW_FULL_COLD=1`. A local run without it keeps brew's dependencies installed and prints a warning: those brew numbers are not comparable.

### Noise control

- Each cell is the **median of 5 rounds** (`BENCH_ROUNDS`), shown with its standard deviation.
- A discarded warmup round runs first, so DNS, TLS and disk caches are populated before timing starts.
- Tool order rotates every round, so no tool always gets the slowest or fastest network slot.

### Versions and builds

- Peers are built from their latest release tag. CI also builds malt from its latest release branch (`BENCH_MALT_RELEASE=1`), so the table is release against release. A local run benches your working tree.
- Each tool uses the release flags its upstream ships: malt `ReleaseSafe` (as in [`.goreleaser.yaml`](.goreleaser.yaml)), nanobrew `ReleaseFast`, zerobrew `cargo build --release`.
- CI runs on `macos-26`, so every package has a bottle built for the host OS.

### Withheld cells

A peer's cell shows ⚠️ when its install fails or its cold median exceeds 50 s (`BENCH_MAX_COLD`). That points to a regression in that tool, not a comparable time. malt is never withheld: a failed malt install aborts the run, so it can't publish anything.

### Reproducing

`./scripts/local-bench.sh` runs the same steps as CI: every package, then the ffmpeg ×20 stress test. Add `--clean` to wipe the `/tmp` bench state afterwards. To iterate, run `scripts/bench.sh <pkg>` directly:

- `SKIP_BUILD=1` reuses the existing binaries.
- `SKIP_OTHERS=1` and `SKIP_BREW=1` drop the peer tools.
- `BENCH_SKIP_UPDATE=1` keeps whatever peer versions are already checked out.
