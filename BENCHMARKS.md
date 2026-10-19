# Benchmarks

This file gives the install times of malt, nanobrew, zerobrew, and Homebrew. The [benchmark workflow](.github/workflows/benchmark.yml) updates them each week. The README shows a summary of the cold and warm tables.

<!-- BENCH:META:START -->
- Install times on macOS 26 (Apple Silicon).
- Benchmarked releases:
  - malt `0.25.2`
  - nanobrew `v0.1.213`
  - zerobrew `v0.4.0`
<!-- BENCH:META:END -->

> [!NOTE]
> malt verifies the SHA256 of a bottle before it reads the archive. Thus, extraction starts only after the download is complete. A client that extracts during the download can be faster on large packages, but its parser reads data that is not verified yet. → [Verify before parse](ARCHITECTURE.md#safety-and-security)

<!-- BENCH:COLD:START -->
### Cold Install (median ±σ)

| Package | malt | nanobrew | zerobrew | Homebrew |
| ------- | ---- | -------- | -------- | -------- |
| **tree** (0 deps) | 0.554±0.007s | 0.594±0.033s | 1.106±0.185s | 1.894±0.187s |
| **wget** (7 deps) | 3.591±0.582s | 7.903±0.754s | 4.009±0.808s | 20.904±4.086s |
| **ffmpeg** (14 deps) | 4.001±0.536s | 7.992±0.935s | 3.523±0.189s | 20.654±1.923s |
| **openjdk** (29 deps) | 15.060±1.395s | 25.897±4.279s | 7.214±0.438s | 17.368±1.414s |
| **tesseract** (37 deps) | 10.698±0.570s | 29.125±6.394s | 5.792±0.435s | 19.247±1.722s |
<!-- BENCH:COLD:END -->

<!-- BENCH:WARM:START -->
### Warm Install

| Package | malt | nanobrew | zerobrew |
| ------- | ---- | -------- | -------- |
| **tree** (0 deps) | 0.015s | 0.112s | 0.307s |
| **wget** (7 deps) | 0.023s | 0.113s | 0.264s |
| **ffmpeg** (14 deps) | 0.031s | 4.110s | 0.252s |
| **openjdk** (29 deps) | 0.018s | 6.482s | 0.220s |
| **tesseract** (37 deps) | 0.021s | 1.381s | 0.282s |
<!-- BENCH:WARM:END -->

<!-- BENCH:SIZE:START -->
### Binary Size

| Tool | Size |
| ---- | ---- |
| **malt** | 4.8 MB |
| nanobrew | 3.5 MB |
| zerobrew | 8.7 MB |
<!-- BENCH:SIZE:END -->

> Apple Silicon (GitHub Actions macos-26), 2026-10-12. Auto-updated weekly via the [benchmark workflow](.github/workflows/benchmark.yml).

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
