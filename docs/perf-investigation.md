# malt — Performance Investigation

> **Status:** problem statement only. No fixes yet — this doc is meant to brief
> follow-up agents (`coder`, `performance-engineer`, `analyst`) on what to dig
> into.

## The problem

malt's stated reason to exist is **being faster than Homebrew**. Measured
today against a real installation flow, **it isn't** — and it's not just
slower than the other minimalist Zig/Rust alternatives, it's slower than
Homebrew itself, which is the thing it was supposed to replace.

A clean, scripted run of `tree` (0 deps), `wget` (6 deps), and `ffmpeg`
(11 deps) on Apple Silicon, with every tool pointed at an isolated `/tmp`
prefix and the prefix wiped between cold and warm so nobody can cheat,
gives this:

### Cold install (true cold, prefix wiped)

| Package           | malt        | nanobrew | zerobrew | bru     | brew   |
| ----------------- | ----------- | -------- | -------- | ------- | ------ |
| `tree` (0 deps)   | **3.94 s**  | 0.57 s   | 1.01 s   | 0.02 s‡ | 2.71 s |
| `wget` (6 deps)   | **13.39 s** | 3.20 s   | 4.93 s   | 0.28 s‡ | 2.26 s |
| `ffmpeg` (11 deps)| **20.77 s** | 3.00 s   | 4.93 s   | 1.18 s‡ | 3.87 s |

### Warm install (prefix kept; bottle in store)

| Package           | malt       | nanobrew | zerobrew | bru     |
| ----------------- | ---------- | -------- | -------- | ------- |
| `tree` (0 deps)   | **1.11 s** | 0.009 s  | 0.11 s   | 0.02 s  |
| `wget` (6 deps)   | **1.26 s** | 0.75 s   | 0.49 s   | 0.06 s  |
| `ffmpeg` (11 deps)| **1.87 s** | 0.93 s   | 1.77 s   | 1.17 s  |

‡ bru cold numbers are almost certainly **not** real cold runs — see §3.

That's the headline. **malt is the slowest column in every cold row, and
the slowest in every warm row except the borderline case of `ffmpeg`
warm vs zerobrew.** Cold `wget` is the worst spot: malt is **5.9×
slower than Homebrew** and 4.2× slower than nanobrew on the same bottle
download. Warm `tree` is the most damning shape: nanobrew finishes in
**9 ms** what malt takes **1.11 s** to do — a ~123× gap on a workload
with zero dependencies and zero dylibs to relocate. Whatever malt is
doing for that 1.1 s, the other tools have decided they don't need to.

One more thing the new numbers reveal: malt's per-invocation floor is
**not** flat. tree → wget → ffmpeg warm goes 1.11 → 1.26 → 1.87 s, so
it does scale with package complexity, but **the zero-deps floor itself
is already 1.1 s** — and that's what we have to attack first.

The goal of this doc is to figure out **what** that work is and **whether
any of it is actually necessary**. The three concrete questions for the
agents:

1. **Where does malt's ~1 s warm-install floor come from?** It's a fixed
   per-invocation cost: `tree` (200 KB, 0 deps) and `wget` (with 6 deps)
   warm at ~1.10 s and ~1.14 s respectively. That +43 ms delta over a 6×
   bigger payload says the work is in startup/coordination, not
   per-file or per-byte.
2. **Why is malt's cold install 4–40× slower than the other Zig tools?**
   It downloads the same bytes from the same registry. The gap has to be
   in how it does the downloading + materializing, not in the network.
3. **Are the comparisons fair?** Specifically, bru's "0.05 s cold tree" is
   too fast to be a real network fetch. We should confirm whether bru is
   reading from a cache outside the prefix we wipe, so we know which
   numbers in the table to trust as "true cold."

## How these numbers were produced

```bash
BENCH_TRUE_COLD=1 ./scripts/bench.sh
```

- Each tool runs against an isolated `/tmp/<short>` prefix (`/tmp/mt-b`,
  `/tmp/nb`, `/tmp/zb`, `/tmp/bru`) — never `/opt/...`.
- `BENCH_TRUE_COLD=1` wipes each tool's prefix between cold and warm runs so
  the cold install really has to redownload from network.
- See `scripts/bench.sh` for the exact `time …` invocations and exit-code
  checks.

## Raw results

Run on the developer's M-series Mac (home network, ~2026-04-10).

### Binary size

| Tool     | Size   |
| -------- | ------ |
| **malt** | 3.2 M  |
| nanobrew | 1.4 M  |
| zerobrew | 8.6 M  |
| bru      | 1.8 M  |

malt is in the middle of the pack — ~2× nanobrew/bru, ~⅓ of zerobrew.
Not a problem on its own, just a data point.

> **Note:** brew warm is not measured (the upstream workflow only times brew
> cold, since the bench is comparing against "what an end-user would type
> after installing Homebrew").

## Observations

### 1. malt has a high per-invocation floor that mostly doesn't scale with the work

| Package            | malt warm | nanobrew warm | malt − nb |
| ------------------ | --------: | ------------: | --------: |
| `tree` (0 deps)    |    1.106s |        0.009s |   +1.10 s |
| `wget` (6 deps)    |    1.261s |        0.746s |   +0.52 s |
| `ffmpeg` (11 deps) |    1.865s |        0.929s |   +0.94 s |

Two things to read off this:

1. The **floor** (zero-dependency case) is already **~1.1 s**. nanobrew
   does the same `tree` install in **9 ms**. That ~1.1 s gap is the most
   actionable target — it's pure overhead, paid even when there's nothing
   to do.
2. Past the floor, malt's per-dep slope is roughly comparable to
   nanobrew's (`wget` adds ~150 ms vs nanobrew's ~740 ms; `ffmpeg` adds
   ~760 ms vs nanobrew's ~190 ms — noisy but clearly the same order of
   magnitude). So the second-priority question is: what is the floor
   work, and can it be deleted entirely or done once and cached?

Things we already ruled out:

- **Binary startup**: `malt --version` = **3 ms**, `malt list` = **5 ms**.
- **API freshness check**: `src/net/api.zig:46` (`fetchFormula`) reads from a
  TTL'd disk cache via `fetchCached → readCache` (`api.zig:72-114`); on a
  warm run there's no HTTP traffic.
- **Bottle download**: the bottle is already in `<prefix>/store/<sha>` and
  `src/cli/install.zig:112` (`store.exists(job.sha256)`) takes the cache-hit
  path, skipping `bottle_mod.download`.

So the 1 s is somewhere between **"Resolved"** and **"installed"** — i.e.
inside the **materialize** phase. Suspect call sites to inspect first:

- `src/cli/install.zig:300-360` — the resolve loop (calls `api.fetchFormula`
  per package + per dep).
- `src/cli/install.zig:660-720` — `recordKeg` + the SQLite INSERT/REPLACE
  path (`installRecordKeg` ~line 807, `INSERT OR REPLACE INTO kegs`).
- `src/core/cellar.zig` / `src/core/linker.zig` — file copies + symlink
  creation. **Top suspect**: are we walking the bottle and re-running
  Mach-O patching unconditionally even when there are no `Mach-O LC_*` slots
  to rewrite?
- `src/macho/relocate.zig` — for `tree` there are _no_ dylibs, so any time
  spent here on a `tree` install is wasted. Verify with `dtruss`/`sample`.
- `src/db/lock.zig` — global install lock. Is it doing a polling sleep loop?
- SQLite — every `BEGIN/COMMIT` on macOS implies an `fsync` against the WAL.
  How many transactions per install? Would batching help?

### 2. malt's cold install is slower than every alternative — including Homebrew

For `wget` (cold), normalized to malt = 1×:

| Tool     |     cold | vs malt |
| -------- | -------: | ------: |
| bru‡     |  0.277 s |  ×0.02  |
| brew     |  2.263 s |  ×0.17  |
| nanobrew |  3.203 s |  ×0.24  |
| zerobrew |  4.927 s |  ×0.37  |
| **malt** | 13.386 s |  ×1.00  |

For `ffmpeg` (cold):

| Tool     |     cold | vs malt |
| -------- | -------: | ------: |
| bru‡     |  1.182 s |  ×0.06  |
| nanobrew |  3.000 s |  ×0.14  |
| brew     |  3.869 s |  ×0.19  |
| zerobrew |  4.927 s |  ×0.24  |
| **malt** | 20.774 s |  ×1.00  |

‡ bru almost certainly hits a hidden cache — see §3.

Even **Homebrew** — written in Ruby/bash, the slow incumbent — beats malt
by ~6× on cold `wget` and ~5× on cold `ffmpeg`. nanobrew beats malt by
~4–7×. zerobrew (Rust) is on the same order as nanobrew. The bottles
being downloaded are byte-identical (all of these pull from
`ghcr.io/v2/homebrew/core` or its mirrors). So the gap is **not** in
download throughput; it's in how malt is doing the downloads.

Things to investigate:

- **Sequential vs parallel downloads.** `src/cli/install.zig:533` mentions
  "parallel download" in a comment but the cold-install slope is roughly
  linear in the number of dependencies (`tree`/`wget` cold delta: malt
  +7.84 s ≈ 6 deps × ~1.3 s/dep), which looks **serial**. Confirm via
  `dtruss -t connect` or by counting concurrent `recv()` syscalls.
- **GHCR auth round-trips.** GHCR requires a `GET /token?...` before each
  blob fetch. Are we requesting a fresh token _per bottle_? `src/net/ghcr.zig`
  is the place to look.
- **HTTP keep-alive.** `src/net/client.zig` — does the `HttpClient` reuse a
  single TCP connection across requests, or does each download open a fresh
  TLS handshake? On a home network, a TLS handshake is ~150–300 ms; doing
  one per bottle would explain a large chunk of the cold gap.
- **Atomic install vs streamed install.** Bru's "Pouring tree 2.3.2" output
  hints at a streaming pour (untar → write directly to cellar). malt has a
  9-step "atomic install protocol" (per `install.zig` doc comment) that
  may be moving bytes through `<prefix>/tmp` first and then renaming, which
  doubles I/O.

### 3. bru's "cold" numbers are almost certainly fake-cold (and zerobrew has its own oddity)

**bru.** Cold `tree` 0.022 s, cold `wget` 0.277 s, cold `ffmpeg` 1.182 s.
Those numbers are too low for any honest network fetch + extract + relink
on a home connection. The bench script wipes `/tmp/bru` (which is bru's
`HOMEBREW_PREFIX`) before each cold run, but bru likely keeps its bottle
download cache **outside** that prefix — probably under
`~/Library/Caches/bru` or `~/.bru`. Verify with:

```bash
find ~/Library/Caches ~/.bru ~/.cache 2>/dev/null | grep -i bru
```

If confirmed, bru is being measured as "warm-fetch + materialize" while
malt is being measured as "true cold + materialize". Not malt's fault,
but it makes the table misleading. Three ways to fix:

1. Find bru's cache path and add it to `prep_cold_bru` in `bench.sh`.
2. Pass an env var to bru that points its cache somewhere we control.
3. Add a `BENCH_NETWORK_DOWN=1` mode that runs the cold install with
   network blocked, so anything that's actually hitting the network fails
   instead of silently using a hidden cache.

**zerobrew.** Cold `wget` and cold `ffmpeg` are reported as **identical
to the millisecond** (4.927 s / 4.927 s). That's almost certainly an
artifact: either zerobrew is hitting some internal cap, our wipe isn't
clearing all of its state, or the timing capture got duplicated. Worth
re-running with a single package at a time to get a clean reading and
checking what's left under `/tmp/zb` between runs.

**nanobrew.** Cold `tree` 0.57 s, `wget` 3.20 s, `ffmpeg` 3.00 s. These
are roughly consistent with an honest network fetch, but the fact that
`ffmpeg` (much larger) is *faster* than `wget` is suspicious — possibly
a hidden cache survived. Worth checking what's left under `/tmp/nb`
between runs the same way.

In short: trust the **malt warm** and **brew cold** numbers as honest;
treat everything else with caution until §3 is closed out.

### 4. Side note: ignore the README's old numbers

The current README still shows malt cold installs in the millisecond range
(`tree` 0.015 s, `wget` 0.003 s). They don't reproduce locally — they
reproduce against **nothing** — and they're what made the regression seem
worse than it is. The refactored `benchmark.yml` on this branch sets
`BENCH_FAIL_FAST=1` so the next scheduled CI run will overwrite them with
honest numbers (or fail loudly if `malt install` is itself broken on the
runner — which would be a separate bug worth fixing on its own).

**Optimize against the table at the top of this doc, not against the README.**

## Where to look in nanobrew first

Since nanobrew is the closest peer (Zig, Homebrew-bottle-compatible, runs
on the same `/tmp/nb` in our bench) **and** it's beating malt by ~180× on
warm `tree`, it's worth diffing the install paths side by side before
guessing. Suggested entry points:

- **`/tmp/malt-bench/nanobrew/src/main.zig`** — search for `fn install` /
  `cmdInstall`. This is where the per-invocation work lives.
- **`/tmp/malt-bench/nanobrew/src/cellar/`** + **`src/linker/linker.zig`**
  — these are the equivalents of malt's `src/core/{cellar,linker}.zig`.
  The interesting question is which steps nanobrew **skips** that malt
  does on every install.
- **`/tmp/malt-bench/nanobrew/src/db/database.zig`** — nanobrew uses a
  flat JSON file (`/tmp/nb/db/state.json`), not SQLite. That alone is
  worth a few hundred ms compared to opening + transacting against a
  WAL-mode SQLite.

Concrete things nanobrew almost certainly does differently:

1. **No per-install API freshness check** — nanobrew's API client probably
   only fetches when the formula isn't on disk at all, with no TTL probe.
2. **No SQLite** — nanobrew's `state.json` is a single `read → mutate →
write` cycle, no `BEGIN/COMMIT/fsync`.
3. **No Mach-O scan when there are no Mach-O files** — nanobrew likely
   has an early-out (e.g. `if (cellar/.../bin == empty_dylib_set) skip`).
4. **Streaming pour** — direct write into Cellar without an intermediate
   `tmp/` rename.

These four together would plausibly account for the entire 1.1 s →
~6 ms gap. We should validate each before optimizing.

## Suggested next steps

In rough priority order:

1. **Profile a single warm install** of `tree` against `/tmp/mt-b` with
   `sample`, `dtruss -e`, or Instruments → time profiler. The goal is to
   find the function(s) accounting for the 1 s floor. A 5-second profile
   with `sample $(pgrep malt)` should be enough.
2. **Count network round-trips on a cold install of `wget`**. `tcpdump` or
   `dtruss -t connect` will tell us whether each bottle is opening a new
   TLS connection or reusing one. If new — fix the `HttpClient` to reuse
   connections + tokens.
3. **Audit the materialize phase** in `src/cli/install.zig` and the
   functions it calls in `src/core/{cellar,linker,store}.zig`. Specifically:
   - Are we walking every file in the bottle even when we don't need to?
   - Are we Mach-O scanning files that aren't Mach-O?
   - Are SQLite writes batched in one transaction or one per row?
4. **Confirm bru's hidden cache** so we know whether the "0.048 s cold"
   number is a fair comparison or apples-to-oranges. Update
   `prep_cold_bru` accordingly.
5. **Once #1-#3 land**, re-run `BENCH_TRUE_COLD=1 ./scripts/bench.sh` and
   record the new numbers in this doc as a "before/after" table. The CI
   workflow on `main` will then publish them automatically.

## Reproducing locally

```bash
# Full run (build + bench tree/wget/ffmpeg against all available tools)
BENCH_TRUE_COLD=1 ./scripts/bench.sh

# One package, faster iteration
BENCH_TRUE_COLD=1 SKIP_BUILD=1 ./scripts/bench.sh tree

# malt only — useful when profiling
BENCH_TRUE_COLD=1 SKIP_OTHERS=1 SKIP_BREW=1 ./scripts/bench.sh tree

# Without true-cold (cold ≈ warm because store/cache survive)
./scripts/bench.sh tree
```
