# Benchmarks

This file gives the install times of malt, nanobrew, zerobrew, and Homebrew. The [benchmark workflow](.github/workflows/benchmark.yml) updates them each week. The README shows a summary of the cold and warm tables.

<!-- BENCH:META:START -->
- Install times on macOS 26 (Apple Silicon).
- Benchmarked releases:
  - malt `0.25.0`
  - nanobrew `v0.1.214`
  - zerobrew `v0.4.1`
<!-- BENCH:META:END -->

<!-- BENCH:COLD:START -->
### Cold Install (median ±σ)

| Package | malt | nanobrew | zerobrew | Homebrew |
| ------- | ---- | -------- | -------- | -------- |
| **tree** (0 deps) | 0.360±0.060s | 0.437±0.090s | 1.027±0.138s | 3.558±0.101s |
| **wget** (7 deps) | 4.187±2.281s | 8.746±1.036s | 16.763±1.403s | 39.387±5.286s |
| **ffmpeg** (14 deps) | 4.196±0.764s | 7.437±0.529s | 14.384±1.582s | 36.338±3.280s |
| **openjdk** (29 deps) | 16.440±2.588s | 30.599±5.266s | 9.510±1.140s | 48.618±5.683s |
| **tesseract** (37 deps) | 12.846±0.970s | 20.186±1.580s | 10.686±1.839s | ⚠️ n/a (>50s) |

> ⚠️ = cell omitted. That tool's cold install failed, or exceeded the
> sanity ceiling (50 s), which reflects a regression in that tool rather
> than a comparable install time, so the number is withheld instead of
> published. malt is never omitted - a real malt slowdown stays visible.
<!-- BENCH:COLD:END -->

<!-- BENCH:WARM:START -->
### Warm Install

| Package | malt | nanobrew | zerobrew |
| ------- | ---- | -------- | -------- |
| **tree** (0 deps) | 0.016s | 0.111s | 0.320s |
| **wget** (7 deps) | 0.032s | 0.159s | 0.322s |
| **ffmpeg** (14 deps) | 0.028s | 3.821s | 0.232s |
| **openjdk** (29 deps) | 0.016s | 5.880s | 0.198s |
| **tesseract** (37 deps) | 0.022s | 1.421s | 0.310s |
<!-- BENCH:WARM:END -->

<!-- BENCH:SIZE:START -->
### Binary Size

| Tool | Size |
| ---- | ---- |
| **malt** | 4.8 MB |
| nanobrew | 3.5 MB |
| zerobrew | 9.1 MB |
<!-- BENCH:SIZE:END -->

> Apple Silicon (GitHub Actions macos-26), 2026-10-19. Auto-updated weekly via the [benchmark workflow](.github/workflows/benchmark.yml).

## Methodology

### What a number means

Each cell is the wall-clock time of one command, `<tool> install <pkg>`, from launch to exit. This time includes dependency resolution, download, extraction, relocation, links, and the install record.

A sample counts only if the package works after the install. When the install exits, the bench runs the binary of the package from the prefix of the tool (`tree --version`, `java -version`, ...). This check is not timed. If the install exits with a non-zero code or the binary does not run, the sample is a failure, not a time. Thus, a tool cannot show a fast time for a partial install. It also cannot show a fast time for a bottle that is built for a newer macOS and does not load.

### Cold and warm

- **Cold**: the package and all its dependencies are not installed, and the tool has no cached bottles or package metadata. All data comes from the network, as on a new machine.
  - malt, nanobrew, zerobrew: the bench deletes the full prefix of the tool, which contains its caches.
  - Homebrew: the bench uninstalls the package and its full dependency tree. Then it deletes these bottles from `~/Library/Caches/Homebrew` and deletes the API metadata cache. Auto-update and post-install cleanup are off, so they do not add to the time.
- **Warm**: the package was uninstalled immediately before, and the download cache of the tool is still full. This measures the install work without the network. Homebrew has no warm column.

An uninstall of the Homebrew dependency tree removes packages from a real install. Thus, the bench does this only on CI or with `BENCH_BREW_FULL_COLD=1`. Without it, a local run keeps the brew dependencies installed and prints a warning. These brew times are not comparable.

### Noise control

- Each cell is the **median of 5 rounds** (`BENCH_ROUNDS`), with its standard deviation.
- A warmup round runs first, and the bench discards it. Thus, the DNS, TLS, and disk caches are full before the timing starts.
- The tool order changes each round. Thus, no tool always gets the slowest or fastest network slot.

### Versions and builds

- The bench builds peers from their latest release tag. CI also builds malt from its latest release branch (`BENCH_MALT_RELEASE=1`), so the table compares release with release. A local run measures your working tree.
- Each tool uses the release flags that its upstream ships: malt `ReleaseSafe` (as in [`.goreleaser.yaml`](.goreleaser.yaml)), nanobrew `ReleaseFast`, zerobrew `cargo build --release`.
- CI runs on `macos-26`. Thus, each package has a bottle built for the host OS.

### Withheld cells

A peer cell shows ⚠️ if its install fails or its cold median is more than 50 s (`BENCH_MAX_COLD`). This shows a regression in that tool, not a comparable time. malt is never withheld. A failed malt install stops the run, so the run publishes nothing.

### Reproducing

`./scripts/local-bench.sh` runs the same steps as CI: all packages, then the ffmpeg ×20 stress test. To delete the `/tmp` bench state after the run, add `--clean`. For quick iterations, run `scripts/bench.sh <pkg>` directly:

- `SKIP_BUILD=1` uses the existing binaries again.
- `SKIP_OTHERS=1` and `SKIP_BREW=1` remove the peer tools from the run.
- `BENCH_SKIP_UPDATE=1` keeps the peer versions that are already checked out.
