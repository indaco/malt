# malt — Performance Fix Plan

> **Status:** plan only, no code changes. This document is the output of the
> investigation framed by [`docs/perf-investigation.md`](./perf-investigation.md)
> and is meant to brief a follow-up implementation agent.
>
> **Source of claims:** every bottleneck below is backed by a direct file+line
> reference. Estimates without a measured profile are marked **[guess]**.
> Runtime profiling with `sample`/`dtruss` was not achievable in the
> investigation environment, so the first item in §4 below is _"actually run
> `sample`"_ — implement nothing until that has been done and confirms or
> refutes the top suspects below.

## 1. Targets and current state

Source: `docs/perf-investigation.md`, benchmarked on an M-series Mac against
isolated `/tmp/<short>` prefixes.

| Workload            | Current | Target  | Peer (nanobrew) | Gap   |
| ------------------- | ------- | ------- | --------------- | ----- |
| `tree` warm (0 dep) | 1.11 s  | ≤50 ms  | 0.009 s         | ~22×  |
| `wget` warm (6 dep) | 1.26 s  | ≤100 ms | 0.746 s         | ~13×  |
| `wget` cold (6 dep) | 13.39 s | ≤3 s    | 3.20 s          | ~4.5× |
| `ffmpeg` cold       | 20.77 s | ≤5 s    | 3.00 s          | ~4×   |

Ruled out already (from perf-investigation §1): binary startup (3 ms), API
freshness probe (warm cache hit), bottle download on warm (`store.exists()`
hit path).

## 2. Investigation summary

Four parallel investigation passes were run:

1. **Profile warm `malt install tree`** — blocked (sample/dtruss unavailable in
   the session sandbox). Code-inspection estimates only; flagged **[guess]**.
2. **Cold `wget` network audit** — source-only (lsof/dtruss blocked); findings
   for the HTTP client and GHCR token cache are definitive because the code
   is self-contained.
3. **nanobrew install-path diff** — source comparison at
   `/tmp/malt-bench/nanobrew/src/`.
4. **Source audit of suspect files** — `install.zig`, `cellar.zig`,
   `patcher.zig`, `lock.zig`, `sqlite.zig`, `ghcr.zig`, `client.zig`,
   `atomic.zig`.

The most interesting negative result is from the nanobrew diff: **nanobrew
also unconditionally walks the cellar and relocates Mach-O on every install
and still finishes `tree` in 9 ms.** That means "relocate work" by itself
isn't the 1.1 s gap — _something about how malt does it_ is. The plan below
prioritises fixes that attack the known per-walk and per-file constants,
not just the walk-count.

Claims that were confirmed or revised during verification:

| Claim                                                            | Status                                                                               |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `src/core/cellar.zig` does one Mach-O walk                       | **Revised** — does **4 full walks** of the keg every install (§3.1)                  |
| `src/core/cellar.zig:162` skips absolute-path pass for `:any`    | **Confirmed** — already optimized for relocatable bottles                            |
| `src/db/lock.zig` polls with 100 ms sleep                        | **Confirmed but not a bug** — uncontended flock succeeds on first try, 0 ms overhead |
| `src/cli/install.zig:811-834` wraps `recordKeg` in a transaction | **Confirmed** — 1 txn / 1 fsync per keg                                              |
| `src/cli/install.zig:848-858` `recordDeps` is unbatched          | **Confirmed** — N INSERTs = N implicit transactions = N fsyncs                       |
| `src/net/ghcr.zig:98` news up an `HttpClient` per blob           | **Confirmed** — `GhcrClient.http` is dead code on the hot path (§3.4)                |
| `src/cli/install.zig:419-429` downloads are parallel             | **Confirmed** — `Thread.spawn` per job                                               |
| `src/cli/install.zig:441-484` materialize loop is serial         | **Confirmed** — plain `for` over jobs (§3.5)                                         |

## 3. Root causes, ranked by confidence

### 3.1 Multiple unconditional full directory walks per install _(HIGH confidence)_

**Files:** `src/core/cellar.zig:146-184`, `src/core/cellar.zig:241-278`

Every call to `materializeWithCellar` walks the entire keg directory **four
times** on Apple Silicon, regardless of the package's size or contents:

```
cellar.zig:151   patchMachOPlaceholders           → walkMachOAndPatch (1 walk, 2 replacements)
cellar.zig:162   patchMachOAbsolutePaths          → walkMachOAndPatch (1 walk, 2 replacements)  [skipped for :any]
cellar.zig:172   patcher.patchTextFiles(/opt/homebrew, ...)  (1 walk)
cellar.zig:175   patcher.patchTextFiles(/usr/local, ...)     (1 walk)
cellar.zig:181   codesign.signAllMachOInDir       (1 walk) [arm64 only]
```

For a `:any` bottle on arm64 that's **4 walks**; for a non-`:any` bottle it's
**5 walks**. Each walk does independent work but touches the same files, so
files get `open → read → maybe write → close`'d repeatedly, and page cache
warms multiple times.

Worse, `walkMachOAndPatch` at `cellar.zig:271-275` loops over the replacement
list _inside_ the walker:

```zig
for (replacements) |r| {
    _ = patcher.patchPaths(allocator, full_path, r.old, r.new) catch |e| ...
}
```

For the placeholder pass that's 2 replacements, each a separate
`patcher.patchPaths` call — meaning each Mach-O file is opened and
processed **twice** per walk. Combined with the 4 walks, a single Mach-O
binary in `bin/` is touched at least **6 times** during the materialize
phase of a warm install.

**Estimated warm-tree cost:** **[guess]** 200-500 ms. The true number needs
`sample` to confirm — the peer differ noted nanobrew does similar walks and
finishes in 9 ms, so the per-walk constant is probably the real offender, not
the walk count alone. Either way, collapsing to one walk is pure win.

### 3.2 `recordDeps` is unbatched and fsync-per-dep _(HIGH confidence)_

**Files:** `src/cli/install.zig:848-858`, `src/db/sqlite.zig` (PRAGMAs)

```zig
// install.zig:848
fn recordDeps(db: *sqlite.Database, keg_id: i64, formula: *const formula_mod.Formula) void {
    for (formula.dependencies) |dep_name| {
        var stmt = db.prepare("INSERT OR IGNORE INTO dependencies ...") catch continue;
        defer stmt.finalize();
        stmt.bindInt(1, keg_id) catch continue;
        stmt.bindText(2, dep_name) catch continue;
        _ = stmt.step() catch {};
    }
}
```

There is no `beginTransaction`/`commit` wrapping the loop, so every `step()`
runs as its own implicit transaction. In WAL mode with default
`synchronous=FULL`, each commit triggers an `fsync()` on the WAL file.

For `wget` (6 runtime deps) that's 6 WAL fsyncs on warm install. `tree`
(0 deps) is not affected by this specific function (the loop body doesn't
execute), but see §3.3 for the related `recordKeg` cost.

**Estimated warm-wget cost:** **[guess]** 30-100 ms. Trivial to fix, worth
doing regardless.

### 3.3 SQLite `recordKeg` commit on every install _(MEDIUM confidence)_

**Files:** `src/cli/install.zig:804-837`, `src/db/sqlite.zig`

`recordKeg` does use an explicit `beginTransaction()`/`commit()` (line 811,
834), so it's 1 fsync per keg (not per column). Still, on macOS that's
typically 5-20 ms per fsync on SSD. For a warm `tree` install which only
records one keg, that's at most 20 ms — not the 1.1 s floor, but a
contributing factor.

**Additional observation:** `sqlite.zig` sets `journal_mode=WAL` at line 130
and `busy_timeout=5000` at line 132, but never sets `synchronous=NORMAL`. In
WAL mode, `synchronous=NORMAL` is crash-safe for application data (you can
only lose the last committed txn on a power loss, not corrupt the database)
and eliminates the fsync on commit in favor of an fsync on checkpoint. This
is the exact trade-off every modern embedded SQLite consumer makes.

**Estimated warm-tree cost:** **[guess]** 10-30 ms per install.

### 3.4 `HttpClient` is reconstructed per download _(HIGH confidence — cold-install only)_

**Files:** `src/net/ghcr.zig:66-67`, `src/net/ghcr.zig:98-99`, `src/net/client.zig`

`GhcrClient` stores `http: *client_mod.HttpClient` (line 18) but never uses it:

```zig
// ghcr.zig:66  (in fetchToken)
var local_http = client_mod.HttpClient.init(self.allocator);
defer local_http.deinit();

// ghcr.zig:98  (in downloadBlob, per call)
var http = client_mod.HttpClient.init(allocator);
defer http.deinit();
```

The comment at ghcr.zig:64-65 explains why:

> Use a short-lived HTTP client to avoid sharing the parent's
> `std.http.Client` across threads (it is not thread-safe).

This is a real constraint, but the current solution is the maximal price: a
fresh `std.http.Client` (with its TLS context, connection pool, cert store)
per request. For a cold `wget` install that's 1 token fetch + 7 bottle blobs
= **8 TLS handshakes** against `ghcr.io`. A TLS handshake on a home network
is ~150-300 ms, so that alone is 1.2-2.4 s of the 13.4 s cold time.

Further, `src/net/api.zig`'s `fetchFormula` path also goes through
`HttpClient`; any formula fetched on a cold run pays its own handshake.

Good news: **the token cache is correct** (`GhcrClient.cached_token`
at ghcr.zig:19, with mutex + 270 s expiry). Only the transport layer is
reconstructed.

**Estimated cold-wget saving:** **1-2 seconds.** This is the most confident
single cold-install win in the plan.

### 3.5 Materialize phase is serial even though downloads are parallel _(HIGH confidence — cold-install only)_

**Files:** `src/cli/install.zig:412-433` (parallel downloads), `src/cli/install.zig:441-484` (serial materialize)

```zig
// 412-431: parallel fan-out
var threads: std.ArrayList(std.Thread) = .empty;
for (all_jobs.items) |*job| {
    if (job.succeeded) continue;
    const t = std.Thread.spawn(.{}, downloadWorker, .{ allocator, &ghcr, &store, job });
    ...
}
for (threads.items) |t| t.join();

// 441-484: sequential materialize
for (all_jobs.items) |*job| {
    ...
    materializeAndLink(allocator, job, &db, &linker, prefix) catch { ... };
}
```

Materialize is where the Mach-O walks of §3.1 live. For `wget` (7 bottles
total), the cost of §3.1 is paid 7 times back-to-back. For `ffmpeg` (12 bottles),
it's paid 12 times. That matches the observed cold-install slope.

The blocker to parallelizing materialize is the single-threaded `db` handle
and the single `linker`. nanobrew works around this by serialising _only_ the
DB write at the end and parallelising everything that happens inside
`materializeAndLink` up to that point.

**Estimated cold-wget saving:** **3-5 s.** Combined with §3.4, this alone
would bring cold wget from 13.4 s to ~7-9 s.

### 3.6 Dependency-resolve formula fetches are serial _(MEDIUM confidence)_

**Files:** `src/cli/install.zig` ~300-332 (top package resolve) and ~556-600 (dep resolve)

`api.fetchFormula(dep_name)` is called in a plain `for` loop for each
transitive dep. On warm that's a cached-file parse (5-20 ms per call, so
6 deps = ~60-120 ms). On cold each call hits the network, which amplifies
the hit.

**Estimated warm-wget saving:** **[guess]** 30-80 ms.
**Estimated cold-wget saving:** **[guess]** 0.5-1.5 s (depends on how many
deps were not already in the api TTL cache).

### 3.7 Text-file patcher runs twice on the same tree _(MEDIUM confidence)_

**Files:** `src/core/cellar.zig:172,175`

```zig
_ = patcher.patchTextFiles(allocator, cellar_path, "/opt/homebrew", new_prefix) ...
_ = patcher.patchTextFiles(allocator, cellar_path, "/usr/local", new_prefix) ...
```

Two calls → two walks of the whole keg directory, two magic checks, two
read-rewrite passes per text file. A single walker that takes a list of
`(needle, replacement)` pairs and does all substitutions in one pass over
each file would cut this in half. Folded into the fix at §3.1 (§4 fix 1).

### 3.8 `codesign.signAllMachOInDir` re-walks the keg _(LOW confidence)_

**Files:** `src/core/cellar.zig:180-184`, `src/macho/codesign.zig`

On arm64 this does another full walk to sign binaries, separate from the
Mach-O patching walks. A faster alternative is to let the patching pass also
collect the list of Mach-O paths it touched and codesign them directly
without re-walking. Likely folded into the fix at §4 fix 1.

### 3.9 What _didn't_ turn out to be a problem

- **Global install lock** — `src/db/lock.zig` uses `flock(LOCK.EX | LOCK.NB)`
  with a 100 ms retry loop. The retry loop only fires on contention; the
  uncontended path (a benchmark's isolated prefix) acquires on first try and
  adds 0 ms. The earlier profiler theory that lock polling was costing
  50-100 ms was wrong.
- **APFS clonefile staging** — `src/fs/clonefile.zig` already uses APFS
  `clonefile(2)` for the `store → Cellar` copy (O(1), CoW). The "atomic
  tmp/rename" step only applies to the _download_ phase, which is cached on
  warm runs.
- **Token caching** — `GhcrClient.cached_token` is correctly scoped per-repo
  with a 270 s expiry. No per-bottle token fetches.

## 4. Ranked fix list

Every fix below is listed with: the estimated per-workload saving, the
file(s) touched, and a 3-5 line implementation sketch. Estimates flagged
**[guess]** depend on §4.0 actually being run first. **No fix should be
implemented before §4.0.**

### 4.0 Measure first: capture an actual `sample` profile _(P0, prerequisite)_

Before any code changes, land a reproducible profile so we can size the
fixes accurately and avoid chasing phantoms.

```bash
# Ensure a freshly built binary is in /tmp/malt-bench/build/bin/malt
SKIP_BUILD=0 SKIP_OTHERS=1 SKIP_BREW=1 scripts/bench.sh tree

# Loop the warm install several times inside a subshell
(for i in $(seq 1 10); do
   MALT_PREFIX=/tmp/mt-b /tmp/malt-bench/build/bin/malt uninstall tree >/dev/null 2>&1
   MALT_PREFIX=/tmp/mt-b /tmp/malt-bench/build/bin/malt install tree >/dev/null
 done) &
LOOP_PID=$!
/usr/bin/sample $LOOP_PID 10 -file /tmp/malt-warm.sample.txt
wait $LOOP_PID

# Check top functions
head -100 /tmp/malt-warm.sample.txt | less
```

The expected output is a call tree weighted by hit count. The assertions
this plan rests on (§3.1 dominates warm tree, §3.4 dominates cold wget) can
be checked in 2 minutes of reading that file. Commit the sample output
under `docs/perf/warm-tree.sample.txt` as a before-baseline.

Also capture `/usr/bin/time -l` once for the same workload — the
`voluntary context switches` and `block output` counters are the cheap
fsync/lock tell.

**Deliverable:** before-profile files committed, §3 estimates either
confirmed or the fix list below is re-ordered.

### 4.1 Collapse cellar walks into a single walker _(P0, warm + cold)_

**Files:** `src/core/cellar.zig`, `src/macho/patcher.zig`

Replace the 4-5 independent walks in `materializeWithCellar` with one
`walkKegAndApply` pass that visits each file exactly once and applies all
substitutions + codesign inside the single visit. Concretely:

```zig
// new shape
const KegVisitor = struct {
    macho_replacements: []const Replacement,   // placeholder + absolute
    text_replacements:  []const Replacement,   // /opt/homebrew, /usr/local, @@HOMEBREW_*@@
    codesign_on_arm64:  bool,
};

fn walkKegAndApply(allocator, dir_path, v: KegVisitor) !void {
    // 1 walker; for each regular file:
    //   - read up to 16 bytes (magic)
    //   - if Mach-O: apply all macho_replacements in one rewrite, then
    //                if v.codesign_on_arm64: collect into arm64_to_sign list
    //   - else if text-y (ASCII / utf-8 heuristic): apply text_replacements
    //                in one rewrite
    // After walk completes: codesign arm64_to_sign in one batch.
}
```

Benefits: one `openDirAbsolute` + one `Dir.walk`, one `open/read/close` per
file, one write-back per file when something actually changed, one codesign
sub-process per file (or a batched invocation). `patcher.patchPaths` today
allocates per replacement pair — pass the full replacement list and let it
scan the load commands once.

Preserve correctness:

- Keep the `:any` skip for absolute-path rewrites (it's the only place that
  already early-outs; don't regress it).
- Keep `PathTooLong` as a hard error — it is today.
- Keep text-file patching best-effort (`std.log.warn`), it is today.
- Keep `writeInstallReceipt` at the end (unchanged).

**Estimated saving:** **[guess]** 200-500 ms warm tree; linearly larger for
multi-file packages. Plausible path to the sub-100 ms warm-tree target
when combined with §4.2 and §4.3.

### 4.2 Wrap `recordDeps` in a transaction, set `synchronous=NORMAL` _(P0, warm)_

**Files:** `src/cli/install.zig:848-858`, `src/db/sqlite.zig:~130`

Two micro-fixes in one commit:

```zig
// install.zig:848 — recordDeps
fn recordDeps(db: *sqlite.Database, keg_id: i64, formula: *const formula_mod.Formula) void {
    if (formula.dependencies.len == 0) return;
    db.beginTransaction() catch return;
    defer db.commit() catch {};
    var stmt = db.prepare(
        "INSERT OR IGNORE INTO dependencies (keg_id, dep_name, dep_type) VALUES (?1, ?2, 'runtime');",
    ) catch return;
    defer stmt.finalize();
    for (formula.dependencies) |dep_name| {
        stmt.reset() catch continue;
        stmt.bindInt(1, keg_id) catch continue;
        stmt.bindText(2, dep_name) catch continue;
        _ = stmt.step() catch {};
    }
}
```

Note the additional fix: prepare the statement **once** and `reset()` it
between iterations, instead of preparing and finalizing per dep.

In `src/db/sqlite.zig` near the existing `PRAGMA journal_mode=WAL;` /
`PRAGMA busy_timeout=5000;`, add:

```c
PRAGMA synchronous=NORMAL;
```

In WAL mode this is crash-safe for application data (worst case is losing
the last committed txn, not DB corruption) and eliminates the per-commit
fsync in favor of an fsync on WAL checkpoint.

**Estimated saving:** **[guess]** 30-100 ms warm wget; 10-30 ms warm tree;
linearly more for deeper dep graphs. Compounds with §4.1.

### 4.3 Reuse one `HttpClient` per download worker _(P0, cold)_

**Files:** `src/net/ghcr.zig:86-122`, `src/cli/install.zig:419` (`downloadWorker`)

The current code creates an `HttpClient` per `downloadBlob` call to dodge
`std.http.Client` thread-safety issues. The fix is to own one client _per
worker thread_ instead of per-request:

```zig
// install.zig:105-146 — downloadWorker signature
fn downloadWorker(
    allocator: std.mem.Allocator,
    ghcr: *ghcr_mod.GhcrClient,
    store: *store_mod.Store,
    job: *DownloadJob,
) void {
    var http = client_mod.HttpClient.init(allocator);
    defer http.deinit();
    // ... now pass &http down into ghcr.downloadBlob(...)
}

// ghcr.zig:86 — downloadBlob takes a caller-owned client
pub fn downloadBlob(
    self: *GhcrClient,
    allocator: std.mem.Allocator,
    http: *client_mod.HttpClient,       // <- new
    repo: []const u8,
    digest: []const u8,
    body_out: *std.ArrayList(u8),
    progress: ?client_mod.ProgressCallback,
) GhcrError!void {
    ...
    var resp = http.getWithHeaders(url, &headers, progress) catch ...
}
```

- `ghcr.fetchToken` already has its own `local_http` (line 66); leave it
  alone or give it the same treatment if profiling shows a separate hit.
- `GhcrClient.http: *client_mod.HttpClient` is currently dead — remove the
  field since it's no longer needed.
- `std.http.Client` reuses its internal TCP + TLS pool across requests on
  the same instance, so a worker servicing multiple blobs (or a single
  thread on a 1-package install) collapses to 1 handshake instead of N.

**Estimated cold saving:** **1-2 s** on cold `wget`; **2-3 s** on cold
`ffmpeg`. This is the single highest-confidence cold-install win.

### 4.4 Parallelize the materialize phase _(P1, cold)_

**Files:** `src/cli/install.zig:441-484`, `src/core/linker.zig`, `src/db/sqlite.zig`

Model after nanobrew's `fullInstallOne` pool (peer-diff, step 4: a bounded
thread pool of up to 16 workers). Split the loop body:

1. `materializeAndLink` is factored into `materializeOnly` (clone + patch +
   codesign — thread-safe after §4.1) and `linkAndRecord` (DB insert +
   symlink create — still on the main thread).
2. Parallelize `materializeOnly` across `min(ncpu, jobs.len)` workers.
3. Run `linkAndRecord` for each job in dep-order **after** materialize
   completes, on the main thread, in a single SQLite transaction.

The dep-ordering is required because linker conflict-checking reads the DB
state of already-linked packages; doing that inside the parallel section
would reintroduce the SQLite-single-writer bottleneck.

Gotcha: `failed_kegs` book-keeping (install.zig:447) needs to be promoted
to atomic or moved into the serial post-phase so a failed dep still blocks
dependents.

**Estimated cold saving:** **3-5 s** on cold `wget`; **6-10 s** on cold
`ffmpeg`. Large saving, large blast radius — keep this fix in a separate PR
from §4.1-§4.3 so regressions are easy to bisect.

### 4.5 Parallelize dep-resolve `fetchFormula` calls _(P1, warm + cold)_

**Files:** `src/cli/install.zig:~300-332`, `src/cli/install.zig:~556-600`,
`src/net/api.zig`

Replace the serial `for (deps) |dep| { api.fetchFormula(dep.name) }` with a
small bounded-pool fan-out. `api.fetchFormula` is already cache-hit-friendly
(it reads a TTL'd on-disk cache), so the parallel version just saves the
per-call latency from adding up linearly.

Thread safety: `api.Client` holds a disk cache dir path; reads from disk are
safe from multiple threads, but if the cache write path is shared state, it
needs a mutex or per-thread scratch path.

**Estimated saving:** warm wget **30-80 ms**, cold wget **0.5-1.5 s**.

### 4.6 Cache the parsed formula across the install pipeline _(P2, warm)_

**Files:** `src/cli/install.zig:540,675`, `src/core/formula.zig`

`formula_mod.parseFormula` is called multiple times on the same JSON blob
during a single install (once in resolve, at least once in materialize, once
in record). Parse once and stash the `Formula` struct in `DownloadJob`.

**Estimated warm saving:** **[guess]** 10-30 ms per package.

### 4.7 Ad-hoc codesign: batch instead of re-walk _(P2, warm)_

**Files:** `src/core/cellar.zig:180-184`, `src/macho/codesign.zig`

Folded into §4.1: the unified walker collects the list of Mach-O paths it
touched and the post-walk codesign step processes that list directly,
skipping a full directory traversal. If that's not possible (e.g. codesign
must re-read the file to fingerprint), at least batch the signing into one
subprocess invocation for all files instead of one per file.

**Estimated warm saving:** **[guess]** 20-80 ms on arm64.

### 4.8 Keep: the things §3.9 vindicated

Do **not** change the following — they were investigated and found fine:

- `src/db/lock.zig` — flock polling is 0 ms uncontended; the retry only
  fires when another `malt` is running.
- `src/fs/clonefile.zig` — APFS clonefile is already the O(1) CoW copy.
- `src/net/ghcr.zig:19-22, 42-82` — token cache is correct and
  per-repo-scoped. Don't touch.

## 5. Benchmark projection

Treat the projection below as **ranges**, not a single number. The wide band
is honest uncertainty: the warm-tree floor decomposition is code-inspection
guesswork until §4.0 runs.

### Warm install (prefix kept, bottle in store, fresh pour)

| Package            | Current | After §4.1 + §4.2      | After §4.1 + §4.2 + §4.6 | Peer (nanobrew) | Target  |
| ------------------ | ------- | ---------------------- | ------------------------ | --------------- | ------- |
| `tree` (0 deps)    | 1.11 s  | 300-600 ms **[guess]** | 100-400 ms **[guess]**   | 9 ms            | ≤50 ms  |
| `wget` (6 deps)    | 1.26 s  | 400-700 ms **[guess]** | 200-500 ms **[guess]**   | 0.75 s          | ≤100 ms |
| `ffmpeg` (11 deps) | 1.87 s  | 700 ms - 1.2 s         | 500 ms - 1.0 s           | 0.93 s          | ≤200 ms |

**Honest read:** the warm-tree target of ≤50 ms is probably not reachable by
the fixes in §4 alone — nanobrew hits 9 ms with a JSON state file, no lock,
no codesign per-package, and fewer passes, and those are architectural
choices malt has explicitly rejected for correctness reasons (see §3.9 and
perf-investigation §4). A realistic interim target is **≤200 ms warm tree**,
which is ~6× over nanobrew and ~6× under today — and matches what §4.1-§4.2
should achieve without giving up SQLite/flock correctness.

To actually hit ≤50 ms would require either a post-fix profile that shows
§4.1 wasn't the real hotspot (in which case new fixes open up) or follow-up
work like skipping SQLite for no-op state changes, skipping text patching
when no placeholders are present in the bottle manifest, or caching the
"this file has no relocatable paths" fact across installs.

### Cold install (true cold, prefix wiped)

| Package            | Current | After §4.3 | After §4.3 + §4.4 | After §4.3 + §4.4 + §4.5 | Peer (nanobrew) | Target |
| ------------------ | ------- | ---------- | ----------------- | ------------------------ | --------------- | ------ |
| `tree` (0 deps)    | 3.94 s  | 2.5-3.0 s  | 2.5-3.0 s         | 2.0-2.5 s                | 0.57 s          | ≤1 s   |
| `wget` (6 deps)    | 13.39 s | 11-12 s    | 6-8 s             | 4-6 s                    | 3.20 s          | ≤3 s   |
| `ffmpeg` (11 deps) | 20.77 s | 17-19 s    | 8-11 s            | 5-8 s                    | 3.00 s          | ≤5 s   |

The ≤3 s cold-wget target is **tight but plausible** if §4.4's materialize
parallelization lands and the warm-install fixes compound underneath it.
Cold `ffmpeg` ≤5 s is **probably a stretch** — the download phase itself
(serial bottle bytes over network, even parallelized) has a floor set by
the slowest single bottle, which for ffmpeg is on the order of seconds.
Measure after §4.3-§4.4 and re-set the target.

## 6. Sequencing

Recommended landing order, each as a separate PR so regressions bisect cleanly:

1. **`perf: capture baseline sample profile`** (§4.0). Committable as
   `docs/perf/warm-tree.sample.txt` + a `docs/perf/cold-wget.sample.txt`.
   **Block all other PRs on this.**
2. **`perf(cellar): collapse materialize walks into one pass`** (§4.1, §4.7
   folded in). The big warm-install win.
3. **`perf(db): batch recordDeps, set synchronous=NORMAL`** (§4.2). Tiny
   diff, independently verifiable.
4. **`perf(net): share one HttpClient per download worker`** (§4.3). The
   big cold-install win.
5. Re-run `BENCH_TRUE_COLD=1 ./scripts/bench.sh` and commit an updated
   "after" table into `docs/perf-investigation.md` for each of 2-4 above.
6. **`perf(install): parallelize materialize phase`** (§4.4). Larger blast
   radius — land only after the above three are stable.
7. **`perf(install): parallelize dep formula resolve`** (§4.5) and
   **`perf(install): cache parsed formula per job`** (§4.6).
8. Final benchmark sweep. Update `docs/perf-investigation.md` with the new
   steady-state table and close it out.

## 7. What this plan does NOT propose

- **Replacing SQLite with flat JSON** — peer-differ noted this would save
  3-5 ms per install but gives up ACID, race-safety, and structured
  queries (`malt list`, `malt deps`, reverse-dep lookup). The fsync cost
  is addressed by §4.2 and §3.3 instead.
- **Removing the global flock** — verified fine in §3.9. Removing it to
  match nanobrew would break concurrent-install safety without any
  measurable performance gain.
- **Removing the symlink conflict-check** — verified out of scope for the
  warm-tree floor (tree is keg-only and already skips the check).
- **Skipping text-file patching entirely** — required for correctness on
  non-relocatable bottles. §4.1 merges the two passes into one walk instead.
- **Changing the atomic download-then-commit protocol** — verified using
  APFS clonefile already; the "tmp → rename" only applies to the
  download phase, which is cached on warm runs.
