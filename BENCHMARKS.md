# Benchmarks

Install times for malt against nanobrew, zerobrew and Homebrew, refreshed weekly by the [benchmark workflow](.github/workflows/benchmark.yml). The README shows the cold and warm tables at a glance.

<!-- BENCH:META:START -->

- Install times on macOS 14 (Apple Silicon).
- Benchmarked releases:
  - malt `0.24.4`
  - nanobrew `v0.1.212`
  - zerobrew `v0.3.2`

<!-- BENCH:META:END -->

<!-- BENCH:COLD:START -->

### Cold Install (median ±σ)

| Package              | malt         | nanobrew     | zerobrew                | Homebrew     |
| -------------------- | ------------ | ------------ | ----------------------- | ------------ |
| **tree** (0 deps)    | 0.490±0.017s | 0.554±0.039s | 1.143±0.016s            | 1.076±0.060s |
| **wget** (6 deps)    | 2.867±0.266s | 6.680±0.276s | ⚠️ n/a (install failed) | 1.337±0.081s |
| **ffmpeg** (11 deps) | 3.177±0.182s | 6.299±0.390s | ⚠️ n/a (install failed) | 2.690±0.089s |

> ⚠️ = cell omitted. That tool's cold install failed, or exceeded the
> sanity ceiling (50 s), which reflects a regression in that tool rather
> than a comparable install time, so the number is withheld instead of
> published. malt is never omitted - a real malt slowdown stays visible.

<!-- BENCH:COLD:END -->

<!-- BENCH:WARM:START -->

### Warm Install

| Package              | malt   | nanobrew | zerobrew                |
| -------------------- | ------ | -------- | ----------------------- |
| **tree** (0 deps)    | 0.007s | 0.109s   | 0.271s                  |
| **wget** (6 deps)    | 0.017s | 0.403s   | ⚠️ n/a (install failed) |
| **ffmpeg** (11 deps) | 0.020s | 3.307s   | ⚠️ n/a (install failed) |

<!-- BENCH:WARM:END -->

<!-- BENCH:SIZE:START -->

### Binary Size

| Tool     | Size   |
| -------- | ------ |
| **malt** | 4.3 MB |
| nanobrew | 3.4 MB |
| zerobrew | 8.7 MB |

<!-- BENCH:SIZE:END -->

> Apple Silicon (GitHub Actions macos-14), 2026-09-28. Auto-updated weekly via the [benchmark workflow](.github/workflows/benchmark.yml).

## Methodology

Each cell is the **median of 5 rounds** (`BENCH_ROUNDS=5`, the default in [`scripts/bench.sh`](scripts/bench.sh)) - more robust to single-run jitter than a mean. Override with `BENCH_ROUNDS=N`. Every run also emits per-tool `_min` and `_stddev` keys to `$GITHUB_OUTPUT` and prints them in the local terminal summary.

A cold sample here starts from a wiped install prefix for every tool, so the first round exercises the full download → extract → link → db-write path. Some benchmark scripts define "cold" as an uninstall/reinstall, which keeps the download cache warm; the two definitions can produce different absolute cold numbers for the same tool on the same hardware.

`BENCH_TRUE_COLD=1` wipes each tool's install prefix **and** bottle download cache before every cold sample, so "cold" means no bottle anywhere on disk.

- malt, nanobrew, zerobrew: one prefix wipe covers both (the cache lives inside the prefix).
- Homebrew: the cache lives outside the prefix (`~/Library/Caches/Homebrew/downloads`), so it's wiped explicitly per formula and its transitive deps via `brew --cache`.
- Without that extra Homebrew wipe, local brew numbers come out 5–25× faster than CI's - brew is reusing bottles cached by earlier rounds.

Each package bench opens with a discarded warmup round: every tool runs one install/uninstall pair whose timings are thrown away, so DNS, TLS session cache, TCP congestion window, and disk caches are all populated before timing starts.

The measured rounds then rotate tool order (round _r_ starts with `tools[r mod N]`), so no single tool reliably eats the "cold network" slot or benefits from the warmest one.

`scripts/bench.sh` resolves nanobrew's and zerobrew's latest release tag before each build, so a peer is never benched as a weeks-old snapshot nor as a mid-development commit. Set `BENCH_SKIP_UPDATE=1` to pin whatever is already checked out. CI additionally sets `BENCH_MALT_RELEASE=1` so the published table is release-vs-release; a local run benches your working tree.

A peer tool whose cold install fails, or exceeds `BENCH_MAX_COLD` (50 s), has that cell withheld as ⚠️ - a regression in their tool is not a comparable number. malt is never withheld: its own numbers stay in the table however bad they get, and a failed malt install aborts the run instead of publishing anything.

Each tool is built using the release flags its upstream ships with: malt `ReleaseSafe` (matches [`.goreleaser.yaml`](.goreleaser.yaml)), nanobrew `ReleaseFast`, zerobrew `cargo build --release`. Binary sizes may differ from the numbers shown on each tool's own repo - the gap is almost always version drift, not a flag difference.

To reproduce locally, `./scripts/local-bench.sh` runs the four CI phases (tree, wget, ffmpeg, stress-test) in order. Add `--clean` to wipe `/tmp` bench state afterwards. For iterative work, `scripts/bench.sh <pkg>` directly - `SKIP_BUILD=1` reuses existing binaries; `SKIP_OTHERS=1` / `SKIP_BREW=1` skip peer comparisons.
