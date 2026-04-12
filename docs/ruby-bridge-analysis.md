# Ruby Bridge Analysis: Executing Homebrew `post_install` Blocks in malt

**Status:** Research / Design proposal
**Scope:** Evaluation of strategies for running Homebrew formula `post_install` Ruby DSL blocks inside malt (macOS-only, Zig 0.15.x, single ~3 MB binary, sub-millisecond cold start).
**Target audience:** malt maintainers deciding whether and how to close the current `post_install_defined` coverage gap.

---

## 1. Executive Summary

malt currently **refuses to install** any formula whose Homebrew JSON manifest carries `post_install_defined: true`. The refusal is hard-wired at two sites — `src/cli/install.zig:695` raises `InstallError.PostInstallUnsupported`, and `src/cli/migrate.zig:230–235` returns `.skipped_post_install` — and the user is told to fall back to `brew install`. Based on the homebrew-core landscape, this disqualifies roughly **15–20% of formulae** (~1,000–1,400 packages) from the native install path.

This document evaluates five strategies for closing that gap:

1. **mruby embedded** via Zig `@cImport` (small static lib, real Ruby VM)
2. **CRuby `libruby` linked** (reference Ruby, statically or dynamically)
3. **Native Zig DSL interpreter** (hand-written parser + tree-walking interpreter for a Ruby subset)
4. **lib-ruby-parser (Rust) via FFI** (AST parsing only, interpreter still required)
5. **Subprocess delegation** to a system Ruby

**Recommendation — ranked:**

1. **Primary: Native Zig DSL interpreter (Option 3).** It is the only option that preserves every one of malt's product promises — single ~3 MB binary, sub-ms cold start, zero external toolchains, trivially universal-buildable. The `post_install` workload is a small, empirically-bounded DSL (60–80 primitives), not "all of Ruby," which makes a hand-rolled interpreter tractable. Expected coverage after Phases 0–3: **~65–75% of `post_install`-defining formulae** (4–6 weeks of focused work); Phases 4–5 push this to **~85–90%** (3–4 more weeks). Everything above that tier degrades gracefully to the existing refusal-plus-brew-fallback behavior.

2. **Fallback if coverage spike disproves the DSL-subset thesis: mruby (Option 1).** If a homebrew-core scan shows that real `post_install` blocks use significantly more Ruby surface than expected (blocks, metaprogramming, user-defined helpers, etc.), mruby gives real Ruby semantics at ~500 KB–1.5 MB binary cost and ~3–8 ms per invocation. The deal-breaker risk is DSL-stdlib coverage: `Pathname`, `FileUtils`, `Process`, and Homebrew's `Formula` helpers all need hand-written Zig shims because mruby ships none of them.

3. **Stopgap: Subprocess to Homebrew's Ruby (Option 5), behind an opt-in flag.** Good for unblocking power users during Phase 0–1 of Option 3. Not a long-term story because Apple is removing `/usr/bin/ruby` and malt cannot require users to install Homebrew to run malt.

4. **Rejected: lib-ruby-parser via Rust FFI (Option 4).** Introduces a second toolchain (Rust/cargo) in a project that currently has zero external build dependencies, saves only the parser portion of Option 3's work (~30%), and forces every release to clear "Rust built for both arches" gates.

5. **Rejected: CRuby libruby (Option 2).** Binary size explodes from 3 MB to ~13–20 MB (a 4–7× regression on malt's headline metric), cross-compiling CRuby through `zig build universal` is hostile, runtime init is 20–80 ms per invocation (two orders of magnitude over the sub-ms cold-start claim), and a dynamic link against macOS system Ruby depends on a framework Apple has deprecated.

**Next concrete step, before any code is written:** a one-day spike that clones homebrew-core and produces a histogram of method calls and AST node kinds found inside `def post_install ... end` blocks across all ~1,000–1,400 defining formulae. That histogram collapses every uncertainty band in this document and tells us unambiguously whether Option 3 is a weekend project or a multi-month effort.

---

## 2. Context

### 2.1 The current gap

Today's refusal path is minimal:

- **`src/core/formula.zig:31`** — the `Formula` struct carries a `post_install_defined: bool` field, populated at `src/core/formula.zig:121` from the Homebrew API JSON.
- **`src/cli/install.zig:689–699`** — the install command raises `InstallError.PostInstallUnsupported` before dependency resolution if the flag is set.
- **`src/cli/migrate.zig:230–236`** — the migrate command returns `.skipped_post_install`, leaving the formula registered under Homebrew rather than moving it to malt.

malt never parses the formula's Ruby source. It only consumes the pre-baked JSON manifest from Homebrew's API. Adding a `post_install` execution path is therefore greenfield — there is no parser, no runtime, no DSL dispatch layer to extend.

### 2.2 Architectural constraints

Any solution must live inside the envelope malt has publicly committed to:

- **Single binary, ~3 MB stripped.** The README headlines this number. A 30% regression is noticeable; a 4× regression is a different product.
- **Sub-millisecond cold start** for `malt --version`-class commands. Adding a runtime that runs at startup, even just to register symbols, is a direct threat.
- **macOS-only, Apple Silicon + Intel.** `build.zig` has a `universal` step that builds `aarch64-macos` and `x86_64-macos` and `lipo`s them. Any new dependency must cross-compile from a single maintainer machine.
- **Zero external build toolchains.** `build.zig.zon` has no dependencies; `vendor/` contains only the SQLite amalgamation; `c/` contains only `clonefile.h`. Introducing `cargo`, `autoconf`, or `rake` is a one-way door for project philosophy.
- **Existing `brew fallback` is the graceful degradation target.** malt already knows how to hand off to Homebrew for unsupported cases. That path should remain the ceiling for failure modes — we are strictly looking to reduce how often it triggers.

### 2.3 The `post_install` workload is small

Homebrew `post_install` blocks are empirically tiny. A typical block is 2–15 lines long and does one of: create a config file in `etc`, symlink a helper binary, drop files into `var/lib/foo`, or run `foo --rebuild-cache` once. The DSL surface area used is bounded — roughly 30–50 distinct methods across `Pathname`, `FileUtils`, `File`, `ENV`, `Formula`, and Homebrew's UI helpers (`ohai`/`opoo`/`odie`). This shapes every conclusion below: we are not building "a Ruby" — we are building "a DSL executor for the subset of Ruby that Homebrew formulae actually use in `post_install`."

---

## 3. Comparison Matrix

All numbers are order-of-magnitude estimates targeting macOS 14 on Apple Silicon, release build with LTO and stripping. Ranges reflect confidence — wide bands mean a real measurement pass would tighten them significantly. Tilde (~) marks numbers derived from general knowledge of the runtime rather than measurement.

| Axis                                      | 1. mruby static                                                          | 2. CRuby libruby                             | 3. Native Zig DSL                           | 4. lib-ruby-parser (Rust FFI)    | 5. Subprocess to system Ruby             |
| ----------------------------------------- | ------------------------------------------------------------------------ | -------------------------------------------- | ------------------------------------------- | -------------------------------- | ---------------------------------------- |
| **Binary size delta**                     | ~0.8–1.5 MB                                                              | ~10–15 MB static / 0 MB dynamic + system dep | ~30–80 KB                                   | ~2.5–4 MB (parser only)          | 0 MB                                     |
| **Cold-start cost (feature unused)**      | ~0.05–0.15 ms                                                            | Static ~2–8 ms / Dynamic ~15–40 ms           | ~0.005–0.02 ms                              | ~0.1–0.3 ms                      | 0 ms                                     |
| **Per-invocation runtime init**           | ~1–3 ms                                                                  | ~20–80 ms                                    | 0 ms                                        | ~0.2–0.5 ms                      | ~30–120 ms (fork + exec + ruby boot)     |
| **Per-invocation parse**                  | ~0.5–2 ms/KB                                                             | ~1–4 ms/KB                                   | ~0.05–0.3 ms/KB                             | ~0.1–0.4 ms/KB                   | included                                 |
| **Per-invocation dispatch**               | ~0.2–1 ms/op                                                             | ~0.1–0.5 ms/op                               | ~0.01–0.05 ms/op                            | N/A (needs own interp)           | included                                 |
| **Total per invocation (~1 KB, ~10 ops)** | ~3–8 ms                                                                  | ~25–100 ms                                   | ~0.2–0.8 ms                                 | ~1–3 ms + interp cost            | ~35–140 ms                               |
| **Steady-state RSS (runtime)**            | ~1–3 MB                                                                  | ~8–20 MB                                     | ~50–200 KB                                  | ~2–5 MB                          | 0 (child proc: ~15–30 MB)                |
| **In-process parallelism**                | Per-thread VM (no GIL)                                                   | GIL — effectively single-thread              | Trivial                                     | Parser pure; interp is your call | Unlimited across processes               |
| **Homebrew DSL compat**                   | Partial — needs Zig shims for `Pathname`/`FileUtils`/`Process`/`Formula` | Full — all CRuby semantics                   | Bounded — whitelisted subset                | Parse-full, exec-none            | Full if Ruby is present                  |
| **Build complexity**                      | 4/5 (mruby's rake, vendored lib per arch)                                | 5/5 (autoconf, cross-compile hostile)        | 1/5 (just Zig source)                       | 5/5 (adds Rust/cargo toolchain)  | 1/5 (none)                               |
| **Maintenance surface**                   | 3/5                                                                      | 4/5                                          | 4/5 (DSL evolves, tracked as UnknownMethod) | 3/5                              | 5/5 (user's runtime, out of our control) |
| **Testability**                           | 3/5                                                                      | 2/5 (GC state leaks)                         | 5/5 (pure Zig unit tests)                   | 4/5                              | 2/5                                      |
| **Debuggability**                         | 3/5 (line numbers, exceptions)                                           | 4/5 (real traces)                            | 5/5 (Zig errors, we control messages)       | 3/5 (FFI memory bugs)            | 3/5 ("what Ruby version?")               |
| **Preserves sub-ms cold start?**          | Yes, with caveat (~30–50% binary growth)                                 | **No** — init alone is 20–80 ms              | **Yes**                                     | Yes                              | Yes                                      |
| **Preserves ~3 MB binary?**               | Marginal (3.5–4.5 MB)                                                    | **No** (~13–20 MB)                           | **Yes** (3.05 MB)                           | Marginal (5.5–7 MB)              | Yes                                      |
| **Preserves "no external toolchain"?**    | Partial (C compile from Zig works; mruby's rake is avoidable)            | **No**                                       | **Yes**                                     | **No** (Rust/cargo)              | Yes                                      |

---

## 4. Per-Approach Deep Dive

### 4.1 Option 1 — mruby embedded via `@cImport`

**What it is.** mruby is a small, embeddable Ruby implementation (originally by Matz, 2012) designed for exactly this kind of host: explicit VM state (`mrb_state*`), clean C API, ~400 KB minimal static library, ISO/IEC 30170 core-language conformant. Current line is the 3.3.x series, actively maintained, used by H2O and game engines historically.

**Integration shape.** Vendor the source tree under `vendor/mruby/`, compile its ~150 `.c` files directly from `build.zig` via `addCSourceFiles` (the same pattern already used for SQLite). Avoid mruby's rake-based build by enumerating sources; this sidesteps needing a maintainer-side Ruby. Zig-side boundary is ~100 lines:

```zig
// src/core/ruby_mruby.zig
const c = @cImport({
    @cInclude("mruby.h");
    @cInclude("mruby/compile.h");
});

pub const Runtime = struct {
    mrb: *c.mrb_state,

    pub fn init() !Runtime {
        const mrb = c.mrb_open() orelse return error.OutOfMemory;
        return .{ .mrb = mrb };
    }

    pub fn deinit(self: *Runtime) void {
        c.mrb_close(self.mrb);
    }

    pub fn eval(self: *Runtime, source: []const u8) !void {
        const ctx = c.mrbc_context_new(self.mrb);
        defer c.mrbc_context_free(self.mrb, ctx);
        _ = c.mrb_load_nstring_cxt(self.mrb, source.ptr, @intCast(source.len), ctx);
        if (self.mrb.*.exc != null) {
            self.mrb.*.exc = null;
            return error.RuntimeFailed;
        }
    }
};
```

The real work is **not** the skeleton. It is binding ~40 Homebrew DSL methods (`bin`, `etc`, `HOMEBREW_PREFIX`, `Pathname#/`, `.install`, `inreplace`, `system`, `FileUtils.*`, `ohai`/`opoo`/`odie`) as Zig-implemented builtins registered via `mrb_define_method`. Estimate: **1,500–3,000 LoC** of glue.

**Homebrew DSL compatibility.** mruby ships _no_ Ruby stdlib — the methods Homebrew formulae rely on don't exist until you add them:

- `Pathname` — community mrbgem `mruby-pathname`, partial
- `FileUtils` — `mruby-fileutils`, partial
- `system`, backticks — `mruby-process`, mostly works
- `require` — no load-path mechanism; you must preload as mrbgems
- UTF-8 strings — opt-in via `MRB_UTF8_STRING` (adds ~15% size)

You would be writing a **Homebrew compatibility layer on top of mruby**, not "running Ruby." Every surprise in a real formula is one or more new Zig shims.

**Build/platform concerns.** Minimal mruby static lib is ~400–700 KB on arm64; with the stdlib gems you need for Homebrew compat expect 1.2–1.8 MB. Universal binary doubles that. This pushes malt from ~3 MB to **~4–4.5 MB stripped** — a 30–50% size regression. Cross-compile is fine because the C compile is driven by Zig.

**Verdict.** The technically cleanest real-Ruby option. Deal-breaker risk is the long tail of Homebrew formulae that assume CRuby stdlib semantics; every surprise costs a shim. Best treated as the fallback option if the Option 3 coverage spike shows the DSL-subset thesis doesn't hold. Budget 2–4 weeks for initial viable coverage of common formulae.

### 4.2 Option 2 — CRuby libruby linked (static or dynamic)

**What it is.** The reference Ruby implementation. Embedding means linking against `libruby.{dylib,a}` and driving the VM via `ruby_init()`, `ruby_init_loadpath()`, `rb_eval_string_protect()`, `ruby_cleanup()`. The Zig glue itself is almost identical to Option 1 — all the difficulty is elsewhere.

**Dynamic against system Ruby — non-viable.** macOS ships `/usr/bin/ruby` 2.6.x from a framework Apple has marked deprecated since Catalina (2019). It is still present on current macOS releases but is explicitly slated for removal. Building malt on top of it is building on sand on a 1–3 year horizon.

**Static linking a vendored CRuby — buildable but hostile.** CRuby's `autoconf` + `make` build system probes ~200 headers, generates code at build time, assumes GNU make idioms, and does not cross-compile cleanly. You would be:

1. Vendoring a ~30 MB Ruby source tree under `vendor/ruby/`.
2. Running `./configure && make` via `b.addSystemCommand` — re-introducing `sh` and `make` as build dependencies.
3. Linking the resulting `libruby-static.a` (~10 MB) plus `libiconv`, `libz`.
4. Running `zig build universal` from a single maintainer machine, which means Ruby's `configure` must cross-compile arm64↔x86_64 — an uncertain proposition.

**Binary size.** Static CRuby 3.3 on arm64 is **~10–15 MB after strip+LTO**, plus you need the Ruby stdlib `.rb` files bundled as a tarball-in-binary (~3–5 MB compressed) or installed alongside. malt goes from ~3 MB to **~13–20 MB** — a 4–7× regression that contradicts the headline product claim.

**Runtime cost.** `ruby_init` + `ruby_init_loadpath` is **~20–80 ms** on Apple Silicon — two orders of magnitude over malt's sub-ms cold-start ceiling. Even lazy-loaded (only when a `post_install` block is about to run), the first invocation in a malt run pays the full tax. The GIL prevents in-process parallelism across formulae.

**ABI stability.** CRuby does **not** guarantee ABI stability across minors (3.2 → 3.3 → 3.4). Every Ruby bump is a potential `@cImport` rewrite. Static linking sidesteps the dylib-swap case but leaves you responsible for patching CRuby yourself.

**Licensing.** Dual-licensed Ruby License / BSD-2-Clause. Permissive, compatible with a single-binary distribution. Include notices. Not a blocker.

**Verdict.** Maximum compatibility at the cost of everything that makes malt malt. Size, startup, build complexity, and toolchain requirements all land on the wrong side of malt's product promises. **Rule out** as a baseline path. Could theoretically ship as an optional `malt-full` distribution variant, but that is a different product.

### 4.3 Option 3 — Native Zig DSL interpreter (recommended)

**What it is.** Skip Ruby runtimes entirely. Write a small recursive-descent parser and tree-walking interpreter in Zig for the subset of Ruby that `post_install` blocks actually use. No `@cImport`, no vendored runtime, no external toolchain. This is the option most aligned with malt's existing architecture.

**The subset.** Based on a survey of Homebrew DSL conventions, the workload covers roughly 60–80 primitives:

- **Pathname operations** — `/` (join), `to_s`, `mkpath`, `chmod`, `write`, `read`, `exist?`, `directory?`, `file?`, `symlink?`, `children`, `basename`, `dirname`, `make_symlink`, `install_symlink`
- **FileUtils** — `cp`, `cp_r`, `mv`, `rm_rf`, `rm_f`, `ln_sf`, `install`, `touch`, `chmod`, `chown`, `mkdir_p`
- **String/IO** — `File.write`, `File.read`, `gsub`, `sub`, `chomp`, `strip`, `split`, string interpolation (`#{...}`)
- **Process** — `system` with literal or Pathname args, `Utils.popen_read`, backticks
- **Formula context** — `bin`, `sbin`, `lib`, `libexec`, `include`, `share`, `pkgshare`, `etc`, `var`, `opt_prefix`, `prefix`, `buildpath`, `HOMEBREW_PREFIX`, `HOMEBREW_CELLAR`, `ENV[...]=`
- **UI** — `ohai`, `opoo`, `odie` (map to existing `src/ui/output.zig`)
- **`inreplace`** — literal form and regex form (needs a small regex engine or vendored libc regex)
- **Control flow** — postfix `if`/`unless`, minimal `.each { |x| single-statement }`, `begin/rescue` (single-block form)

No metaprogramming. No `method_missing`. No eigenclasses. No `require`. No `Proc.new`. No blocks beyond `inreplace do |s| s.gsub!(...) end` and `Dir.glob(...).each`.

**Integration shape.**

```zig
// src/core/ruby_dsl/ast.zig
pub const Node = union(enum) {
    str_lit: []const u8,
    int_lit: i64,
    ident: []const u8,           // bin, etc, HOMEBREW_PREFIX
    method_call: struct {
        receiver: ?*Node,
        name: []const u8,
        args: []*Node,
        block: ?*Block,
    },
    assign: struct { name: []const u8, value: *Node },
    path_join: struct { lhs: *Node, rhs: *Node }, // Pathname / "foo"
    string_interp: []InterpPart,
    seq: []*Node,
};

// src/core/ruby_dsl/interp.zig
pub const Interp = struct {
    arena: std.heap.ArenaAllocator,
    prefix: []const u8,          // HOMEBREW_PREFIX
    formula_prefix: []const u8,  // e.g. /opt/homebrew/Cellar/foo/1.2.3
    env: std.StringHashMap(Value),

    pub fn eval(self: *Interp, source: []const u8) !void {
        var p = Parser.init(self.arena.allocator(), source);
        const prog = try p.parseProgram();
        _ = try self.evalNode(prog);
    }

    fn dispatch(self: *Interp, mc: MethodCall) !Value {
        if (std.mem.eql(u8, mc.name, "mkpath"))    return self.builtinMkpath(mc);
        if (std.mem.eql(u8, mc.name, "chmod"))     return self.builtinChmod(mc);
        if (std.mem.eql(u8, mc.name, "system"))    return self.builtinSystem(mc);
        if (std.mem.eql(u8, mc.name, "inreplace")) return self.builtinInreplace(mc);
        if (std.mem.eql(u8, mc.name, "install"))   return self.builtinInstall(mc);
        // ... ~60 more
        return error.UnknownMethod;
    }
};
```

No changes to `build.zig` beyond new source files under `src/core/ruby_dsl/`. Universal build is free. No vendored libs. No new `build.zig.zon` dependencies.

**Architectural invariants to bake in from day one:**

- **Two-pass execution.** Parse to AST, then run a _static verification pass_ that rejects any node outside the current tier _before_ any side effects are executed. Half-run `post_install` blocks are the worst possible failure mode — they leave a half-configured keg behind with no recovery path. Verification-first means malt either runs the whole block or falls through cleanly to the refusal path.
- **Deterministic Pathname resolution.** All `bin`, `etc`, `var`, `prefix`, etc. resolve at interpreter-construction time from the formula's cellar path, not lazily. Removes a class of "which keg am I in?" bugs.
- **Sandboxed environment.** `system` calls run with `HOMEBREW_PREFIX`, `HOMEBREW_CELLAR`, `PATH` pre-set from malt's store layout. No ambient environment leakage.
- **Graceful fallback.** Any `UnknownMethod`, `UnsupportedNode`, or parse error falls through to the existing `PostInstallUnsupported` path, which in turn can shell out to `brew postinstall <formula>` for full compatibility. We are strictly improving on the current refusal behavior — never regressing it.

**Phased rollout.**

| Phase                                        | Duration  | Scope                                                                                                                                                                                                                   | Est. coverage |
| -------------------------------------------- | --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------- | --------------------------------------------------- | ------- |
| **0 — Parser + AST + verification**          | 1–2 weeks | Recursive-descent Ruby-subset parser (~800–1,200 LoC), AST types, static verification pass, fallback wiring. Does not execute anything yet.                                                                             | 0% (infra)    |
| **1 — Trivial tier**                         | ~1 week   | `Pathname#/`, `.install`, `.install_symlink`, `mkdir_p`, `touch`, `rm_rf`, `chmod`, `File.write`, `ENV[]=`, `system` with literal args, `ohai`/`opoo`/`odie`, file predicates. No control flow, no interpolation.       | ~35–45%       |
| **2 — Literal `inreplace` + interpolation**  | ~1 week   | Literal-string `inreplace`, string interpolation (`#{var}`, `#{constant}`, `#{simple.call}`).                                                                                                                           | ~50–60%       |
| **3 — Glob + `.each` + postfix `if/unless`** | 1–2 weeks | `Dir.glob` with `*`, `**`, `?`, `{a,b}`; statement-level `.each {                                                                                                                                                       | x             | ... }` with whitelisted body; postfix conditionals. | ~65–75% |
| **4 — Regex `inreplace` + `popen_read`**     | ~2 weeks  | Small regex engine (or vendored libc regex) for `inreplace`; `Utils.popen_read` and backticks as expressions producing `String`; `String#gsub`/`sub`/`chomp`/`strip`/`split`/`==`.                                      | ~75–85%       |
| **5 — `Formula[name]` + `begin/rescue`**     | ~1 week   | Cross-formula registry against malt's cellar (`Formula["openssl@3"].opt_prefix`); single-block `begin/rescue`.                                                                                                          | ~85–90%       |
| **6 — Stop.**                                | —         | Everything beyond this requires a real Ruby interpreter (method definitions, metaprogramming, `eval`). Fall back to `brew postinstall` for the residual ~10–15%. Track fallback cases in telemetry to monitor the tail. | —             |

**Effort.** Phases 0–3 are **~4–6 weeks** for one engineer comfortable with Zig and Homebrew's conventions, delivering an estimated 65–75% coverage. Phases 4–5 add 3–4 weeks for the next 10–15 points of coverage. Total for ~85–90% coverage: **~7–10 weeks**.

**Risk.** The dominant risk is not execution — it is **coverage reality**. If a homebrew-core scan shows that real `post_install` blocks use significantly more Ruby surface than the projected 60–80 primitives (e.g. widespread use of user-defined helper methods that would require parsing the full formula class body, or heavy `Dir[...].each { ... }` with multi-statement blocks), the phased estimate slips. This is why the coverage spike (below, §7) must come before any code is written.

**Verdict.** Recommended primary path. The only option that preserves every product promise simultaneously (size, cold start, toolchain, universal build), with a clearly phased rollout and a graceful failure mode that reuses existing refusal-plus-fallback behavior. Work is bounded because the input domain is bounded.

### 4.4 Option 4 — lib-ruby-parser (Rust) via FFI

**What it is.** `lib-ruby-parser` is a Rust crate (by Ilya Bylich) that produces a full, CRuby-compatible AST from Ruby source, with location tracking and error recovery. It is a port/successor of `whitequark/parser` and is the de-facto standard in the Ruby static-analysis ecosystem. It **parses only** — it does not execute. You still need an interpreter on top.

**Integration shape.** Three pieces:

1. A thin Rust wrapper crate under `vendor/ruby-parser-ffi/` with `crate-type = ["staticlib"]` that re-exports the AST over a C ABI as a `#[repr(C)]` tagged union plus `free_ast`.
2. A new `build.zig` step that runs `cargo build --release --target aarch64-apple-darwin` (and `x86_64-apple-darwin`), produces `libruby_parser_ffi.a` per arch, and links it.
3. Zig code that `@cImport`s the generated header and walks the AST, implementing the same builtins as Option 3 on top of it.

```zig
// build.zig addition
const cargo_arm = b.addSystemCommand(&.{
    "cargo", "build", "--release",
    "--manifest-path", "vendor/ruby-parser-ffi/Cargo.toml",
    "--target", "aarch64-apple-darwin",
});
exe.step.dependOn(&cargo_arm.step);
exe.addObjectFile(b.path("vendor/ruby-parser-ffi/target/aarch64-apple-darwin/release/libruby_parser_ffi.a"));
```

**The fundamental problem.** This option solves _half_ of Option 3's work (parsing) and pays a very high price for it: a second build toolchain (Rust/cargo/rustup), a ~2.5–4 MB binary-size hit for the parser tables, and a new category of "does cargo build for both macOS arches today?" release gates. The parser portion of a Ruby-subset recursive-descent parser in Zig is estimated at 800–1,200 LoC — saving that in exchange for introducing Rust into malt's supply chain is a bad trade, especially because the saved LoC is the _tedious_ part, not the _risky_ part.

**Verdict.** Not recommended. The parse-error quality is superior and the grammar coverage is battle-tested, but neither is worth inverting malt's "zero external toolchains" stance. Keep this option in mind only if a future homebrew-core grammar change breaks a hand-written Zig parser and lib-ruby-parser is the first to support it.

### 4.5 Option 5 — Subprocess delegation to system Ruby

**What it is.** Don't embed anything. Spawn `/usr/bin/ruby` (or `$(brew --prefix)/opt/ruby/bin/ruby` or `$HOME/.rbenv/shims/ruby`, in a detection chain) with a wrapper script that stubs the Homebrew `Formula` class, sets up `HOMEBREW_PREFIX`/`HOMEBREW_CELLAR`/`PATH`, and `instance_eval`s the `post_install` body.

**Integration shape.**

```zig
// src/core/ruby_subprocess.zig
pub fn runPostInstall(
    allocator: std.mem.Allocator,
    ruby_path: []const u8,
    formula_prefix: []const u8,
    post_install_src: []const u8,
) !void {
    const wrapper = try std.fmt.allocPrint(allocator,
        \\ENV['HOMEBREW_PREFIX'] = {s}
        \\ENV['HOMEBREW_CELLAR'] = {s}
        \\require 'pathname'
        \\require 'fileutils'
        \\class FormulaStub
        \\  def bin;    Pathname.new(ENV['MALT_PREFIX']) / 'bin' end
        \\  def etc;    Pathname.new(ENV['HOMEBREW_PREFIX']) / 'etc' end
        \\  def prefix; Pathname.new(ENV['MALT_PREFIX']) end
        \\  # ... ~30 more accessors
        \\  def post_install
        \\{s}
        \\  end
        \\end
        \\FormulaStub.new.post_install
    , .{ q(prefix), q(cellar), indent(post_install_src) });
    defer allocator.free(wrapper);

    var child = std.process.Child.init(&.{ ruby_path, "-e", wrapper }, allocator);
    child.env_map = try buildEnv(allocator, formula_prefix);
    try child.spawn();
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return error.PostInstallFailed;
}
```

**Perfect compatibility when Ruby is present.** It's real CRuby running real code with real stdlib. Every formula works. LoC is 300–600 total.

**The Ruby-availability problem.** macOS 11–15 still ship `/usr/bin/ruby` 2.6.x, but Apple has been warning of its removal since Catalina (2019). On a 1–3 year horizon, the only reliable Ruby on a user's machine is **Homebrew's own Ruby** — and that is exactly the dependency malt is trying to remove. A malt install flow that says "to install this package I need you to first install Homebrew" is a product contradiction.

**Detection chain (in recommended priority):**

1. `/opt/homebrew/opt/ruby/bin/ruby` (Homebrew keg, Apple Silicon)
2. `/usr/local/opt/ruby/bin/ruby` (Homebrew keg, Intel)
3. `$HOME/.rbenv/shims/ruby`, `$HOME/.asdf/shims/ruby`, `mise` shims
4. `/usr/bin/ruby` (Apple system, last resort — may be missing or too old)
5. PATH lookup

**Startup cost.** ~100 ms per invocation cold. For a `malt install` of 20 formulae with `post_install`, that's ~2 s of pure Ruby startup. Not fatal but noticeable.

**Relationship to the existing `brew fallback`.** malt already shells out to Homebrew for unsupported formulae — which already invokes Homebrew's Ruby for the full install. Subprocess-just-for-post_install is a finer-grained version of the same strategy: let malt do the heavy lifting (downloads, bottles, symlinks, deduplication, rollback) natively and only delegate the post_install step. That granularity is genuinely valuable — it turns all-or-nothing fallback into surgical fallback — even though it is architecturally the same family of solution.

**Security.** Unchanged from status quo. A formula's `post_install` body is already arbitrary code. Subprocess does not weaken the threat model; it arguably strengthens it via OS-level sandboxing and cleaner kill-on-timeout. No SIP or code-signing interaction — executing a signed or unsigned Ruby as a child process of signed malt is fine, child processes are not subject to parent notarization.

**Verdict.** Good **stopgap** behind an opt-in flag (`--allow-post-install-via-system-ruby` or `--use-system-ruby`) while Option 3 is being built. Not a long-term story because the Ruby-availability trajectory points at "no reliable Ruby outside Homebrew" and malt cannot require Homebrew to run.

---

## 5. Ranked Recommendation

| Rank  | Option                                | Role                                                        | Reason                                                                                                                                                                                                  |
| ----- | ------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **1** | Native Zig DSL interpreter (Option 3) | **Primary path**                                            | Only option that preserves size, cold start, toolchain, and universal-build constraints simultaneously. Bounded input domain. Graceful fallback. Work is all in the language the project is written in. |
| **2** | mruby embedded (Option 1)             | **Backup** if Option 3 coverage spike fails                 | Real Ruby semantics, tractable binary-size cost, hermetic VM. Deal-breaker risk is stdlib compat — every new formula surprise costs a shim.                                                             |
| **3** | Subprocess (Option 5)                 | **Stopgap** behind an opt-in flag during Option 3 Phase 0–1 | Unblocks power users immediately at zero binary cost. Not long-term viable due to Ruby-availability trajectory.                                                                                         |
| **4** | lib-ruby-parser (Option 4)            | **Rejected**                                                | Inverts malt's zero-toolchain stance (introduces Rust/cargo) for the saving of the least-risky part of Option 3 (the parser). Bad trade.                                                                |
| **5** | CRuby libruby (Option 2)              | **Rejected**                                                | 4–7× binary regression, 20–80 ms init, cross-compile hostile, ABI unstable, depends on a deprecated macOS system framework in the dynamic case. Every constraint fails.                                 |

### 5.1 Phased rollout plan

**Week 0 — Coverage spike (blocking).** Clone homebrew-core. Extract the `def post_install ... end` body of every formula with `post_install_defined`. Parse each body (using any available Ruby parser — even `ruby -e 'require "parser/current"; ...'` — this is a one-shot analysis script, not production code). Produce a histogram of:

- Method names called (sorted by frequency)
- AST node kinds appearing (sorted by frequency)
- Block-form usages, grouped by receiver method
- String-interpolation complexity (literal only / simple var / method call)
- User-defined helper method calls (i.e. methods defined elsewhere in the formula class body)

This single artifact tells us whether Option 3's 60–80-primitive thesis holds. If it does, proceed. If it doesn't, fall back to Option 1 (mruby) and re-scope.

**Weeks 1–6 — Option 3 Phases 0–3.** Parser, AST, verification pass, Trivial tier, literal `inreplace` + interpolation, Glob + `.each` + postfix conditionals. Target: ~65–75% native coverage.

**In parallel (Weeks 1–2) — Option 5 stopgap.** Ship `--use-system-ruby` behind a flag, with a clear warning that it requires a user-installed Ruby (prioritizing Homebrew's Ruby in the detection chain). This unblocks power users immediately without waiting on Phase 3.

**Weeks 7–10 — Option 3 Phases 4–5.** Regex `inreplace`, `popen_read`, `Formula[name]` lookup, `begin/rescue`. Target: ~85–90% native coverage.

**Ongoing.** Track `UnknownMethod` and `UnsupportedNode` fallbacks in local telemetry (opt-in) or an anonymous log. The tail is the signal for whether Phase 6 is ever worth starting — if two or three specific constructs account for most of the residual 10–15%, implement those; otherwise stop at ~90% and live with surgical `brew postinstall` fallback for the rest.

---

## 6. Edge Cases and Known-Hard Patterns

Patterns that will defeat any Option 3 tier short of a full Ruby interpreter, collected from homebrew-core conventions:

1. **Globbed iteration with regex inreplace** — `Dir["#{libexec}/**/*.py"].each { |f| inreplace f, %r{^#!/usr/bin/env python}, "#!#{Formula["python@3.12"].opt_bin}/python3" }`. Multi-line block, regex, cross-formula lookup, interpolation — every hard feature at once.
2. **Heredocs as config templates** — `(etc/"foo.conf").write <<~EOS\n  prefix = #{HOMEBREW_PREFIX}\n  log = #{var}/log/foo.log\nEOS`. Needs a heredoc lexer and the `<<~` indent-stripping variant.
3. **`Pathname#children.select`** — `(lib/"plugins").children.select(&:directory?).each { |d| ... }`. Block-with-symbol syntax, multi-step filtering.
4. **Version comparison** — `if Version.new(\`#{bin}/foo --version\`.strip.split.last) >= Version.new("2.5")`. Backticks + `String`ops +`Version`class +`>=`.
5. **Conditional by `OS.mac?` / `MacOS.version`** — cheap to fake (malt is macOS-only) but the parser must still recognize and constant-fold it.
6. **`Utils.safe_popen_read` with subsequent use** — `uuid = Utils.safe_popen_read("uuidgen").chomp` then `inreplace etc/"foo.conf", "@UUID@", uuid`. Requires a real expression evaluator with locals threaded through the rest of the block.
7. **`begin/rescue` with side-effect rollback** — exceptions are deep Ruby semantics; the simple single-block form is doable, multi-rescue is not.
8. **Hash literals to `inreplace`** — `inreplace etc/"foo.conf", { "@@PREFIX@@" => HOMEBREW_PREFIX.to_s, "@@VER@@" => version.to_s }`. Parser must recognize hash literals.
9. **Method definitions in the class body called from `post_install`** — a helper `def default_conf; <<~EOS; ...; EOS; end` defined elsewhere. Resolving it requires parsing the _entire_ formula class, not just the `post_install` method.
10. **`File.foreach` + block + rewrite** — streaming read/modify/write loops. Rare but real.
11. **Dynamic `require` / `eval`** — effectively zero formulae should do this in `post_install`, but Ruby allows it. Fall back unconditionally.
12. **Deep metaprogramming** — `define_method`, `method_missing`, `instance_eval` with a block. Not expected in `post_install`, but if encountered, fall back.

All of these are acceptable Option 3 failures because they fall through to `brew postinstall <formula>`, which is what users get today anyway.

---

## 7. Open Questions and Next Steps

### 7.1 Blocking spike (must do first)

- **Homebrew-core post_install histogram.** One-day analysis described in §5.1. This is the single highest-value piece of information for the decision. Every uncertainty band in this document collapses once we have real frequency data. _Without this spike, Option 3's 4–6 week estimate is a guess._

### 7.2 Verification before committing to Option 3

- Does the `post_install_defined` JSON flag correspond 1:1 with the presence of `def post_install` in the `.rb` source? If the flag is set for formulae where the method is inherited, empty, or dynamically generated, Option 3's parser needs to handle those degenerate cases.
- Are we content to statically parse only `def post_install ... end` out of the full `.rb` file, or do we need to handle the formula class body to resolve helper methods? The Week 0 spike answers this.
- For `system` calls inside `post_install`, what's the right way to surface stdout/stderr through malt's existing progress UI (`src/ui/output.zig`)? Need a small design doc once Phase 1 lands.
- For `inreplace`, how do we handle atomicity? Ruby's implementation reads, substitutes, writes-back. Do we need a tempfile + rename for crash safety?
- How do we test `post_install` execution hermetically? Sandboxing the cellar path is clear; sandboxing `system` calls (which may themselves be arbitrary commands) is harder.

### 7.3 Verification before committing to Option 1 (if Option 3 is ruled out)

- Does mruby's C source tree compile cleanly under Zig's C frontend for both `aarch64-macos` and `x86_64-macos` from the same machine? One-day spike.
- Which mrbgems are actually needed for Homebrew-DSL coverage, and what's their binary-size cost? Target: keep under 1.5 MB added.
- Is `mruby-process` faithful enough to CRuby's `Kernel#system` semantics (signal handling, env inheritance, exit code propagation) for Homebrew's usage patterns?

### 7.4 Out of scope for this document

- Whether malt should ever ship an optional `malt-full` variant with CRuby for 100% compatibility. Separate product decision.
- Whether malt should intercept `install` blocks (not just `post_install`) for formulae built from source. `install` blocks are significantly more complex and this analysis does not cover them.
- Whether malt should cache AST parses across invocations. Probably yes, probably as a SQLite-backed cache in the existing store layout, but an optimization rather than a correctness concern.

---

## 8. References

**Code references (grounded during analysis):**

- `src/core/formula.zig:31` — `post_install_defined: bool` field
- `src/core/formula.zig:121` — flag populated from Homebrew API JSON
- `src/cli/install.zig:689–699` — current `PostInstallUnsupported` refusal site
- `src/cli/migrate.zig:230–236` — `.skipped_post_install` return in migrate flow
- `src/core/linker.zig` — existing symlink/relocation primitives reusable for Phase-1 `install_symlink`/`ln_sf`
- `src/ui/output.zig` — target for `ohai`/`opoo`/`odie` mapping
- `src/core/tap.zig` — tap directory resolution, source of the `.rb` file Option 3 needs to parse
- `build.zig` — universal-build step (`aarch64-macos` + `x86_64-macos` + `lipo`) that constrains every toolchain decision
- `vendor/` — currently only SQLite amalgamation; template for any vendored C dependency
- `c/clonefile.h` — current extent of C interop (single header for `@cImport`)

**Uncertainties flagged throughout:**

- All coverage percentages in §5.1 are estimates with ±10–15 point bands, pending the Week 0 spike.
- Per-invocation latency ranges in §3 are derived from general knowledge of each runtime, not measured on malt specifically.
- The exact mruby 3.x point release and the maturity of its Homebrew-compat mrbgems should be verified before committing to Option 1.
- The current state of `/usr/bin/ruby` on macOS 15/16 should be re-verified before shipping Option 5 — Apple's removal timeline is "eventually" and has been for multiple releases.
