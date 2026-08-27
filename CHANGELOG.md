# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The changelog is generated and managed by [sley](https://github.com/indaco/sley).

## v0.23.1 - 2026-08-22

### Highlights

v0.23.1 is a fixes-only release, mostly post-install work, interruptible network calls, and hardening.

- **Post-install work runs again.** Homebrew is moving formulas off Ruby onto declarative steps, and malt didn't run some of them. llvm, redis, nginx, ruby, python and gcc quietly skipped their setup; a malt-installed `clang` ended up with no config file. They now get it on the next install, upgrade, or `mt migrate`.
- **Ctrl-C interrupts.** Downloads, retry backoffs and stalled network calls stop when you hit Ctrl-C. A silent origin can no longer hold a command open indefinitely.
- **Formula and tap text can't drive your terminal.** Control sequences are stripped before anything is printed. Formula code also runs without your secrets in its environment, and every network hop stays on HTTPS.
- **Taps resolve the way brew resolves them.** All spellings of a tap are one tap, so pins, `mt untap` and `--tap` filters stop disagreeing. And a failed `mt rollback` no longer leaves you with no working version of the package.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🩹 Fixes

- **post-install:** run the declarative steps upstream moved formulas onto ([07a0b92e](https://github.com/indaco/malt/commit/07a0b92e)) ([#893](https://github.com/indaco/malt/pull/893))
- **net:** honor Ctrl-C during a retry backoff ([8aa4eaeb](https://github.com/indaco/malt/commit/8aa4eaeb)) ([#888](https://github.com/indaco/malt/pull/888))
- **install:** honor Ctrl-C during a bottle download ([e55c94be](https://github.com/indaco/malt/commit/e55c94be)) ([#887](https://github.com/indaco/malt/pull/887))
- **net:** stop a silent origin from parking a command with no timeout and no Ctrl-C ([43e1dd37](https://github.com/indaco/malt/commit/43e1dd37)) ([#886](https://github.com/indaco/malt/pull/886))
- **tap:** treat every spelling of a tap as the one tap brew treats it as ([c375cf3b](https://github.com/indaco/malt/commit/c375cf3b)) ([#885](https://github.com/indaco/malt/pull/885))
- **net:** stop a Ctrl-C during a network call from being slept off and retried ([31d85c41](https://github.com/indaco/malt/commit/31d85c41)) ([#883](https://github.com/indaco/malt/pull/883))
- **net:** refuse a cleartext origin on a conditional GET ([a46bd6c8](https://github.com/indaco/malt/commit/a46bd6c8)) ([#882](https://github.com/indaco/malt/pull/882))
- **net:** stop failing a cask install on a blip the download would have retried ([52850a33](https://github.com/indaco/malt/commit/52850a33)) ([#881](https://github.com/indaco/malt/pull/881))
- **net:** stop classifying casks from redirect chains the download would reject ([f02477bd](https://github.com/indaco/malt/commit/f02477bd)) ([#880](https://github.com/indaco/malt/pull/880))
- **net:** stop resolving a cask artifact from a redirect chain that never ended ([0935587d](https://github.com/indaco/malt/commit/0935587d)) ([#879](https://github.com/indaco/malt/pull/879))
- **update:** run the exact cosign the trust guard approved ([f7e0c536](https://github.com/indaco/malt/commit/f7e0c536)) ([#878](https://github.com/indaco/malt/pull/878))
- **net:** stop passing off a failed artifact-URL resolution as a successful one ([4622f952](https://github.com/indaco/malt/commit/4622f952)) ([#877](https://github.com/indaco/malt/pull/877))
- **net:** refuse a cleartext hop when resolving a redirecting artifact URL ([99c20a52](https://github.com/indaco/malt/commit/99c20a52)) ([#876](https://github.com/indaco/malt/pull/876))
- **post-install:** stop native post_install children from seeing malt's secrets ([84056ac7](https://github.com/indaco/malt/commit/84056ac7)) ([#875](https://github.com/indaco/malt/pull/875))
- **tui:** drop 8-bit control bytes from row content before it reaches the terminal ([0bd61df3](https://github.com/indaco/malt/commit/0bd61df3)) ([#874](https://github.com/indaco/malt/pull/874))
- **ui:** stop child output from repainting lines it never wrote ([6b2fe115](https://github.com/indaco/malt/commit/6b2fe115)) ([#872](https://github.com/indaco/malt/pull/872))
- **ui:** reject ill-formed UTF-8 so no escape byte reaches the terminal ([b638de4d](https://github.com/indaco/malt/commit/b638de4d)) ([#871](https://github.com/indaco/malt/pull/871))
- **ui:** drop CSI sequences whose parameters are not plain numeric ([abe8bbfe](https://github.com/indaco/malt/commit/abe8bbfe)) ([#870](https://github.com/indaco/malt/pull/870))
- **ui:** strip terminal control sequences from formula and tap text ([bf8eeffa](https://github.com/indaco/malt/commit/bf8eeffa)) ([#869](https://github.com/indaco/malt/pull/869))
- **rollback:** never leave a package broken by a failed rollback ([fb4c0cfe](https://github.com/indaco/malt/commit/fb4c0cfe)) ([#868](https://github.com/indaco/malt/pull/868))
- **tap:** act on a prefix that has no database yet ([fd803418](https://github.com/indaco/malt/commit/fd803418)) ([#866](https://github.com/indaco/malt/pull/866))
- **net:** stop stalling on responses that carry no body ([fc9992e1](https://github.com/indaco/malt/commit/fc9992e1)) ([#865](https://github.com/indaco/malt/pull/865))
- **build:** restore the relocation-logic pin so the guard runs again ([1570de12](https://github.com/indaco/malt/commit/1570de12)) ([#864](https://github.com/indaco/malt/pull/864))
- **tui:** refuse to start rather than re-exec through PATH ([4d2b9597](https://github.com/indaco/malt/commit/4d2b9597)) ([#863](https://github.com/indaco/malt/pull/863))
- **cask:** give each DMG install a mount point it created ([e101fd75](https://github.com/indaco/malt/commit/e101fd75)) ([#862](https://github.com/indaco/malt/pull/862))
- **dsl:** create symlinks with the target a formula wrote ([9c282876](https://github.com/indaco/malt/commit/9c282876)) ([#860](https://github.com/indaco/malt/pull/860))
- **build:** run the integration suite in the fast test target ([a29696cf](https://github.com/indaco/malt/commit/a29696cf)) ([#858](https://github.com/indaco/malt/pull/858))
- **dsl:** isolate formula environments ([f7e13feb](https://github.com/indaco/malt/commit/f7e13feb)) ([#842](https://github.com/indaco/malt/pull/842))
- use trusted paths for macOS system tools ([08705a96](https://github.com/indaco/malt/commit/08705a96)) ([#845](https://github.com/indaco/malt/pull/845))
- **cask:** confine artifact sources to extraction roots ([e7df474d](https://github.com/indaco/malt/commit/e7df474d)) ([#843](https://github.com/indaco/malt/pull/843))
- **archive:** recheck deferred hardlinks ([014f1102](https://github.com/indaco/malt/commit/014f1102)) ([#837](https://github.com/indaco/malt/pull/837))
- **dsl:** confine native read sources ([8279d263](https://github.com/indaco/malt/commit/8279d263)) ([#840](https://github.com/indaco/malt/pull/840))
- **dsl:** confine mutation path variants ([75f39047](https://github.com/indaco/malt/commit/75f39047)) ([#836](https://github.com/indaco/malt/pull/836))

### 📖 Documentation

- add security policy for private vulnerability reports ([ae8b6d24](https://github.com/indaco/malt/commit/ae8b6d24)) ([#892](https://github.com/indaco/malt/pull/892))
- **readme:** remove outdated example version note ([fdd694e5](https://github.com/indaco/malt/commit/fdd694e5)) ([#867](https://github.com/indaco/malt/pull/867))
- add AGENTS.md for AI-assisted contributions ([1bc596af](https://github.com/indaco/malt/commit/1bc596af)) ([#857](https://github.com/indaco/malt/pull/857))
- **changelog:** restore the 0.22 patch release notes ([4a3bda87](https://github.com/indaco/malt/commit/4a3bda87)) ([#835](https://github.com/indaco/malt/pull/835))

### 🏡 Chores

- **devbox:** update packages ([681722a6](https://github.com/indaco/malt/commit/681722a6)) ([#890](https://github.com/indaco/malt/pull/890))
- **regressions:** re-pin relocation logic without a cache-version bump ([41b036c6](https://github.com/indaco/malt/commit/41b036c6))

### 🤖 CI

- **bench:** stop reporting an unconfigured peer as a benchmark failure ([fcca83c2](https://github.com/indaco/malt/commit/fcca83c2)) ([#891](https://github.com/indaco/malt/pull/891))
- **bench:** restore the weekly benchmark after nanobrew's relocation change ([2c1ed31e](https://github.com/indaco/malt/commit/2c1ed31e)) ([#859](https://github.com/indaco/malt/pull/859))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@rustytrees](https://github.com/rustytrees)

## v0.23.0 - 2026-08-10

### Highlights

v0.23.0 widens the set of packages malt installs end to end, makes a warm run nearly free, and puts Ctrl-C in charge of any command.

- **More packages install complete.** Formulas run the post-install step they declare, so `ca-certificates` and `fontconfig` land ready to use; perl-based packages like `exiftool` are runnable straight after install; and `.tar.xz` casks - every Nerd Font among them - install natively.
- **Nothing to do costs nothing.** A `bundle install` where nothing changed does no network work at all, and relinking a large keg is ~3x faster.
- **Ctrl-C stops any command.** Slow commands stop on the first press rather than finishing a walk you no longer want, and a second press always kills.
- **A tighter trust path.** Cleartext download urls are refused, and self-update no longer trusts a signature verifier picked up from a directory packages can write to.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **macho:** patch universal binaries in 64-bit fat containers ([8219c0e2](https://github.com/indaco/malt/commit/8219c0e2)) ([#828](https://github.com/indaco/malt/pull/828))

### 🩹 Fixes

- **post-install:** honour the conditions and fields formulas declare ([e8681e99](https://github.com/indaco/malt/commit/e8681e99)) ([#832](https://github.com/indaco/malt/pull/832))
- **post-install:** finish the install for formulas that clean up and glob ([d816caef](https://github.com/indaco/malt/commit/d816caef)) ([#831](https://github.com/indaco/malt/pull/831))
- **security:** close the cleartext and verifier-shim gaps on the trust path ([51b955a0](https://github.com/indaco/malt/commit/51b955a0)) ([#826](https://github.com/indaco/malt/pull/826))
- **install:** stop re-fetching metadata for packages already installed ([d3a5c871](https://github.com/indaco/malt/commit/d3a5c871)) ([#825](https://github.com/indaco/malt/pull/825))
- **cli:** make Ctrl-C actually stop malt ([c1ed701e](https://github.com/indaco/malt/commit/c1ed701e)) ([#822](https://github.com/indaco/malt/pull/822))
- **relocation:** make perl-based packages runnable after install ([dec3d5ac](https://github.com/indaco/malt/commit/dec3d5ac)) ([#819](https://github.com/indaco/malt/pull/819))
- **build:** make the fast test target actually run every test ([3fd0cdad](https://github.com/indaco/malt/commit/3fd0cdad)) ([#818](https://github.com/indaco/malt/pull/818))
- **relocation:** report kegs left behind when relocation logic changes ([88331287](https://github.com/indaco/malt/commit/88331287)) ([#817](https://github.com/indaco/malt/pull/817))
- **relocation:** report the paths a long prefix leaves pointing at the build prefix ([8b931c7b](https://github.com/indaco/malt/commit/8b931c7b)) ([#816](https://github.com/indaco/malt/pull/816))
- **cask:** install the .tar.xz casks malt was turning away ([c94ec734](https://github.com/indaco/malt/commit/c94ec734)) ([#815](https://github.com/indaco/malt/pull/815))
- **post-install:** run the commands formulas declare in post-install steps ([a4ab5d7d](https://github.com/indaco/malt/commit/a4ab5d7d)) ([#814](https://github.com/indaco/malt/pull/814))
- **services:** resolve the service name once per operation, not per lookup ([384296fd](https://github.com/indaco/malt/commit/384296fd)) ([#811](https://github.com/indaco/malt/pull/811))
- **services:** create working_dir and accept a keg name ([870003b8](https://github.com/indaco/malt/commit/870003b8))
- **post-install:** fail loudly instead of hanging when the output filter cannot start ([5a50b1a9](https://github.com/indaco/malt/commit/5a50b1a9)) ([#810](https://github.com/indaco/malt/pull/810))
- **post-install:** sanitize child output on the native interpreter path ([66b1d064](https://github.com/indaco/malt/commit/66b1d064)) ([#793](https://github.com/indaco/malt/pull/793))
- **post-install:** confine the copy step's source to the keg and prefix ([4306a9e0](https://github.com/indaco/malt/commit/4306a9e0)) ([#809](https://github.com/indaco/malt/pull/809))
- **post-install:** add the copy step and expand keg/prefix tokens inline ([c9fb5eee](https://github.com/indaco/malt/commit/c9fb5eee)) ([#803](https://github.com/indaco/malt/pull/803))
- **security:** refuse an undeclared cask digest and a symlinked link target ([9b126e94](https://github.com/indaco/malt/commit/9b126e94)) ([#807](https://github.com/indaco/malt/pull/807))
- **security:** close tap-controlled path and sandbox escapes ([f03c3ca7](https://github.com/indaco/malt/commit/f03c3ca7))
- **archive:** refuse entries written through an archive's own symlink ([1141bd54](https://github.com/indaco/malt/commit/1141bd54))

### 💅 Refactors

- **macho:** make the fat-slice bounds check independent of field width ([d9a4a201](https://github.com/indaco/malt/commit/d9a4a201)) ([#827](https://github.com/indaco/malt/pull/827))

### 📖 Documentation

- **benchmark:** update results 2026-08-10 ([f360b5b8](https://github.com/indaco/malt/commit/f360b5b8)) ([#824](https://github.com/indaco/malt/pull/824))
- **benchmark:** update results 2026-08-03 ([95f4b94d](https://github.com/indaco/malt/commit/95f4b94d)) ([#802](https://github.com/indaco/malt/pull/802))
- **benchmark:** update results 2026-07-27 ([4d84ead6](https://github.com/indaco/malt/commit/4d84ead6)) ([#788](https://github.com/indaco/malt/pull/788))

### 🎨 Styling

- restore zig fmt compliance in path_component ([8e2ffab7](https://github.com/indaco/malt/commit/8e2ffab7)) ([#808](https://github.com/indaco/malt/pull/808))

### ✅ Tests

- **archive:** pin symlink bookkeeping to the pax-overridden entry name ([009963a6](https://github.com/indaco/malt/commit/009963a6)) ([#806](https://github.com/indaco/malt/pull/806))

### 🏡 Chores

- update codecov.json ([ad252597](https://github.com/indaco/malt/commit/ad252597))
- **demos:** authenticate the demo recorder against the GitHub API ([43df4072](https://github.com/indaco/malt/commit/43df4072)) ([#830](https://github.com/indaco/malt/pull/830))
- **deps:** bump vendored SQLite to 3.53.4 ([d8b75c9f](https://github.com/indaco/malt/commit/d8b75c9f)) ([#795](https://github.com/indaco/malt/pull/795))
- **pins:** bump homebrew-core pin to b6ad3325be06 ([a24eea4e](https://github.com/indaco/malt/commit/a24eea4e)) ([#799](https://github.com/indaco/malt/pull/799))

### 🤖 CI

- restore push credentials for the workflows that publish branches ([868354cb](https://github.com/indaco/malt/commit/868354cb)) ([#823](https://github.com/indaco/malt/pull/823))
- harden GitHub Actions workflows with zizmor recommendations ([b39bdeb7](https://github.com/indaco/malt/commit/b39bdeb7)) ([#813](https://github.com/indaco/malt/pull/813))
- bump actions/setup-go from 6 to 7 ([7f359700](https://github.com/indaco/malt/commit/7f359700)) ([#800](https://github.com/indaco/malt/pull/800))
- bump taiki-e/install-action from 2 to 2.85.4 ([c6afd9f2](https://github.com/indaco/malt/commit/c6afd9f2)) ([#801](https://github.com/indaco/malt/pull/801))

### 📦 Build

- generate the single-binary test root so it cannot drift from the module list ([439c4580](https://github.com/indaco/malt/commit/439c4580)) ([#812](https://github.com/indaco/malt/pull/812))
- add a single-binary test target ([ebe5bc2f](https://github.com/indaco/malt/commit/ebe5bc2f))

### 🎉 New Contributors

- [@rustytrees](https://github.com/rustytrees) made their first contribution in [#795](https://github.com/indaco/malt/pull/795)

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@rustytrees](https://github.com/rustytrees)
- [@github-actions[bot]](https://github.com/github-actions[bot])
- [@dependabot[bot]](https://github.com/dependabot[bot])

## v0.22.3 - 2026-07-27

### Highlights

v0.22.3 is a fix release: packages that arrive fully set up and usable, and colour output that follows your terminal and your redirects.

- **Formulas that finish setting themselves up.** Packages that publish a launcher or shell completions from their post-install step now land on your PATH instead of installing with nothing to run, stale links are retired on the way, and a shipped config file arrives filled in rather than with the placeholder still in it.
- **Bottles that actually launch.** A bottle whose wrapper points inside another package now resolves that path at install time, so it runs instead of failing on first use - and `mt doctor` flags any leftover placeholder in a script, a case that used to install clean and break later.
- **Colour that respects your terminal and your pipes.** `CLICOLOR_FORCE` gets you ANSI through `less -R` or a CI log, `CLICOLOR=0` turns it off, and `NO_COLOR` still overrides everything. Redirecting a command to a file no longer fills it with escape sequences, and a 256-colour custom theme falls back to the default palette on terminals that can't render it.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🩹 Fixes

- **post-install:** close declarative post-install step gaps ([97214997](https://github.com/indaco/malt/commit/97214997)) ([#787](https://github.com/indaco/malt/pull/787))
- **install:** resolve dependency-scoped bottle placeholders ([12bbdcbf](https://github.com/indaco/malt/commit/12bbdcbf)) ([#786](https://github.com/indaco/malt/pull/786))
- **ui:** gate 256-index custom themes on terminal depth ([c7156691](https://github.com/indaco/malt/commit/c7156691)) ([#785](https://github.com/indaco/malt/pull/785))
- **ui:** decide colour per output stream ([85e6b1db](https://github.com/indaco/malt/commit/85e6b1db)) ([#784](https://github.com/indaco/malt/pull/784))
- **ui:** honour CLICOLOR and CLICOLOR_FORCE ([7714b8c1](https://github.com/indaco/malt/commit/7714b8c1)) ([#783](https://github.com/indaco/malt/pull/783))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.22.2 - 2026-07-26

### Highlights

v0.22.2 makes cleanup and doctor agree on broken symlinks, speeds up relinking on large kegs, and stops a bad install from ever passing as a success.

- **`mt cleanup` now actually removes broken symlinks.** Doctor's advice to run it used to do nothing - now it does, wherever the symlinks live.
- **Faster relinking on big kegs.** Reinstalling packages like openssl@3 is up to 3x quicker.
- **Bad installs get caught, not shipped.** A relocation defect that would leave a binary unable to load now fails the install instead of reporting success.
- **Real help for every command.** `untap`, `help`, and the `remove`/`ls` aliases no longer dead-end on "No help available."

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🩹 Fixes

- **cleanup:** sweep broken symlinks so doctor's advice works ([f07460a6](https://github.com/indaco/malt/commit/f07460a6)) ([#782](https://github.com/indaco/malt/pull/782))
- **doctor:** find broken symlinks below the top level of each link dir ([a1dc3b49](https://github.com/indaco/malt/commit/a1dc3b49)) ([#781](https://github.com/indaco/malt/pull/781))
- **cli:** give untap, help and the command aliases real help topics ([95182d92](https://github.com/indaco/malt/commit/95182d92)) ([#778](https://github.com/indaco/malt/pull/778))
- **install:** refuse a keg the loader would reject ([303e0632](https://github.com/indaco/malt/commit/303e0632)) ([#776](https://github.com/indaco/malt/pull/776))

### ⚡ Performance

- **linker:** cut warm-install link time by ~3x on large kegs ([a35d7705](https://github.com/indaco/malt/commit/a35d7705)) ([#779](https://github.com/indaco/malt/pull/779))

### ✅ Tests

- **regression:** stop the etag guard blaming malt for a shared rate limit ([5c4498de](https://github.com/indaco/malt/commit/5c4498de)) ([#780](https://github.com/indaco/malt/pull/780))
- **regression:** tell apart a real etag regression from GitHub flakiness ([a94b3119](https://github.com/indaco/malt/commit/a94b3119)) ([#777](https://github.com/indaco/malt/pull/777))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.22.1 - 2026-07-25

### 🩹 Fixes

- **store:** re-relocate kegs cached before the rpath dedup landed ([743127d7](https://github.com/indaco/malt/commit/743127d7)) ([#775](https://github.com/indaco/malt/pull/775))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.22.0 - 2026-07-24

### Highlights

v0.22.0 shows you when a package slips backward, makes installs fail loud instead of going quiet, and widens the range of formulae that install cleanly.

- **See when a package moves backward.** When an upstream version goes down, `mt outdated` and `mt upgrade` now flag it - and the `mt tui` Outdated tab marks it too - so a downgrade never slips past looking like a routine update.
- **Operations that speak up instead of going quiet.** Purge, migrate, and link path failures now surface instead of reporting a silent success, oversized auth tokens are sized to fit rather than dropped, and orphan-enumeration errors are reported instead of truncated - fewer operations that look fine but weren't.
- **More Homebrew formulae just install.** The native interpreter now interpolates and de-indents squiggly heredoc bodies, so formulae that build files from heredocs work as written.
- **Remove a bundle and its packages in one go.** `mt bundle remove --purge` now uninstalls the members it drops, instead of leaving them installed behind the bundle.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **dsl:** de-indent squiggly heredoc bodies ([01b4c561](https://github.com/indaco/malt/commit/01b4c561)) ([#770](https://github.com/indaco/malt/pull/770))
- **dsl:** interpolate heredoc bodies in the native interpreter ([d4d6baa2](https://github.com/indaco/malt/commit/d4d6baa2)) ([#769](https://github.com/indaco/malt/pull/769))
- **tui:** mark backward moves in the Outdated tab ([9d8e0571](https://github.com/indaco/malt/commit/9d8e0571)) ([#757](https://github.com/indaco/malt/pull/757))
- **upgrade:** announce when a package moves backward ([b78433a7](https://github.com/indaco/malt/commit/b78433a7)) ([#755](https://github.com/indaco/malt/pull/755))
- **outdated:** mark rows whose upstream moved backward ([aa123a55](https://github.com/indaco/malt/commit/aa123a55)) ([#753](https://github.com/indaco/malt/pull/753))
- **bundle:** uninstall members with bundle remove --purge ([617883ae](https://github.com/indaco/malt/commit/617883ae)) ([#730](https://github.com/indaco/malt/pull/730))

### 🩹 Fixes

- **dsl:** fail loud when building system/popen argv instead of dropping args ([ff59bfee](https://github.com/indaco/malt/commit/ff59bfee)) ([#768](https://github.com/indaco/malt/pull/768))
- **core:** fail loud when a forge auth token overflows its buffer ([69993353](https://github.com/indaco/malt/commit/69993353)) ([#766](https://github.com/indaco/malt/pull/766))
- **net:** size the auth header exactly so long tokens are never dropped ([fa90d94f](https://github.com/indaco/malt/commit/fa90d94f)) ([#765](https://github.com/indaco/malt/pull/765))
- **cli:** surface purge lock-path failure instead of silent success ([0a61a4f4](https://github.com/indaco/malt/commit/0a61a4f4)) ([#764](https://github.com/indaco/malt/pull/764))
- **cli:** surface migrate path failures instead of silent success ([3c3bbed3](https://github.com/indaco/malt/commit/3c3bbed3)) ([#763](https://github.com/indaco/malt/pull/763))
- **cli:** surface link path and bind failures instead of silent success ([d9780e87](https://github.com/indaco/malt/commit/d9780e87)) ([#762](https://github.com/indaco/malt/pull/762))
- **ui/color:** make lazy env/TTY caches race-free with atomic sentinels ([f47b7260](https://github.com/indaco/malt/commit/f47b7260)) ([#760](https://github.com/indaco/malt/pull/760))
- **install:** drop rpaths that relocation collapses onto one prefix ([5c0128c2](https://github.com/indaco/malt/commit/5c0128c2)) ([#758](https://github.com/indaco/malt/pull/758))
- **outdated:** stop rendering an ordering claim malt never checks ([8aa1f60f](https://github.com/indaco/malt/commit/8aa1f60f)) ([#749](https://github.com/indaco/malt/pull/749))
- **upgrade:** print the revision-qualified installed version ([4e862ee2](https://github.com/indaco/malt/commit/4e862ee2)) ([#748](https://github.com/indaco/malt/pull/748))
- **outdated:** stop qualifying tap cask versions with a stray revision ([249d8604](https://github.com/indaco/malt/commit/249d8604)) ([#747](https://github.com/indaco/malt/pull/747))
- **dsl:** read a leading-zero formula literal as octal ([39f3441b](https://github.com/indaco/malt/commit/39f3441b)) ([#745](https://github.com/indaco/malt/pull/745))
- **doctor:** stop misjudging which process holds the database lock ([8d8648dd](https://github.com/indaco/malt/commit/8d8648dd)) ([#740](https://github.com/indaco/malt/pull/740))
- **db:** stop fresh databases rebuilding an empty kegs table ([09e95772](https://github.com/indaco/malt/commit/09e95772)) ([#739](https://github.com/indaco/malt/pull/739))
- **deps:** make the declared resolve error set the real one ([0d732106](https://github.com/indaco/malt/commit/0d732106)) ([#736](https://github.com/indaco/malt/pull/736))
- **cli:** drop no-op flags and complete the Homebrew plural aliases ([c9a52e18](https://github.com/indaco/malt/commit/c9a52e18)) ([#735](https://github.com/indaco/malt/pull/735))
- **help:** give bundle and services real help topics ([60d36465](https://github.com/indaco/malt/commit/60d36465)) ([#733](https://github.com/indaco/malt/pull/733))
- **completions:** stop advertising flags the CLI does not accept ([5f6825fa](https://github.com/indaco/malt/commit/5f6825fa)) ([#731](https://github.com/indaco/malt/pull/731))
- **store:** surface orphan-enumeration errors instead of silently truncating ([a3d48523](https://github.com/indaco/malt/commit/a3d48523)) ([#718](https://github.com/indaco/malt/pull/718))

### 💅 Refactors

- **outdated:** follow the fetch for the dry-run snapshot and unify the currency compare ([6f897d97](https://github.com/indaco/malt/commit/6f897d97)) ([#771](https://github.com/indaco/malt/pull/771))
- **auth:** use one GitHub Authorization scheme across net and core ([ae9d4387](https://github.com/indaco/malt/commit/ae9d4387)) ([#767](https://github.com/indaco/malt/pull/767))
- **fs:** add prefix_path leaf for overflow-safe path joins ([c7cd98a9](https://github.com/indaco/malt/commit/c7cd98a9)) ([#761](https://github.com/indaco/malt/pull/761))
- **install:** encode the tap-archive digest with the standard library ([8e7d9186](https://github.com/indaco/malt/commit/8e7d9186)) ([#743](https://github.com/indaco/malt/pull/743))
- **core:** retire the hand-rolled constant-time SHA compare ([565d9ad3](https://github.com/indaco/malt/commit/565d9ad3)) ([#742](https://github.com/indaco/malt/pull/742))
- **cli, ui:** remove three pieces of code that never did what they claimed ([45f28d66](https://github.com/indaco/malt/commit/45f28d66)) ([#738](https://github.com/indaco/malt/pull/738))
- **doctor:** prepare the orphan classifier once per sweep ([f284a19b](https://github.com/indaco/malt/commit/f284a19b)) ([#729](https://github.com/indaco/malt/pull/729))
- **outdated:** reuse the pooled client for tap .rb fetches ([7be2d400](https://github.com/indaco/malt/commit/7be2d400)) ([#728](https://github.com/indaco/malt/pull/728))
- **migrate:** dedup outcome drain and extract parallel runner ([57be182d](https://github.com/indaco/malt/commit/57be182d)) ([#727](https://github.com/indaco/malt/pull/727))
- **install:** iterate rb_parse lines with std.mem.splitScalar ([bf0aec42](https://github.com/indaco/malt/commit/bf0aec42)) ([#726](https://github.com/indaco/malt/pull/726))
- **fs:** consolidate readFileAllAbsolute into one shared helper ([346a791c](https://github.com/indaco/malt/commit/346a791c)) ([#722](https://github.com/indaco/malt/pull/722))
- **linker:** derive conflict-check dirs from the canonical list ([ecf3b2e6](https://github.com/indaco/malt/commit/ecf3b2e6)) ([#719](https://github.com/indaco/malt/pull/719))

### 📖 Documentation

- **README:** update the zig badge ([ea15e54a](https://github.com/indaco/malt/commit/ea15e54a)) ([#750](https://github.com/indaco/malt/pull/750))
- **benchmark:** update results 2026-07-20 ([e57931c4](https://github.com/indaco/malt/commit/e57931c4)) ([#725](https://github.com/indaco/malt/pull/725))

### ✅ Tests

- **regression:** skip etag 304 check when rate-limit window resets ([8e79de84](https://github.com/indaco/malt/commit/8e79de84)) ([#772](https://github.com/indaco/malt/pull/772))
- **outdated:** de-flake the recompute-warm regression against timestamp digits ([ab34db89](https://github.com/indaco/malt/commit/ab34db89)) ([#759](https://github.com/indaco/malt/pull/759))
- give every test fixture a scratch path of its own ([423ad32c](https://github.com/indaco/malt/commit/423ad32c)) ([#746](https://github.com/indaco/malt/pull/746))
- guard against shared fixture paths and leaked scratch ([74405277](https://github.com/indaco/malt/commit/74405277)) ([#744](https://github.com/indaco/malt/pull/744))
- make every scratch fixture path unique per process and call ([6467a642](https://github.com/indaco/malt/commit/6467a642)) ([#741](https://github.com/indaco/malt/pull/741))
- **regressions:** stop the outdated TTL guard reporting a false bug ([a28ed6ba](https://github.com/indaco/malt/commit/a28ed6ba)) ([#737](https://github.com/indaco/malt/pull/737))
- fix give parse-cache tests process-unique temp dirs ([ce1fdd08](https://github.com/indaco/malt/commit/ce1fdd08)) ([#734](https://github.com/indaco/malt/pull/734))
- fail the build when completions drift from the CLI ([4f116e52](https://github.com/indaco/malt/commit/4f116e52)) ([#732](https://github.com/indaco/malt/pull/732))
- harden the regression suite against TTY, token, and timeout flakes ([dbbbb609](https://github.com/indaco/malt/commit/dbbbb609)) ([#720](https://github.com/indaco/malt/pull/720))

### 🏡 Chores

- **dev:** add bench-solo/bench-full recipes, just --list pointer, kcov shell hint ([5bc2ce64](https://github.com/indaco/malt/commit/5bc2ce64)) ([#773](https://github.com/indaco/malt/pull/773))
- update codecov.json ([177b26b9](https://github.com/indaco/malt/commit/177b26b9))
- **help:** document that malt announces backward moves ([5f5725a4](https://github.com/indaco/malt/commit/5f5725a4)) ([#756](https://github.com/indaco/malt/pull/756))
- **help:** document that tap formulas upgrade on tap changes ([c29c166b](https://github.com/indaco/malt/commit/c29c166b)) ([#752](https://github.com/indaco/malt/pull/752))
- **help:** describe outdated by what it compares, not by ordering ([ce0efade](https://github.com/indaco/malt/commit/ce0efade)) ([#751](https://github.com/indaco/malt/pull/751))

### 🤖 CI

- **bench:** stamp skipped peer tools in benchmark tables instead of blanking ([295b3196](https://github.com/indaco/malt/commit/295b3196)) ([#724](https://github.com/indaco/malt/pull/724))
- **release:** auto-cut release/<minor> branch on minor releases ([9cd46f54](https://github.com/indaco/malt/commit/9cd46f54)) ([#723](https://github.com/indaco/malt/pull/723))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.21.0 - 2026-07-18

### Highlights

v0.21.0 makes the `mt tui` dashboard fully mouse-driven, stops it flickering, and speeds up bulk upgrades while keeping the Outdated view honest.

- **Drive the whole dashboard with your mouse.** `mt tui` now tracks the mouse end to end - click the tab bar to switch tabs, click any row on Installed, Search, Outdated, or Services to select it, and scroll the active list with the wheel.
- **A dashboard that no longer flickers.** The dashboard stops clearing the whole screen every frame and instead paints each region to its full rectangle, so the view stays steady as you move around.
- **Faster upgrades that keep Outdated in step.** `mt upgrade` checks every installed package in one request instead of one at a time and decides up front what it can skip - then drops the packages it upgraded from the cached Outdated view so the list never lags behind.
- **Spot a failed background service at a glance.** A service that exited with a failure now shows up as errored, marked with a distinct danger dot in the Services tab.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **upgrade:** check every installed package in one request, not one at a time ([d5f70eba](https://github.com/indaco/malt/commit/d5f70eba)) ([#713](https://github.com/indaco/malt/pull/713))
- **upgrade:** decide what may be skipped before upgrading anything ([7ad9d001](https://github.com/indaco/malt/commit/7ad9d001)) ([#712](https://github.com/indaco/malt/pull/712))
- **tui:** hit-test clicks to Services rows ([8841c734](https://github.com/indaco/malt/commit/8841c734)) ([#709](https://github.com/indaco/malt/pull/709))
- **tui:** switch tabs by clicking the tab bar ([02325686](https://github.com/indaco/malt/commit/02325686)) ([#703](https://github.com/indaco/malt/pull/703))
- **tui:** hit-test clicks to Outdated rows ([9bc95b04](https://github.com/indaco/malt/commit/9bc95b04)) ([#702](https://github.com/indaco/malt/pull/702))
- **tui:** drive the dashboard with mouse clicks ([d40f7182](https://github.com/indaco/malt/commit/d40f7182)) ([#701](https://github.com/indaco/malt/pull/701))
- **tui:** hit-test clicks to Search rows ([38f41414](https://github.com/indaco/malt/commit/38f41414)) ([#700](https://github.com/indaco/malt/pull/700))
- **tui:** hit-test clicks to Installed rows ([c96df2b9](https://github.com/indaco/malt/commit/c96df2b9)) ([#699](https://github.com/indaco/malt/pull/699))
- **tui:** scroll the active list with the mouse wheel ([87649e64](https://github.com/indaco/malt/commit/87649e64)) ([#698](https://github.com/indaco/malt/pull/698))
- **tui:** enable and cleanly restore mouse tracking ([d868405d](https://github.com/indaco/malt/commit/d868405d)) ([#697](https://github.com/indaco/malt/pull/697))
- **tui:** add a pure click-row→list-index helper ([2398e71a](https://github.com/indaco/malt/commit/2398e71a)) ([#696](https://github.com/indaco/malt/pull/696))
- **tui:** decode SGR mouse reports into a typed event ([a8fe13ea](https://github.com/indaco/malt/commit/a8fe13ea)) ([#695](https://github.com/indaco/malt/pull/695))
- **tui/services:** render errored services with a distinct danger dot ([00b16a10](https://github.com/indaco/malt/commit/00b16a10)) ([#685](https://github.com/indaco/malt/pull/685))
- **core/services:** surface a service's last-exit failure as errored ([602482c0](https://github.com/indaco/malt/commit/602482c0)) ([#684](https://github.com/indaco/malt/pull/684))

### 🩹 Fixes

- **tui:** propagate parse-time OOM instead of relabeling it as BadJson ([7c44f4dd](https://github.com/indaco/malt/commit/7c44f4dd)) ([#715](https://github.com/indaco/malt/pull/715))
- **upgrade:** leave the outdated cache alone when nothing was upgraded ([76b24f6b](https://github.com/indaco/malt/commit/76b24f6b)) ([#708](https://github.com/indaco/malt/pull/708))
- **upgrade:** drop upgraded packages from the cached outdated view ([1f761735](https://github.com/indaco/malt/commit/1f761735)) ([#706](https://github.com/indaco/malt/pull/706))
- **cask:** stop a running-app check from misreading other processes ([dca8f352](https://github.com/indaco/malt/commit/dca8f352)) ([#705](https://github.com/indaco/malt/pull/705))
- **tui:** converge installed-tab sub-KB sizes on the canonical shape ([1552d09f](https://github.com/indaco/malt/commit/1552d09f)) ([#692](https://github.com/indaco/malt/pull/692))
- **tui:** stop the filter row ghosting a caret when the query is cleared ([87a1fb38](https://github.com/indaco/malt/commit/87a1fb38)) ([#688](https://github.com/indaco/malt/pull/688))
- **tui:** reset the search phase on an empty read ([5c631cf1](https://github.com/indaco/malt/commit/5c631cf1)) ([#687](https://github.com/indaco/malt/pull/687))
- **tui:** keep the search frame responsive during a slow read ([e32b77d2](https://github.com/indaco/malt/commit/e32b77d2)) ([#686](https://github.com/indaco/malt/pull/686))
- **cli:** stop network commands cleanly on Ctrl-C ([bcea6d26](https://github.com/indaco/malt/commit/bcea6d26)) ([#683](https://github.com/indaco/malt/pull/683))
- **tui:** open the Outdated tab instantly from the cached snapshot ([3a6d8c60](https://github.com/indaco/malt/commit/3a6d8c60)) ([#682](https://github.com/indaco/malt/pull/682))
- **upgrade:** warm the Outdated snapshot even with third-party-tap kegs ([35bacbb2](https://github.com/indaco/malt/commit/35bacbb2)) ([#681](https://github.com/indaco/malt/pull/681))
- **upgrade:** reuse a dry-run's outdated audit to warm the shared snapshot ([78f5bc96](https://github.com/indaco/malt/commit/78f5bc96)) ([#680](https://github.com/indaco/malt/pull/680))
- **tui:** remove the per-frame screen clear so the dashboard stops flickering ([d52cfe4b](https://github.com/indaco/malt/commit/d52cfe4b)) ([#674](https://github.com/indaco/malt/pull/674))
- **tui:** cover every tab's variable-height regions to their rectangle ([4dd5892e](https://github.com/indaco/malt/commit/4dd5892e)) ([#673](https://github.com/indaco/malt/pull/673))
- **tui:** blank the footer's unused rows to its full height ([f0ac6992](https://github.com/indaco/malt/commit/f0ac6992)) ([#672](https://github.com/indaco/malt/pull/672))
- **tui:** blank the list region's unused rows to its full rectangle ([80497c1c](https://github.com/indaco/malt/commit/80497c1c)) ([#671](https://github.com/indaco/malt/pull/671))
- **db:** copy bound text at bind time to remove use-after-free hazard ([c11a1ced](https://github.com/indaco/malt/commit/c11a1ced)) ([#669](https://github.com/indaco/malt/pull/669))
- **store:** version the relocated-keg cache key and reclaim stale versions ([c6eb42d3](https://github.com/indaco/malt/commit/c6eb42d3)) ([#668](https://github.com/indaco/malt/pull/668))
- **linker:** link nested keg subdirectories into the prefix ([fae532cc](https://github.com/indaco/malt/commit/fae532cc)) ([#667](https://github.com/indaco/malt/pull/667))

### 💅 Refactors

- **upgrade:** build the snapshot warm from the audit plan ([cbf8f9a8](https://github.com/indaco/malt/commit/cbf8f9a8)) ([#714](https://github.com/indaco/malt/pull/714))
- **outdated:** expose a row disposition that can prove a row current ([93e0aa1a](https://github.com/indaco/malt/commit/93e0aa1a)) ([#711](https://github.com/indaco/malt/pull/711))
- **upgrade:** report what each package decided instead of poking a counter ([92b4c339](https://github.com/indaco/malt/commit/92b4c339)) ([#707](https://github.com/indaco/malt/pull/707))
- **migrate:** fold the keg INSERT onto the shared recordKeg seam ([399b90de](https://github.com/indaco/malt/commit/399b90de)) ([#694](https://github.com/indaco/malt/pull/694))
- **install:** unify the tap/local keg INSERT onto the canonical seam ([09802b99](https://github.com/indaco/malt/commit/09802b99)) ([#693](https://github.com/indaco/malt/pull/693))
- **tui:** share the ui byte humanizer in the doctor tab ([e11c7b1c](https://github.com/indaco/malt/commit/e11c7b1c)) ([#691](https://github.com/indaco/malt/pull/691))
- **cli:** share the ui byte humanizer across doctor ([e33d5092](https://github.com/indaco/malt/commit/e33d5092)) ([#690](https://github.com/indaco/malt/pull/690))
- **ui:** add a shared byte humanizer in the ui sink ([24d99c12](https://github.com/indaco/malt/commit/24d99c12)) ([#689](https://github.com/indaco/malt/pull/689))
- **outdated:** extract writeSnapshotEntries snapshot-write leaf ([14194dca](https://github.com/indaco/malt/commit/14194dca)) ([#677](https://github.com/indaco/malt/pull/677))
- **ui:** remove the unused Spinner progress renderer ([972a9b9e](https://github.com/indaco/malt/commit/972a9b9e)) ([#676](https://github.com/indaco/malt/pull/676))
- **ui:** bound progress draw appends through a fixed writer ([72080153](https://github.com/indaco/malt/commit/72080153)) ([#675](https://github.com/indaco/malt/pull/675))
- **tui:** add a self-erasing line helper for positioned rows ([f1066b3e](https://github.com/indaco/malt/commit/f1066b3e)) ([#670](https://github.com/indaco/malt/pull/670))
- **install:** build InstallFlags directly in installAll ([5f1b5f8d](https://github.com/indaco/malt/commit/5f1b5f8d)) ([#666](https://github.com/indaco/malt/pull/666))
- **install:** move flag parse + validation into the args leaf ([342ea668](https://github.com/indaco/malt/commit/342ea668)) ([#665](https://github.com/indaco/malt/pull/665))
- **install:** introduce a typed InstallFlags value object ([24bfab9d](https://github.com/indaco/malt/commit/24bfab9d)) ([#662](https://github.com/indaco/malt/pull/662))
- **tui:** replace the per-tab performers with one domain-agnostic perform(cmd) ([3804a4a1](https://github.com/indaco/malt/commit/3804a4a1)) ([#659](https://github.com/indaco/malt/pull/659))
- **tui:** make step return a Cmd value and demote the search basket ops to pure state ([8f5bb1aa](https://github.com/indaco/malt/commit/8f5bb1aa)) ([#658](https://github.com/indaco/malt/pull/658))
- **tui:** add the cmd sink leaf with Cmd, Msg, and a comptime Parsed union ([5b50675b](https://github.com/indaco/malt/commit/5b50675b)) ([#657](https://github.com/indaco/malt/pull/657))
- **tui:** move the installed and search effects into their tabs and drop the hub's parser imports ([f8c9bb45](https://github.com/indaco/malt/commit/f8c9bb45)) ([#656](https://github.com/indaco/malt/pull/656))
- **tui:** move the outdated and services effect groups beside their tabs ([337c4242](https://github.com/indaco/malt/commit/337c4242)) ([#655](https://github.com/indaco/malt/pull/655))
- **tui:** widen the tab contract with a service capability and route it through moduleFor ([479b7c61](https://github.com/indaco/malt/commit/479b7c61)) ([#654](https://github.com/indaco/malt/pull/654))
- **tui:** split the central Store into per-tab Storage ([74a10d9d](https://github.com/indaco/malt/commit/74a10d9d)) ([#653](https://github.com/indaco/malt/pull/653))
- **tui:** add a ctx sink leaf for the shared read-model and effect ports ([021757ab](https://github.com/indaco/malt/commit/021757ab)) ([#652](https://github.com/indaco/malt/pull/652))
- **tui:** let each tab own its background-fetch behavior ([77151678](https://github.com/indaco/malt/commit/77151678)) ([#651](https://github.com/indaco/malt/pull/651))
- **net:** stream a GET response body to a caller sink ([06f9485f](https://github.com/indaco/malt/commit/06f9485f)) ([#647](https://github.com/indaco/malt/pull/647))
- **core:** share SHA-mismatch diagnostics via a streamed check ([316f2171](https://github.com/indaco/malt/commit/316f2171)) ([#646](https://github.com/indaco/malt/pull/646))
- **net:** delegate CountingWriter to any Writer sink ([8e92d5fa](https://github.com/indaco/malt/commit/8e92d5fa)) ([#645](https://github.com/indaco/malt/pull/645))

### 📖 Documentation

- bring v0.20.x release notes to main ([1c4bcaa2](https://github.com/indaco/malt/commit/1c4bcaa2)) ([#716](https://github.com/indaco/malt/pull/716))
- **benchmark:** update results 2026-07-13 ([ff2bb02f](https://github.com/indaco/malt/commit/ff2bb02f)) ([#664](https://github.com/indaco/malt/pull/664))
- **benchmark:** update results 2026-07-13 ([7a867ea9](https://github.com/indaco/malt/commit/7a867ea9)) ([#660](https://github.com/indaco/malt/pull/660))
- **benchmark:** update results 2026-07-10 ([66e971cf](https://github.com/indaco/malt/commit/66e971cf)) ([#648](https://github.com/indaco/malt/pull/648))
- bring v0.20.4 and v0.20.5 release notes to main ([de729309](https://github.com/indaco/malt/commit/de729309)) ([#609](https://github.com/indaco/malt/pull/609))
- bring v0.20.3 release notes to main ([ae422f78](https://github.com/indaco/malt/commit/ae422f78)) ([#588](https://github.com/indaco/malt/pull/588))
- bring v0.20.x release notes to main ([1d2b0724](https://github.com/indaco/malt/commit/1d2b0724)) ([#585](https://github.com/indaco/malt/pull/585))

### ⚡ Performance

- **outdated:** warm the snapshot from the recompute's entries instead of re-auditing ([4bb29f60](https://github.com/indaco/malt/commit/4bb29f60)) ([#678](https://github.com/indaco/malt/pull/678))
- **core:** stream the bottle download to disk while hashing ([bcb9c0a0](https://github.com/indaco/malt/commit/bcb9c0a0)) ([#649](https://github.com/indaco/malt/pull/649))

### ✅ Tests

- **outdated:** fix the cached-outdated regression harness to resolve c_sqlite ([2eeb87d2](https://github.com/indaco/malt/commit/2eeb87d2)) ([#679](https://github.com/indaco/malt/pull/679))
- **tui:** pin the run loop's synchronous Cmd/Msg fast-path ([6cc477f3](https://github.com/indaco/malt/commit/6cc477f3)) ([#661](https://github.com/indaco/malt/pull/661))
- **net:** cover getToWriter's streaming blob-size cap ([9d407051](https://github.com/indaco/malt/commit/9d407051)) ([#650](https://github.com/indaco/malt/pull/650))

### 🏡 Chores

- **regressions:** guard the bulk upgrade path ([427e4e11](https://github.com/indaco/malt/commit/427e4e11)) ([#710](https://github.com/indaco/malt/pull/710))
- **tui:** pin the tab-bar buffer to what the bar can draw ([d25c1e36](https://github.com/indaco/malt/commit/d25c1e36)) ([#704](https://github.com/indaco/malt/pull/704))

### 🤖 CI

- **bench:** publish the shipped release and explain omitted cells ([68f38c5b](https://github.com/indaco/malt/commit/68f38c5b)) ([#663](https://github.com/indaco/malt/pull/663))
- **bench:** pin peer tools to latest release and guard anomalous cold numbers ([0db65630](https://github.com/indaco/malt/commit/0db65630)) ([#644](https://github.com/indaco/malt/pull/644))

### 🎉 New Contributors

- [@gitbutler](https://github.com/gitbutler) made their first contribution in [603f1972](https://github.com/indaco/malt/commit/603f1972)

### ❤️ Contributors

- [@gitbutler](https://github.com/gitbutler)
- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.20.10 - 2026-07-10

### Highlights

v0.20.10 makes `mt doctor --fix` safe to run without second-guessing it, and stops installs from ever fetching a build for the wrong machine.

- **A Doctor `--fix` you can trust.** Repairs now serialize behind the prefix lock and reap orphaned store entries atomically, so a partial or concurrent fix can't corrupt your install or leave a reference row pointing at nothing.
- **No more false repairs.** Doctor leaves an intact symlink alone when its target is only temporarily unreachable, rather than tearing down something you still need.
- **Installs that match your machine.** `mt install` never resolves a tap artifact built for the wrong architecture, so you can't end up with a binary that won't run.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🩹 Fixes

- **doctor:** reap orphan store entries atomically so a partial delete never outlives its ref row ([3a3911b9](https://github.com/indaco/malt/commit/3a3911b9)) ([#643](https://github.com/indaco/malt/pull/643))
- **install:** never resolve a tap artifact for the wrong architecture ([c4750739](https://github.com/indaco/malt/commit/c4750739)) ([#642](https://github.com/indaco/malt/pull/642))
- **doctor:** serialize --fix prefix mutations behind malt.lock ([4aa1e7e9](https://github.com/indaco/malt/commit/4aa1e7e9)) ([#641](https://github.com/indaco/malt/pull/641))
- **doctor:** don't remove an intact symlink whose target is inaccessible ([0942e30b](https://github.com/indaco/malt/commit/0942e30b)) ([#640](https://github.com/indaco/malt/pull/640))
- **doctor:** repair a stale lock by truncating instead of unlinking it ([fb86840d](https://github.com/indaco/malt/commit/fb86840d)) ([#639](https://github.com/indaco/malt/pull/639))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.20.9 - 2026-07-09

### Highlights

v0.20.9 brings malt in step with Homebrew v6's declarative post-install steps and polishes a batch of rough edges in `mt tui`.

- **Compatible with Homebrew v6 install steps.** Homebrew is migrating formulae from Ruby `post_install` blocks to the declarative `post_install_steps` framework - malt now runs those steps natively across install, upgrade, and migrate, so packages keep setting themselves up correctly as upstream converts.
- **A steadier TUI.** Wrapped rows no longer split multi-byte characters, `End` jumps to the last row in every tab, a lone `Esc` resolves immediately, uninstall acts on the package you confirmed - not the live selection - and the terminal is restored cleanly on panic or termination.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🩹 Fixes

- **ui/progress:** make shared progress counters race-free under concurrent repaints ([1c9e7a62](https://github.com/indaco/malt/commit/1c9e7a62)) ([#638](https://github.com/indaco/malt/pull/638))
- **tui:** keep wrapped rows on UTF-8 rune boundaries ([9f338aaa](https://github.com/indaco/malt/commit/9f338aaa)) ([#637](https://github.com/indaco/malt/pull/637))
- **install:** run declarative post-install steps across install, upgrade, and migrate ([675fea29](https://github.com/indaco/malt/commit/675fea29)) ([#636](https://github.com/indaco/malt/pull/636))
- **tui:** make End jump to the last row in every tab ([4cf0d4f7](https://github.com/indaco/malt/commit/4cf0d4f7)) ([#635](https://github.com/indaco/malt/pull/635))
- **tui:** resolve a lone Esc immediately instead of on the next keypress ([9cc4d503](https://github.com/indaco/malt/commit/9cc4d503)) ([#634](https://github.com/indaco/malt/pull/634))
- **tui:** uninstall the package the guard was armed on, not the live selection ([7239deca](https://github.com/indaco/malt/commit/7239deca)) ([#633](https://github.com/indaco/malt/pull/633))
- **tui:** restore the terminal on panic and termination signals ([2a74397e](https://github.com/indaco/malt/commit/2a74397e)) ([#631](https://github.com/indaco/malt/pull/631))

### ✅ Tests

- **install:** stop the Ruby fallback route test reading the live homebrew-core tap ([98dd9777](https://github.com/indaco/malt/commit/98dd9777)) ([#632](https://github.com/indaco/malt/pull/632))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.20.8 - 2026-07-08

### 🩹 Fixes

- **core/sandbox:** grant sandbox writes under resolved roots for symlinked prefixes ([4e1f08df](https://github.com/indaco/malt/commit/4e1f08df)) ([#630](https://github.com/indaco/malt/pull/630))
- **ci:** verify the committed pins manifest instead of re-enumerating live formulas ([5a8c820a](https://github.com/indaco/malt/commit/5a8c820a)) ([#629](https://github.com/indaco/malt/pull/629))
- **core/cellar:** pour bottle etc/var overlays and relocate embedded config paths ([bfa89cac](https://github.com/indaco/malt/commit/bfa89cac)) ([#628](https://github.com/indaco/malt/pull/628))
- **core/dsl:** run post_install against revisioned keg paths and surface command failures ([14ed80f9](https://github.com/indaco/malt/commit/14ed80f9)) ([#626](https://github.com/indaco/malt/pull/626))
- **cli:** route the help command's argument to its command topic ([0329e0e6](https://github.com/indaco/malt/commit/0329e0e6)) ([#625](https://github.com/indaco/malt/pull/625))
- **update:** remove the twin's .old backup and show help without starting the updater ([025d3753](https://github.com/indaco/malt/commit/025d3753)) ([#623](https://github.com/indaco/malt/pull/623))
- **cli:** report overlong unknown commands cleanly instead of panicking ([b7799aaa](https://github.com/indaco/malt/commit/b7799aaa)) ([#622](https://github.com/indaco/malt/pull/622))
- **cli:** forward brew's real exit code and diagnose a broken brew in the fallback ([05b027bf](https://github.com/indaco/malt/commit/05b027bf)) ([#621](https://github.com/indaco/malt/pull/621))
- **update:** report a restored self-update as a clean failure, not a broken rollback ([30c51138](https://github.com/indaco/malt/commit/30c51138)) ([#620](https://github.com/indaco/malt/pull/620))

### 🏡 Chores

- **core:** drop upstream-removed formulas from the pins manifest ([c59b16f9](https://github.com/indaco/malt/commit/c59b16f9)) ([#627](https://github.com/indaco/malt/pull/627))
- **core:** drop upstream-removed formulas from the pins manifest ([12e0f098](https://github.com/indaco/malt/commit/12e0f098)) ([#624](https://github.com/indaco/malt/pull/624))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.20.7 - 2026-07-06

### 🩹 Fixes

- **security:** reject path separators in tap-supplied names and versions ([f8eaef2](https://github.com/indaco/malt/commit/f8eaef2)) ([#618](https://github.com/indaco/malt/pull/618))
- **services:** reject path separators in service label at the validation gate ([c17ad19](https://github.com/indaco/malt/commit/c17ad19)) ([#616](https://github.com/indaco/malt/pull/616))
- **upgrade:** stop spurious "database is locked" when a formula gains a new dependency ([fdb4b5a](https://github.com/indaco/malt/commit/fdb4b5a)) ([#615](https://github.com/indaco/malt/pull/615))
- **security:** enforce the terminal sanitizer's anti-injection guarantee ([4ddb33c](https://github.com/indaco/malt/commit/4ddb33c)) ([#613](https://github.com/indaco/malt/pull/613))

### 🏡 Chores

- **pins:** drop formulae upstream no longer runs post_install for ([693469d](https://github.com/indaco/malt/commit/693469d)) ([#619](https://github.com/indaco/malt/pull/619))
- **pins:** refresh homebrew-core source manifest ([a98b07f](https://github.com/indaco/malt/commit/a98b07f)) ([#614](https://github.com/indaco/malt/pull/614))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.20.6 - 2026-07-03

### 🩹 Fixes

- **bundle:** escape names and versions in JSON, Brewfile and receipt emitters ([b456a2a](https://github.com/indaco/malt/commit/b456a2a)) ([#612](https://github.com/indaco/malt/pull/612))
- **cli/run:** forward the run binary's exit code, args, and failures ([8e4fd68](https://github.com/indaco/malt/commit/8e4fd68)) ([#611](https://github.com/indaco/malt/pull/611))
- **cli:** stop consuming global flags after the -- separator ([6e568f6](https://github.com/indaco/malt/commit/6e568f6)) ([#610](https://github.com/indaco/malt/pull/610))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.20.5 - 2026-07-03

### 🩹 Fixes

- **cask:** prompt visibly and confirm before sudo for PKG casks ([c1dc70c](https://github.com/indaco/malt/commit/c1dc70c)) ([#608](https://github.com/indaco/malt/pull/608))
- **net:** enforce the response size cap before allocating the body ([fab7795](https://github.com/indaco/malt/commit/fab7795)) ([#607](https://github.com/indaco/malt/pull/607))
- **net:** refresh GHCR token and retry once on a 401 blob download ([ac0c9dc](https://github.com/indaco/malt/commit/ac0c9dc)) ([#605](https://github.com/indaco/malt/pull/605))

### 📖 Documentation

- **readme:** improve readability and surface selling points ([ead1522](https://github.com/indaco/malt/commit/ead1522)) ([#604](https://github.com/indaco/malt/pull/604))

### 🏡 Chores

- **just:** set MALT_GITHUB_TOKEN from gh to avoid-limit SKIPs ([7b5ba39](https://github.com/indaco/malt/commit/7b5ba39)) ([#606](https://github.com/indaco/malt/pull/606))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.20.4 - 2026-07-01

### 🩹 Fixes

- **cask:** sweep only the uninstalled cask's own cached versions ([3bbee2a](https://github.com/indaco/malt/commit/3bbee2a)) ([#602](https://github.com/indaco/malt/pull/602))
- **purge:** create nested parent directories for absolute manifest paths ([afe4f79](https://github.com/indaco/malt/commit/afe4f79)) ([#597](https://github.com/indaco/malt/pull/597))
- **backup:** honor symlink-to-directory parents; collapse redundant leaf in writeToPath ([c72fddd](https://github.com/indaco/malt/commit/c72fddd)) ([#596](https://github.com/indaco/malt/pull/596))
- **backup:** create nested parent directories for absolute output paths ([8877bfe](https://github.com/indaco/malt/commit/8877bfe)) ([#593](https://github.com/indaco/malt/pull/593))
- **bundle:** honor explicit create path regardless of --format order ([f7e40e2](https://github.com/indaco/malt/commit/f7e40e2)) ([#592](https://github.com/indaco/malt/pull/592))
- **purge:** credit only successfully-freed bytes on partial wipe ([b09d8e0](https://github.com/indaco/malt/commit/b09d8e0)) ([#591](https://github.com/indaco/malt/pull/591))
- **net:** honor MALT_GITHUB_TOKEN across all GitHub API calls ([03b8936](https://github.com/indaco/malt/commit/03b8936)) ([#590](https://github.com/indaco/malt/pull/590))
- **bundle:** stop trailing comments from aborting Brewfile imports ([685dfb4](https://github.com/indaco/malt/commit/685dfb4)) ([#589](https://github.com/indaco/malt/pull/589))

### 💅 Refactors

- **fs:** extract path_write leaf and route backup/purge/bundle through it ([8bf3f4d](https://github.com/indaco/malt/commit/8bf3f4d)) ([#599](https://github.com/indaco/malt/pull/599))
- **cli:** collapse redundant absolute/relative file-open branches ([b63eed1](https://github.com/indaco/malt/commit/b63eed1)) ([#598](https://github.com/indaco/malt/pull/598))

### ✅ Tests

- **rollback:** isolate sandbox dirs per process to stop tmp-path races ([e9dc930](https://github.com/indaco/malt/commit/e9dc930)) ([#595](https://github.com/indaco/malt/pull/595))

### 🤖 CI

- ci/upgrade-gh-actions (#603) ([9f7b521](https://github.com/indaco/malt/commit/9f7b521))
- fix pins auto-bump 403 on homebrew-core HEAD resolution ([13e50a2](https://github.com/indaco/malt/commit/13e50a2)) ([#594](https://github.com/indaco/malt/pull/594))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.20.3 - 2026-06-30

### 🩹 Fixes

- **search:** collapse mixed-case local exact match to one canonical row ([9475df4](https://github.com/indaco/malt/commit/9475df4)) ([#587](https://github.com/indaco/malt/pull/587))
- **info:** show installed package when both --cask and --formula are set ([5613996](https://github.com/indaco/malt/commit/5613996)) ([#586](https://github.com/indaco/malt/pull/586))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.20.2 - 2026-06-30

### 🩹 Fixes

- **outdated:** detect upstream revision-only bumps on the fetch fallback ([a4be3ec](https://github.com/indaco/malt/commit/a4be3ec)) ([#584](https://github.com/indaco/malt/pull/584))
- **outdated:** refuse stale snapshots after revision-format change ([705fef8](https://github.com/indaco/malt/commit/705fef8)) ([#583](https://github.com/indaco/malt/pull/583))
- **outdated:** keep revision-bumped formulas in cached listing ([4e5fc99](https://github.com/indaco/malt/commit/4e5fc99)) ([#582](https://github.com/indaco/malt/pull/582))
- **install:** fail loudly when a dependency formula can't be fetched ([e5a8fd4](https://github.com/indaco/malt/commit/e5a8fd4)) ([#581](https://github.com/indaco/malt/pull/581))
- **tui:** reword a test comment that tripped the spawn-invariant lint ([02dd65d](https://github.com/indaco/malt/commit/02dd65d)) ([#580](https://github.com/indaco/malt/pull/580))
- **cask:** tell the user when a running app blocks a cask upgrade ([f8900b9](https://github.com/indaco/malt/commit/f8900b9)) ([#579](https://github.com/indaco/malt/pull/579))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.20.1 - 2026-06-29

### 🩹 Fixes

- **tui:** stop in-TUI upgrades failing with database-locked errors ([c4eb77a](https://github.com/indaco/malt/commit/c4eb77a)) ([#578](https://github.com/indaco/malt/pull/578))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.20.0 - 2026-06-29

### Highlights

v0.20.0 widens what `mt outdated` can see, makes it cheaper to run, and hardens upgrades so cleanup never deletes something you still need.

- **`mt outdated` now covers your third-party taps.** Formulae from taps beyond homebrew-core show up alongside everything else - and a fresh `outdated` is fast and cheap, served from a cached versions index and a conditional bulk dump that skips the download when nothing changed.
- **Upgrades that don't lose your packages.** Revisioned kegs survive autoremove, link, promote, and purge; upgrades keep their dependency edges so cleanup can't sweep a live runtime dependency; and a verbose install no longer hangs partway through.
- **Safer against hostile formulae and archives.** A batch of hardening keeps cask tokens, archive entries, and DSL file operations from escaping the keg or following redirects with your credentials.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **outdated:** report outdated formulae from third-party taps ([e5419bb](https://github.com/indaco/malt/commit/e5419bb)) ([#552](https://github.com/indaco/malt/pull/552))
- **tui:** update the outdated list in place after an upgrade ([3cc7f0e](https://github.com/indaco/malt/commit/3cc7f0e)) ([#550](https://github.com/indaco/malt/pull/550))
- **outdated:** resolve core rows from one cached version map ([c281030](https://github.com/indaco/malt/commit/c281030)) ([#549](https://github.com/indaco/malt/pull/549))
- **net:** cache upstream stable and revision in a versions index ([d9a35a8](https://github.com/indaco/malt/commit/d9a35a8)) ([#548](https://github.com/indaco/malt/pull/548))

### 🩹 Fixes

- **update:** never offer a downgrade and refresh stale version notices faster ([fe43aeb](https://github.com/indaco/malt/commit/fe43aeb)) ([#574](https://github.com/indaco/malt/pull/574))
- **update:** only notify when the released version is actually newer ([488f744](https://github.com/indaco/malt/commit/488f744)) ([#573](https://github.com/indaco/malt/pull/573))
- **fs/archive:** extract tarballs with oversized pax extended headers ([b9bb27a](https://github.com/indaco/malt/commit/b9bb27a)) ([#570](https://github.com/indaco/malt/pull/570))
- **rollback:** serialize cask rollback and unify lock-failure diagnostics ([6da69e7](https://github.com/indaco/malt/commit/6da69e7)) ([#569](https://github.com/indaco/malt/pull/569))
- **cli:** keep revisioned kegs intact on autoremove, link, and promote ([7c5e231](https://github.com/indaco/malt/commit/7c5e231)) ([#568](https://github.com/indaco/malt/pull/568))
- **purge:** keep the DB-linked keg when sweeping old versions ([5547bb3](https://github.com/indaco/malt/commit/5547bb3)) ([#567](https://github.com/indaco/malt/pull/567))
- **core/child:** prevent install-path hang on verbose child output ([2502c96](https://github.com/indaco/malt/commit/2502c96)) ([#566](https://github.com/indaco/malt/pull/566))
- **upgrade:** preserve dependency edges so cleanup can't delete live runtime deps ([6d2af48](https://github.com/indaco/malt/commit/6d2af48)) ([#565](https://github.com/indaco/malt/pull/565))
- **migrate:** serialize store-ref bump on the keg DB lock to stop wrong-keg writes ([2423459](https://github.com/indaco/malt/commit/2423459)) ([#564](https://github.com/indaco/malt/pull/564))
- **install:** keep --download-only from pruning the installed keg under --force ([cb16f8d](https://github.com/indaco/malt/commit/cb16f8d)) ([#563](https://github.com/indaco/malt/pull/563))
- **dsl:** mask chmod mode to permission bits instead of narrowing ([ae15332](https://github.com/indaco/malt/commit/ae15332)) ([#562](https://github.com/indaco/malt/pull/562))
- **dsl:** keep a dangling #{ from aborting formula parsing ([9c3e3d8](https://github.com/indaco/malt/commit/9c3e3d8)) ([#561](https://github.com/indaco/malt/pull/561))
- **dsl:** bound parse nesting and user-method call depth ([d1e140e](https://github.com/indaco/malt/commit/d1e140e)) ([#560](https://github.com/indaco/malt/pull/560))
- **dsl:** confine cp/mv/cp_r source paths to the keg ([fcf0488](https://github.com/indaco/malt/commit/fcf0488)) ([#559](https://github.com/indaco/malt/pull/559))
- **macho:** reject fat slice bounds that overflow 32-bit arithmetic ([75b76e1](https://github.com/indaco/malt/commit/75b76e1)) ([#558](https://github.com/indaco/malt/pull/558))
- **cask:** reject path traversal in cask token and version ([a7fecbd](https://github.com/indaco/malt/commit/a7fecbd)) ([#557](https://github.com/indaco/malt/pull/557))
- **net:** stop credential headers from following cross-domain redirects ([d562eea](https://github.com/indaco/malt/commit/d562eea)) ([#556](https://github.com/indaco/malt/pull/556))
- **fs/archive:** reject pax-overridden symlink targets that escape the extract dir ([5d5e766](https://github.com/indaco/malt/commit/5d5e766)) ([#555](https://github.com/indaco/malt/pull/555))
- **dsl:** stop FS builtins from writing through symlinks out of the keg ([d56df12](https://github.com/indaco/malt/commit/d56df12)) ([#554](https://github.com/indaco/malt/pull/554))
- **tui:** upgrade the kind the user selected, not formula-first ([88e910c](https://github.com/indaco/malt/commit/88e910c)) ([#551](https://github.com/indaco/malt/pull/551))
- **doctor:** downgrade filesystem-vs-DB findings while an operation is in flight ([59c2afe](https://github.com/indaco/malt/commit/59c2afe)) ([#542](https://github.com/indaco/malt/pull/542))
- **doctor:** explain why --fix could not sweep an orphan instead of a silent no-op ([55bc626](https://github.com/indaco/malt/commit/55bc626)) ([#541](https://github.com/indaco/malt/pull/541))
- **doctor:** stop flagging warm store bytes as unpurgeable orphans ([b0ae403](https://github.com/indaco/malt/commit/b0ae403)) ([#539](https://github.com/indaco/malt/pull/539))

### 💅 Refactors

- **upgrade:** summarise the bulk run instead of one line per current package ([a717243](https://github.com/indaco/malt/commit/a717243)) ([#546](https://github.com/indaco/malt/pull/546))

### 📖 Documentation

- present the install-verify pin as an example tag ([173132a](https://github.com/indaco/malt/commit/173132a)) ([#543](https://github.com/indaco/malt/pull/543))

### ⚡ Performance

- **net:** conditional-GET the bulk dump so a fresh outdated is cheap ([f602994](https://github.com/indaco/malt/commit/f602994)) ([#553](https://github.com/indaco/malt/pull/553))

### ✅ Tests

- **smoke:** treat any HTTPS status as TLS success in ssl python smoke ([7e627ef](https://github.com/indaco/malt/commit/7e627ef)) ([#572](https://github.com/indaco/malt/pull/572))
- **clonefile:** stop full-suite flake from shared /tmp paths ([34b38be](https://github.com/indaco/malt/commit/34b38be)) ([#547](https://github.com/indaco/malt/pull/547))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.19.3 - 2026-06-25

### 🩹 Fixes

- **tui:** keep the dashboard responsive — never freeze input behind a slow audit ([37ff4d9](https://github.com/indaco/malt/commit/37ff4d9)) ([#545](https://github.com/indaco/malt/pull/545))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.19.2 - 2026-06-24

### 🩹 Fixes

- **upgrade:** upgrade every named package instead of only the first ([7e7c227](https://github.com/indaco/malt/commit/7e7c227)) ([#544](https://github.com/indaco/malt/pull/544))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.19.1 - 2026-06-24

### 🩹 Fixes

- **doctor:** downgrade filesystem-vs-DB findings while an operation is in flight ([d64bdb1](https://github.com/indaco/malt/commit/d64bdb1)) ([#542](https://github.com/indaco/malt/pull/542))
- **doctor:** explain why --fix could not sweep an orphan instead of a silent no-op ([76dc88e](https://github.com/indaco/malt/commit/76dc88e)) ([#541](https://github.com/indaco/malt/pull/541))
- **doctor:** stop flagging warm store bytes as unpurgeable orphans ([b9db5bf](https://github.com/indaco/malt/commit/b9db5bf)) ([#539](https://github.com/indaco/malt/pull/539))

### 📖 Documentation

- present the install-verify pin as an example tag ([f73e3c7](https://github.com/indaco/malt/commit/f73e3c7)) ([#543](https://github.com/indaco/malt/pull/543))

### 🏡 Chores

- **pins:** resync manifest with committed core pin ([8f04587](https://github.com/indaco/malt/commit/8f04587)) ([#540](https://github.com/indaco/malt/pull/540))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.19.0 - 2026-06-22

### Highlights

v0.19.0 sharpens the `mt tui` dashboard - a calmer Doctor, clearer tabs, and a Search basket you fill across queries - adds scheduled background services, and ships `man malt`.

- **Search once, install the lot.** The Search tab now keeps your selection as you change queries, collecting matches into a basket you can review, clear, and install in one go - no more re-finding packages one at a time.
- **A Doctor you can read at a glance.** The Doctor tab opens with a health band above the findings, tells apart all-clear from no-data, and surfaces how much cache and cask disk you can reclaim - and every list tab now carries a clear column heading.
- **Background services on a schedule.** Services can run on a fixed interval or a cron-style calendar, and `mt services` lists each service's schedule alongside it.
- **`man malt`, built in.** A single man page now ships with every install - tarball and cask alike - so `man malt` works straight after setup.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **tui:** basket view with clear and remove keys ([f4f0a1a](https://github.com/indaco/malt/commit/f4f0a1a)) ([#530](https://github.com/indaco/malt/pull/530))
- **tui:** install the cross-query Search basket ([2255843](https://github.com/indaco/malt/commit/2255843)) ([#529](https://github.com/indaco/malt/pull/529))
- **tui:** persist Search selection across queries ([9295f35](https://github.com/indaco/malt/commit/9295f35)) ([#528](https://github.com/indaco/malt/pull/528))
- **cask:** remove placed font files on uninstall ([c290b62](https://github.com/indaco/malt/commit/c290b62)) ([#523](https://github.com/indaco/malt/pull/523))
- **cask:** install font casks into the user Fonts directory ([060959d](https://github.com/indaco/malt/commit/060959d)) ([#519](https://github.com/indaco/malt/pull/519))
- **core/cask:** add font-artifact leaf module ([8976eae](https://github.com/indaco/malt/commit/8976eae)) ([#518](https://github.com/indaco/malt/pull/518))
- **cli/services:** surface a service's schedule in list output ([5b66e2b](https://github.com/indaco/malt/commit/5b66e2b)) ([#516](https://github.com/indaco/malt/pull/516))
- **core/services:** support run_type :cron via StartCalendarInterval ([e2d89d7](https://github.com/indaco/malt/commit/e2d89d7)) ([#515](https://github.com/indaco/malt/pull/515))
- **core/services:** add Schedule type and StartInterval support ([9ed1264](https://github.com/indaco/malt/commit/9ed1264)) ([#513](https://github.com/indaco/malt/pull/513))
- **install:** place man malt page in the install prefix ([254469a](https://github.com/indaco/malt/commit/254469a)) ([#512](https://github.com/indaco/malt/pull/512))
- **release:** ship man malt via tarball and cask ([3f04d0e](https://github.com/indaco/malt/commit/3f04d0e)) ([#511](https://github.com/indaco/malt/pull/511))
- **man:** generate and commit a single man malt page ([7262b00](https://github.com/indaco/malt/commit/7262b00)) ([#508](https://github.com/indaco/malt/pull/508))
- **tui:** clearer list tabs and a calmer Doctor ([5fc4295](https://github.com/indaco/malt/commit/5fc4295)) ([#506](https://github.com/indaco/malt/pull/506))
- **tui/doctor:** surface reclaimable cache/cask disk in the band ([29555d5](https://github.com/indaco/malt/commit/29555d5)) ([#504](https://github.com/indaco/malt/pull/504))
- **tui/doctor:** distinguish all-clear from no-data ([8036eb1](https://github.com/indaco/malt/commit/8036eb1)) ([#500](https://github.com/indaco/malt/pull/500))
- **tui/doctor:** add a health band above the findings list ([804feb6](https://github.com/indaco/malt/commit/804feb6)) ([#499](https://github.com/indaco/malt/pull/499))

### 🩹 Fixes

- **cask:** restore font files on rollback and reinstall ([dcb852f](https://github.com/indaco/malt/commit/dcb852f)) ([#521](https://github.com/indaco/malt/pull/521))
- **tui:** wrap the footer help line so a tab's action keys survive a narrow terminal ([2ac73a6](https://github.com/indaco/malt/commit/2ac73a6)) ([#517](https://github.com/indaco/malt/pull/517))
- **migrate:** migrate renamed homebrew-core kegs instead of failing ([2c7f552](https://github.com/indaco/malt/commit/2c7f552)) ([#514](https://github.com/indaco/malt/pull/514))
- **outdated:** keep the outdated list in step with mt upgrade ([2a95e7a](https://github.com/indaco/malt/commit/2a95e7a)) ([#507](https://github.com/indaco/malt/pull/507))
- **doctor:** drop the noisy SSL CA bundle row until ca-certificates is installed ([f21f2d0](https://github.com/indaco/malt/commit/f21f2d0)) ([#503](https://github.com/indaco/malt/pull/503))
- **doctor:** keep --json a clean stdout-only stream ([dc51b0c](https://github.com/indaco/malt/commit/dc51b0c)) ([#502](https://github.com/indaco/malt/pull/502))
- **tui:** refresh the Doctor tab after a fix instead of treating its severity exit as a failure ([1de0813](https://github.com/indaco/malt/commit/1de0813)) ([#498](https://github.com/indaco/malt/pull/498))

### 💅 Refactors

- **tui/doctor:** rescale the health histogram and break reclaimable into labelled lines ([015489c](https://github.com/indaco/malt/commit/015489c)) ([#505](https://github.com/indaco/malt/pull/505))
- **tui/doctor:** parse cask_history, tap_cache, taps into Stats ([429ff57](https://github.com/indaco/malt/commit/429ff57)) ([#501](https://github.com/indaco/malt/pull/501))

### 📖 Documentation

- **benchmark:** update results 2026-06-22 ([d49455b](https://github.com/indaco/malt/commit/d49455b)) ([#526](https://github.com/indaco/malt/pull/526))
- docs/tui-demo (#535) ([4cda1b9](https://github.com/indaco/malt/commit/4cda1b9))
- sharpen README positioning and align CLI help, man, and completions ([7880549](https://github.com/indaco/malt/commit/7880549)) ([#527](https://github.com/indaco/malt/pull/527))

### ✅ Tests

- **e2e:** keep TUI delegation roundtrip green under full-suite load ([292c687](https://github.com/indaco/malt/commit/292c687)) ([#536](https://github.com/indaco/malt/pull/536))
- fix - stop parallel outdated_test runs from clobbering each other's cache ([a39728a](https://github.com/indaco/malt/commit/a39728a)) ([#534](https://github.com/indaco/malt/pull/534))
- **cask:** e2e and regression coverage for font casks ([b81692b](https://github.com/indaco/malt/commit/b81692b)) ([#524](https://github.com/indaco/malt/pull/524))

### 🏡 Chores

- **pins:** resync manifest with the committed core pin ([b0e1944](https://github.com/indaco/malt/commit/b0e1944)) ([#537](https://github.com/indaco/malt/pull/537))
- update codecov.json ([6017ac4](https://github.com/indaco/malt/commit/6017ac4))
- **devbox:** add vhs and imagemagick ([757d9f9](https://github.com/indaco/malt/commit/757d9f9)) ([#533](https://github.com/indaco/malt/pull/533))
- **pins:** update pins and homebrew core commit sha ([368f998](https://github.com/indaco/malt/commit/368f998)) ([#532](https://github.com/indaco/malt/pull/532))
- **devbox:** bump devbox schema and package lock ([9ecdb41](https://github.com/indaco/malt/commit/9ecdb41)) ([#531](https://github.com/indaco/malt/pull/531))
- **release:** regenerate man page on version bump ([c4ee8df](https://github.com/indaco/malt/commit/c4ee8df)) ([#510](https://github.com/indaco/malt/pull/510))
- track dist/man ([0358260](https://github.com/indaco/malt/commit/0358260)) ([#509](https://github.com/indaco/malt/pull/509))

### 🤖 CI

- report coverage to Codecov ([ec61f4e](https://github.com/indaco/malt/commit/ec61f4e)) ([#525](https://github.com/indaco/malt/pull/525))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.18.0 - 2026-06-16

### Highlights

v0.18.0 makes malt's colours yours - load a palette you wrote yourself - and sharpens the `mt tui` dashboard so it reads at a glance.

- **Bring your own theme.** Beyond the named palettes, malt now loads custom theme files and resolves them by name, parsing and validating your own colour values. Point `MALT_THEME` at a palette you defined and the whole CLI and dashboard follow it - plus a new built-in Everforest Dark.
- **A dashboard you can read at a glance.** `mt tui` now opens with a header showing name, version, prefix, and live keg counts that refresh after an install, animates loading with a spinner, and paints every selection highlight in your active theme - matching the tab you're on.
- **Installs that never link an empty keg.** Tap formulas kept at the repository root now resolve, and a source-built tap formula is refused outright instead of linking an empty keg.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- add everforest dark theme ([cf49c34](https://github.com/indaco/malt/commit/cf49c34)) ([#494](https://github.com/indaco/malt/pull/494))
- **ui:** load user theme files and resolve custom themes by name ([79d21e9](https://github.com/indaco/malt/commit/79d21e9)) ([#476](https://github.com/indaco/malt/pull/476))
- **ui:** parse and validate custom-theme colour values into SGR ([d5177a7](https://github.com/indaco/malt/commit/d5177a7)) ([#475](https://github.com/indaco/malt/pull/475))

### 🩹 Fixes

- **tui:** match the default-theme selection highlight to the active tab ([3c996c3](https://github.com/indaco/malt/commit/3c996c3)) ([#492](https://github.com/indaco/malt/pull/492))
- **tui:** refresh the header keg count after a cross-tab install ([7a0b99a](https://github.com/indaco/malt/commit/7a0b99a)) ([#491](https://github.com/indaco/malt/pull/491))
- **tui:** paint the dashboard chrome before the initial Installed load ([8d93f8c](https://github.com/indaco/malt/commit/8d93f8c))
- **install:** refuse source-built tap formulas instead of linking an empty keg ([c94690b](https://github.com/indaco/malt/commit/c94690b)) ([#482](https://github.com/indaco/malt/pull/482))
- **install:** resolve tap formulas kept at the repository root ([c5396fd](https://github.com/indaco/malt/commit/c5396fd)) ([#481](https://github.com/indaco/malt/pull/481))
- **tui:** colour the selected-row highlight with the active theme ([8d8cc79](https://github.com/indaco/malt/commit/8d8cc79)) ([#477](https://github.com/indaco/malt/pull/477))
- **ui/progress:** repaint bars on terminal resize instead of corrupting output ([03f3622](https://github.com/indaco/malt/commit/03f3622)) ([#474](https://github.com/indaco/malt/pull/474))
- **ui/progress:** size the download bar to terminal width ([fe6de3b](https://github.com/indaco/malt/commit/fe6de3b)) ([#472](https://github.com/indaco/malt/pull/472))

### 💅 Refactors

- **tui:** show the launch header counts without the heavy tab loads ([b5ef45c](https://github.com/indaco/malt/commit/b5ef45c))
- **ui:** extract terminal-size + SIGWINCH tracking into a leaf ([dd4d665](https://github.com/indaco/malt/commit/dd4d665)) ([#471](https://github.com/indaco/malt/pull/471))

### 📖 Documentation

- update code coverage badge ([b54110e](https://github.com/indaco/malt/commit/b54110e))
- **benchmark:** update results 2026-06-16 ([f4f9d53](https://github.com/indaco/malt/commit/f4f9d53)) ([#496](https://github.com/indaco/malt/pull/496))
- **readme:** add a themed CLI + mt tui gallery ([1237e0c](https://github.com/indaco/malt/commit/1237e0c)) ([#495](https://github.com/indaco/malt/pull/495))
- **readme:** update reading flow ([3148002](https://github.com/indaco/malt/commit/3148002)) ([#487](https://github.com/indaco/malt/pull/487))

### 🏡 Chores

- **pins:** update pins and homebrew core commit sha ([654de60](https://github.com/indaco/malt/commit/654de60)) ([#493](https://github.com/indaco/malt/pull/493))
- auto-sync version into build.zig.zon and README on bump ([a62b190](https://github.com/indaco/malt/commit/a62b190)) ([#486](https://github.com/indaco/malt/pull/486))
- **tui:** animate the lazy-load indicator with a spinner ([0124c0f](https://github.com/indaco/malt/commit/0124c0f)) ([#485](https://github.com/indaco/malt/pull/485))
- **tui:** show a header bar with name, version, prefix and counts ([a8c689d](https://github.com/indaco/malt/commit/a8c689d)) ([#484](https://github.com/indaco/malt/pull/484))
- **pins:** update pins and homebrew core commit sha ([98da073](https://github.com/indaco/malt/commit/98da073)) ([#480](https://github.com/indaco/malt/pull/480))
- **pins:** update pins and homebrew core commit sha ([c2e3676](https://github.com/indaco/malt/commit/c2e3676)) ([#473](https://github.com/indaco/malt/pull/473))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.17.0 - 2026-06-09

### Highlights

v0.17.0 gives malt a face: a built-in terminal dashboard you can drive entirely from the keyboard - and paint in your own colours, dashboard and CLI alike.

- **A dashboard built in, `mt tui`.** Browse installed packages, upgrade what's outdated, start and stop services, run doctor fixes, and search-and-install new packages - all from one resize-aware screen. No daemon, no companion binary: every action delegates back to the real CLI, so what you see is what `mt` does. See [Interactive dashboard](https://github.com/indaco/malt#interactive-dashboard).
- **Theme everything, not just the dashboard.** `MALT_THEME` now colours all of malt's output - nine named palettes (Dracula, Catppuccin, Rosé Pine, Nord, Tokyo Night, Gruvbox, and more), so `mt outdated` and `mt tui` render in the same colours.
- **Services start from the right formulae.** Background services now register against the real installed formula, so `mt services` lists and controls what's actually there.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **ui:** apply MALT_THEME named palettes to CLI output, not just the TUI ([35f722e](https://github.com/indaco/malt/commit/35f722e)) ([#464](https://github.com/indaco/malt/pull/464))
- **tui:** search multi-select & info, loading state, and pane polish ([ca29f1e](https://github.com/indaco/malt/commit/ca29f1e)) ([#463](https://github.com/indaco/malt/pull/463))
- **tui:** themeable palette via MALT_THEME and Search-first tabs ([3d53be6](https://github.com/indaco/malt/commit/3d53be6)) ([#458](https://github.com/indaco/malt/pull/458))
- **tui:** search and install packages from a new tab ([228724e](https://github.com/indaco/malt/commit/228724e)) ([#456](https://github.com/indaco/malt/pull/456))
- **json:** version mt search --json and unify results with installed state ([9346955](https://github.com/indaco/malt/commit/9346955)) ([#455](https://github.com/indaco/malt/pull/455))
- **tui:** doctor tab with per-finding fix ([b6a1e8b](https://github.com/indaco/malt/commit/b6a1e8b)) ([#454](https://github.com/indaco/malt/pull/454))
- **tui:** services tab with start/stop/restart ([8d3baf3](https://github.com/indaco/malt/commit/8d3baf3)) ([#453](https://github.com/indaco/malt/pull/453))
- **tui:** outdated tab with multi-select upgrade ([3c6b96b](https://github.com/indaco/malt/commit/3c6b96b)) ([#451](https://github.com/indaco/malt/pull/451))
- **tui:** surface recoverable mt/parse failures without exiting ([5d7a92c](https://github.com/indaco/malt/commit/5d7a92c)) ([#450](https://github.com/indaco/malt/pull/450))
- **tui:** installed packages tab with detail pane ([14c2b52](https://github.com/indaco/malt/commit/14c2b52)) ([#448](https://github.com/indaco/malt/pull/448))
- **tui:** delegate mutations to mt and refresh after ([4dfb364](https://github.com/indaco/malt/commit/4dfb364)) ([#447](https://github.com/indaco/malt/pull/447))
- **tui:** app shell with tab bar, filter, and mt tui subcommand ([7553dde](https://github.com/indaco/malt/commit/7553dde)) ([#446](https://github.com/indaco/malt/pull/446))
- **tui:** responsive layout and scrollable list ([e31410e](https://github.com/indaco/malt/commit/e31410e)) ([#445](https://github.com/indaco/malt/pull/445))
- **tui:** keyboard input decoder ([9d7c2e1](https://github.com/indaco/malt/commit/9d7c2e1)) ([#444](https://github.com/indaco/malt/pull/444))
- **tui:** terminal control primitives with resize awareness ([c6b8923](https://github.com/indaco/malt/commit/c6b8923)) ([#443](https://github.com/indaco/malt/pull/443))
- **json:** add schema_version to read-command JSON output ([231a423](https://github.com/indaco/malt/commit/231a423)) ([#442](https://github.com/indaco/malt/pull/442))
- **doctor:** allow fixing a single finding by id ([c5f2c4f](https://github.com/indaco/malt/commit/c5f2c4f)) ([#441](https://github.com/indaco/malt/pull/441))
- **doctor:** emit structured findings in JSON output ([f73a5fb](https://github.com/indaco/malt/commit/f73a5fb)) ([#440](https://github.com/indaco/malt/pull/440))
- **info:** expose the dependency list in JSON for installed packages ([7af0826](https://github.com/indaco/malt/commit/7af0826)) ([#439](https://github.com/indaco/malt/pull/439))
- **list:** add pinned, size, and linked status to JSON output ([0f42c3e](https://github.com/indaco/malt/commit/0f42c3e)) ([#438](https://github.com/indaco/malt/pull/438))
- **outdated:** emit a single unified JSON array for formulae and casks ([bc35d15](https://github.com/indaco/malt/commit/bc35d15)) ([#437](https://github.com/indaco/malt/pull/437))

### 🩹 Fixes

- **services:** register background services from real formulae ([91d2fec](https://github.com/indaco/malt/commit/91d2fec)) ([#467](https://github.com/indaco/malt/pull/467))
- **tui:** first-pass dashboard usability fixes ([88f7e8a](https://github.com/indaco/malt/commit/88f7e8a)) ([#462](https://github.com/indaco/malt/pull/462))
- **tui:** open the dashboard on a fresh prefix instead of crashing ([2e7b9cb](https://github.com/indaco/malt/commit/2e7b9cb)) ([#459](https://github.com/indaco/malt/pull/459))
- **smoke:** put install prefix bin on PATH so doctor stays green ([6f8c3b3](https://github.com/indaco/malt/commit/6f8c3b3)) ([#449](https://github.com/indaco/malt/pull/449))

### 📖 Documentation

- update readme and demo with tui ([57425b3](https://github.com/indaco/malt/commit/57425b3)) ([#469](https://github.com/indaco/malt/pull/469))
- **tui:** document mt tui and reconcile the size budget ([171d77c](https://github.com/indaco/malt/commit/171d77c)) ([#461](https://github.com/indaco/malt/pull/461))

### ✅ Tests

- **uses:** isolate the temp database per process ([dd958db](https://github.com/indaco/malt/commit/dd958db)) ([#468](https://github.com/indaco/malt/pull/468))
- **tui:** PTY end-to-end resize and delegation coverage ([29ad639](https://github.com/indaco/malt/commit/29ad639)) ([#457](https://github.com/indaco/malt/pull/457))
- pin two network-flaky tests offline for deterministic runs ([de4eb84](https://github.com/indaco/malt/commit/de4eb84)) ([#452](https://github.com/indaco/malt/pull/452))

### 🏡 Chores

- refresh source pins and harden maintenance tooling ([6259653](https://github.com/indaco/malt/commit/6259653)) ([#466](https://github.com/indaco/malt/pull/466))
- **devbox:** bump devbox schema and package lock ([9532b11](https://github.com/indaco/malt/commit/9532b11)) ([#465](https://github.com/indaco/malt/pull/465))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.16.0 - 2026-06-04

### Highlights

v0.16.0 frees your taps from GitHub - they can now live on any major forge - and smooths the first run after a Homebrew install.

- **Taps on any major forge.** Third-party taps resolve through the forge API - no full clone - on GitHub, GitLab (incl. self-hosted), Codeberg/Forgejo/Gitea, and Gogs, each with its own token for private taps. See [Supported forges](https://github.com/indaco/malt#supported-forges).
- **A cleaner setup after `brew install`.** The cask now lands in a usable prefix and points you at a PATH that works, and the first failed install reports its real cause instead of phantom lock contention.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **core/forge:** resolve taps hosted on Gogs ([7988a38](https://github.com/indaco/malt/commit/7988a38)) ([#432](https://github.com/indaco/malt/pull/432))
- **core/tap:** validate a tap pin against its own forge ([a04e23e](https://github.com/indaco/malt/commit/a04e23e)) ([#428](https://github.com/indaco/malt/pull/428))
- **cli/install:** derive tap version from GitLab/Gitea archive URLs ([662c2e1](https://github.com/indaco/malt/commit/662c2e1)) ([#427](https://github.com/indaco/malt/pull/427))
- **core/forge:** resolve taps hosted on Codeberg/Forgejo ([5ed8f5e](https://github.com/indaco/malt/commit/5ed8f5e)) ([#425](https://github.com/indaco/malt/pull/425))
- **core/forge:** resolve taps hosted on GitLab, including self-hosted ([16d5fa2](https://github.com/indaco/malt/commit/16d5fa2)) ([#424](https://github.com/indaco/malt/pull/424))
- **cli/tap:** register taps on GitLab/Codeberg via --host ([694b59d](https://github.com/indaco/malt/commit/694b59d)) ([#421](https://github.com/indaco/malt/pull/421))
- **db,core/tap:** persist the forge host for each tap ([4881ba2](https://github.com/indaco/malt/commit/4881ba2)) ([#420](https://github.com/indaco/malt/pull/420))

### 🩹 Fixes

- guide cask users to a usable prefix and a working PATH ([3249f29](https://github.com/indaco/malt/commit/3249f29)) ([#435](https://github.com/indaco/malt/pull/435))
- **cli:** replace phantom lock-contention errors with the real cause ([3cf273c](https://github.com/indaco/malt/commit/3cf273c)) ([#434](https://github.com/indaco/malt/pull/434))

### 💅 Refactors

- **core/forge:** rename the Gitea-family forge to gitea ([cdbe65f](https://github.com/indaco/malt/commit/cdbe65f)) ([#431](https://github.com/indaco/malt/pull/431))
- **core/tap:** name the tap's own forge in resolve errors ([e54b9e3](https://github.com/indaco/malt/commit/e54b9e3)) ([#429](https://github.com/indaco/malt/pull/429))
- **net,core/forge:** attach forge auth explicitly, harden host-match ([919a67e](https://github.com/indaco/malt/commit/919a67e)) ([#423](https://github.com/indaco/malt/pull/423))
- **core:** extract a forge seam for tap URL/HEAD/auth resolution ([beff3fa](https://github.com/indaco/malt/commit/beff3fa)) ([#418](https://github.com/indaco/malt/pull/418))

### 📖 Documentation

- document supported tap forges and the archive-pin caveat ([80a0bb6](https://github.com/indaco/malt/commit/80a0bb6)) ([#430](https://github.com/indaco/malt/pull/430))
- **readme:** document GitLab and Codeberg forge token env vars ([d13409a](https://github.com/indaco/malt/commit/d13409a)) ([#426](https://github.com/indaco/malt/pull/426))

### 🏡 Chores

- **pins:** sync the homebrew-core manifest with the pinned commit ([75fd910](https://github.com/indaco/malt/commit/75fd910)) ([#433](https://github.com/indaco/malt/pull/433))
- **pins:** drop node@20/22/24 from the post-install allowlist ([4129a5f](https://github.com/indaco/malt/commit/4129a5f)) ([#422](https://github.com/indaco/malt/pull/422))

### 🤖 CI

- bump sigstore/cosign-installer from 4.1.1 to 4.1.2 ([2a67c80](https://github.com/indaco/malt/commit/2a67c80)) ([#419](https://github.com/indaco/malt/pull/419))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@dependabot[bot]](https://github.com/dependabot[bot])

## v0.15.0 - 2026-06-02

### Highlights

v0.15.0 lets a malt prefix stand on its own - one that was never seeded from a Homebrew install now completes a TLS handshake, keeps borrowed binaries off your PATH, and pulls in any GitHub tap without renaming the repo.

- **A malt-only prefix now speaks HTTPS.** malt provisions the OpenSSL CA bundle natively, so `cert.pem` lands without a side install of Homebrew - the chicken-and-egg that broke TLS in a clean prefix is gone.
- **Your PATH only shows what you asked for.** Dependency-only kegs stay out of `prefix/bin` and `prefix/sbin`; binaries pulled in to satisfy another formula no longer leak into your shell.
- **Bring any GitHub tap in, as-is.** Third-party taps work without the `homebrew-` repo prefix - point malt at `owner/repo` and tap it, no renaming required.
- **Daily verbs filled in.** `mt reinstall <pkg>` is a first-class verb, `mt outdated` takes a `--tap` filter, plain-text backups now carry services, and a slug-shaped typo gets a malt hint instead of brew's help.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **core:** provision the OpenSSL CA bundle natively so HTTPS works in a malt prefix ([b10317c](https://github.com/indaco/malt/commit/b10317c)) ([#404](https://github.com/indaco/malt/pull/404))
- **core/linker:** isolate dependency-only kegs from prefix/bin and prefix/sbin ([9a99e89](https://github.com/indaco/malt/commit/9a99e89)) ([#402](https://github.com/indaco/malt/pull/402))
- **core/tap,cli/tap:** accept third-party taps without the homebrew- prefix ([27d313c](https://github.com/indaco/malt/commit/27d313c)) ([#399](https://github.com/indaco/malt/pull/399))
- **cli/backup:** include services in plain-text backup ([bda818a](https://github.com/indaco/malt/commit/bda818a)) ([#398](https://github.com/indaco/malt/pull/398))
- **cli:** add mt reinstall <pkg> as a first-class verb ([d2ae6e4](https://github.com/indaco/malt/commit/d2ae6e4)) ([#397](https://github.com/indaco/malt/pull/397))
- mt outdated tap filter ([26b3ea2](https://github.com/indaco/malt/commit/26b3ea2)) ([#396](https://github.com/indaco/malt/pull/396))

### 🩹 Fixes

- **core/dsl:** confine native post_install spawns, not just the system-ruby path ([b66ceca](https://github.com/indaco/malt/commit/b66ceca)) ([#415](https://github.com/indaco/malt/pull/415))
- **core/dsl:** implement rm_f and Homebrew-shaped install_symlink ([00a1b61](https://github.com/indaco/malt/commit/00a1b61)) ([#403](https://github.com/indaco/malt/pull/403))
- **cli:** malt-native context for every unknown command ([667d843](https://github.com/indaco/malt/commit/667d843)) ([#401](https://github.com/indaco/malt/pull/401))

### 💅 Refactors

- **ui/progress:** render every download through one progress-bar primitive ([e0a5ec3](https://github.com/indaco/malt/commit/e0a5ec3)) ([#416](https://github.com/indaco/malt/pull/416))
- **core/ruby:** split detect, source, and spawn ([d0951fe](https://github.com/indaco/malt/commit/d0951fe)) ([#412](https://github.com/indaco/malt/pull/412))
- **core/dsl:** make FallbackLog record-only, render in callers ([f4e3217](https://github.com/indaco/malt/commit/f4e3217)) ([#411](https://github.com/indaco/malt/pull/411))
- **cli/install:** route installAll through an OutputSink ([d07cac3](https://github.com/indaco/malt/commit/d07cac3)) ([#409](https://github.com/indaco/malt/pull/409))
- **core/dsl:** gate process.system through the sandbox ([6bb4740](https://github.com/indaco/malt/commit/6bb4740)) ([#408](https://github.com/indaco/malt/pull/408))
- **net:** import HttpClientPool from its own module, drop the client shim ([221a726](https://github.com/indaco/malt/commit/221a726)) ([#407](https://github.com/indaco/malt/pull/407))
- **net/client:** add HttpClient.initWith for test injection ([6417228](https://github.com/indaco/malt/commit/6417228)) ([#406](https://github.com/indaco/malt/pull/406))
- **net/client:** extract HttpClientPool to its own module ([8fd6a7d](https://github.com/indaco/malt/commit/8fd6a7d)) ([#405](https://github.com/indaco/malt/pull/405))

### 📖 Documentation

- update coverage badge ([335ab8c](https://github.com/indaco/malt/commit/335ab8c))
- **benchmark:** update results 2026-06-01 ([c08bdd8](https://github.com/indaco/malt/commit/c08bdd8)) ([#410](https://github.com/indaco/malt/pull/410))
- tighter README with onboarding-first ordering ([01c6321](https://github.com/indaco/malt/commit/01c6321)) ([#400](https://github.com/indaco/malt/pull/400))

### 🏡 Chores

- **pins:** bump homebrew-core pin to fa03f08e96e3 ([213f7f5](https://github.com/indaco/malt/commit/213f7f5)) ([#414](https://github.com/indaco/malt/pull/414))
- **pins:** refresh post_install manifest ([460ea16](https://github.com/indaco/malt/commit/460ea16)) ([#413](https://github.com/indaco/malt/pull/413))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.14.0 - 2026-05-27

### Highlights

v0.14.0 makes malt usable on the networks people actually have - corporate proxies, air-gapped fleets, and machines that go offline without warning.

- **Corporate mirrors via env.** `MALT_API_DOMAIN` and `MALT_BOTTLE_DOMAIN` retarget the formula API and bottle downloads at internal mirrors.
- **`mt install --download-only` prefetches bottles, casks, and tap formulas without installing them.** The seed step for air-gapped machines fed from a connected one.
- **`MALT_OFFLINE` / `--offline` makes refusal a contract.** Reads serve from cache; mutators that would silently hit the network fail fast instead.
- **ETag-aware tap HEAD resolve.** `mt outdated` against third-party taps reuses cached commit SHAs, keeping routine audits inside GitHub's anonymous rate limit.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- etag aware tap head resolve ([159fdc7](https://github.com/indaco/malt/commit/159fdc7)) ([#386](https://github.com/indaco/malt/pull/386))
- honour MALT_OFFLINE and --offline ([7dec164](https://github.com/indaco/malt/commit/7dec164)) ([#385](https://github.com/indaco/malt/pull/385))
- **cli/install:** extend --download-only mode to tap formulas ([bc9b277](https://github.com/indaco/malt/commit/bc9b277)) ([#384](https://github.com/indaco/malt/pull/384))
- **cli/install:** add --download-only mode for bottles and casks ([827094d](https://github.com/indaco/malt/commit/827094d)) ([#382](https://github.com/indaco/malt/pull/382))
- **net:** honour MALT_API_DOMAIN and MALT_BOTTLE_DOMAIN ([974c5f8](https://github.com/indaco/malt/commit/974c5f8)) ([#380](https://github.com/indaco/malt/pull/380))

### 🩹 Fixes

- opportunistic latent low-severity hardening ([cbee732](https://github.com/indaco/malt/commit/cbee732)) ([#389](https://github.com/indaco/malt/pull/389))
- **cli/install:** propagate single-package install failures to a non-zero exit ([8aa6025](https://github.com/indaco/malt/commit/8aa6025)) ([#388](https://github.com/indaco/malt/pull/388))
- **cli/install:** exit non-zero when the cask DB row didn't persist ([308e9f7](https://github.com/indaco/malt/commit/308e9f7)) ([#387](https://github.com/indaco/malt/pull/387))
- **core:** plug temp-clone leak and surface broken opt symlinks ([9bdd624](https://github.com/indaco/malt/commit/9bdd624)) ([#363](https://github.com/indaco/malt/pull/363))

### 💅 Refactors

- small Zig idiom cleanups ([d1fdd19](https://github.com/indaco/malt/commit/d1fdd19)) ([#377](https://github.com/indaco/malt/pull/377))
- **main:** rename version flag to break version_cmd collision ([8f709fc](https://github.com/indaco/malt/commit/8f709fc)) ([#374](https://github.com/indaco/malt/pull/374))
- rename SCREAMING_SNAKE_CASE constants to snake_case ([118a4a7](https://github.com/indaco/malt/commit/118a4a7)) ([#373](https://github.com/indaco/malt/pull/373))
- **ui/output:** collapse info/warn/success scaffold via comptime ([e3726e9](https://github.com/indaco/malt/commit/e3726e9)) ([#372](https://github.com/indaco/malt/pull/372))
- **core/cask:** surface sqlite errors at the boundary ([74c4b8d](https://github.com/indaco/malt/commit/74c4b8d)) ([#371](https://github.com/indaco/malt/pull/371))
- **core/bundle:** type dispatcher errors ([2784213](https://github.com/indaco/malt/commit/2784213)) ([#370](https://github.com/indaco/malt/pull/370))
- thread caller allocator into worker arenas ([c2ed157](https://github.com/indaco/malt/commit/c2ed157)) ([#369](https://github.com/indaco/malt/pull/369))
- **cli/install:** commit to the thin-orchestrator shape ([b230f11](https://github.com/indaco/malt/commit/b230f11)) ([#368](https://github.com/indaco/malt/pull/368))
- **cli/install:** split rb-parse from local orchestration ([cb7ee84](https://github.com/indaco/malt/commit/cb7ee84)) ([#367](https://github.com/indaco/malt/pull/367))
- **cli/install:** drive the install pool through installKegFromBottle ([2a34ef6](https://github.com/indaco/malt/commit/2a34ef6)) ([#366](https://github.com/indaco/malt/pull/366))
- **cli/upgrade:** share install pipeline and dedup recordKeg ([9e2dba4](https://github.com/indaco/malt/commit/9e2dba4)) ([#365](https://github.com/indaco/malt/pull/365))
- **cli/outdated:** split snapshot, rows, refresh, orchestrator ([7386ba4](https://github.com/indaco/malt/commit/7386ba4)) ([#364](https://github.com/indaco/malt/pull/364))
- **update/notifier:** split policy and cache ([22efdda](https://github.com/indaco/malt/commit/22efdda)) ([#362](https://github.com/indaco/malt/pull/362))
- **core:** extract signals module from main ([aef438f](https://github.com/indaco/malt/commit/aef438f)) ([#361](https://github.com/indaco/malt/pull/361))
- **core/hash:** host constantTimeEql, guard core→cli boundary ([d5f59a9](https://github.com/indaco/malt/commit/d5f59a9)) ([#360](https://github.com/indaco/malt/pull/360))

### 📖 Documentation

- update badges and release notes ([5767539](https://github.com/indaco/malt/commit/5767539)) ([#392](https://github.com/indaco/malt/pull/392))
- **benchmark:** update results 2026-05-26 ([d324a58](https://github.com/indaco/malt/commit/d324a58)) ([#390](https://github.com/indaco/malt/pull/390))
- **readme:** add MALT_API_DOMAIN and MALT_BOTTLE_DOMAIN env vars ([6fd12c4](https://github.com/indaco/malt/commit/6fd12c4)) ([#383](https://github.com/indaco/malt/pull/383))
- **benchmark:** update results 2026-05-25 ([049aedd](https://github.com/indaco/malt/commit/049aedd)) ([#381](https://github.com/indaco/malt/pull/381))

### ✅ Tests

- stabilize info_cli human-output assertions under TTY stderr ([4fee64c](https://github.com/indaco/malt/commit/4fee64c)) ([#391](https://github.com/indaco/malt/pull/391))

### 🤖 CI

- **ci:** unblock release pipeline on macos-14 bash 3.2 ([75493b0](https://github.com/indaco/malt/commit/75493b0)) ([#394](https://github.com/indaco/malt/pull/394))

### 🏡 Chores

- **release:** cross-check cask binary paths against the tarball layout ([df61a3f](https://github.com/indaco/malt/commit/df61a3f)) ([#379](https://github.com/indaco/malt/pull/379))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.13.1 - 2026-05-24

### 🩹 Fixes

- **release:** drop wrap_in_directory so cask paths resolve ([6369a2a](https://github.com/indaco/malt/commit/6369a2a)) ([#376](https://github.com/indaco/malt/pull/376))

### 🎉 New Contributors

- [@buggerman](https://github.com/buggerman) made their first contribution in [#376](https://github.com/indaco/malt/pull/376)

### ❤️ Contributors

- [@buggerman](https://github.com/buggerman)

## v0.13.0 - 2026-05-18

### Highlights

v0.13.0 makes malt scriptable end-to-end: every read verb pipes cleanly into `jq` and similar, every long-running mutator emits structured progress, and `bundle export` captures the full set you'd want to rehydrate.

- **JSON parity across the surface.** `tap`, `services`, and `backup` join the rest of the CLI on `--json` - every read verb feeds a script without grep gymnastics.
- **Structured progress for long-running commands.** `MALT_PROGRESS=plain|ndjson` gives scripts, CI runners, and TUI wrappers stable install/upgrade events - no terminal-escape parsing.
- **`bundle export` round-trips taps and services.** The dumped Maltfile/Brewfile matches what's actually installed, not a partial snapshot.
- **`install --force` and `mt outdated` got more honest.** Force-reinstall overwrites the linker symlinks the docs already promised; outdated stops silently classifying a tap cask as up-to-date when its HEAD endpoint was unreachable.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **cli/doctor:** nudge users toward --fix when conditions are auto-fixable ([873baba](https://github.com/indaco/malt/commit/873baba)) ([#356](https://github.com/indaco/malt/pull/356))
- **ui:** unified MALT_PROGRESS contract for long-running mutators ([d5b4824](https://github.com/indaco/malt/commit/d5b4824)) ([#352](https://github.com/indaco/malt/pull/352))
- **cli/bundle:** include taps and services in dump ([285988b](https://github.com/indaco/malt/commit/285988b)) ([#351](https://github.com/indaco/malt/pull/351))
- **cli:** emit --json on tap, services, backup ([6b11d5e](https://github.com/indaco/malt/commit/6b11d5e)) ([#350](https://github.com/indaco/malt/pull/350))

### 🩹 Fixes

- **cli/outdated:** warn on tap HEAD-resolve failures, not silent ([411a9f2](https://github.com/indaco/malt/commit/411a9f2)) ([#358](https://github.com/indaco/malt/pull/358))
- **cli/install:** make --force a reliable recovery path ([d6c1f2a](https://github.com/indaco/malt/commit/d6c1f2a)) ([#355](https://github.com/indaco/malt/pull/355))

### 💅 Refactors

- **core/cellar:** drop local Replacement shadow type ([baf1ece](https://github.com/indaco/malt/commit/baf1ece)) ([#354](https://github.com/indaco/malt/pull/354))
- **core/patch:** expose text-file patching via the facade ([31f5560](https://github.com/indaco/malt/commit/31f5560)) ([#353](https://github.com/indaco/malt/pull/353))

### 📖 Documentation

- **benchmark:** update results 2026-05-18 ([5064d35](https://github.com/indaco/malt/commit/5064d35)) ([#357](https://github.com/indaco/malt/pull/357))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.12.0 - 2026-05-16

### Highlights

v0.12.0 closes the rollback story across formulas and casks, then rounds out the housekeeping, introspection, and convenience verbs that pair with retained-version state. The theme is sharper tools for the moments you actually reach for malt - precise recovery, better visibility, and a few brew-shaped verbs that were still missing.

- **Rollback is a real recovery tool now, for formulas and casks.** `mt rollback --list <pkg>` shows every version still on disk; `mt rollback --to <version>` jumps to a specific one instead of just "the previous keg." Casks join via per-version artefact retention - a bad GUI-app upgrade is recoverable without re-downloading the original DMG.
- **Housekeeping learned about retained cask versions.** `mt purge --old-versions` now reclaims cask per-version cache and Caskroom siblings; `mt doctor` reports retained cask count + size (and `--verbose` lists the offenders); `mt info <package>` shows the retained version history. The "what's costing me disk → reclaim → recover if needed" loop is whole.
- **Better introspection on the daily path.** `mt deps <formula>` is the forward dep view that pairs with `mt uses` for the reverse. `mt search --installed` and `--api` scope the same verb to "what's on this machine?" vs "what could I install?"
- **Tap and brew-name convenience.** `mt tap --pin <sha>` holds a tap at a specific commit; `mt tap --refresh --all` updates every tap in one pass. `mt cleanup` is a thin shim over `mt purge --housekeeping` so muscle memory from `brew cleanup` lands somewhere sensible - the `mt doctor` broken-symlink hint now points at it.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **cli:** add mt cleanup shim for purge --housekeeping ([5927932](https://github.com/indaco/malt/commit/5927932)) ([#345](https://github.com/indaco/malt/pull/345))
- **cli/tap:** add --pin <sha> and --refresh --all ([36f9a71](https://github.com/indaco/malt/commit/36f9a71)) ([#344](https://github.com/indaco/malt/pull/344))
- **cli/search:** add --installed and --api scopes ([9433eac](https://github.com/indaco/malt/commit/9433eac)) ([#343](https://github.com/indaco/malt/pull/343))
- **cli:** add mt deps for forward dependency view ([e031f18](https://github.com/indaco/malt/commit/e031f18)) ([#342](https://github.com/indaco/malt/pull/342))
- **cli/info:** include retained version history per package ([1e23d90](https://github.com/indaco/malt/commit/1e23d90)) ([#340](https://github.com/indaco/malt/pull/340))
- **cli/doctor:** enumerate offenders under --verbose ([df9a225](https://github.com/indaco/malt/commit/df9a225)) ([#339](https://github.com/indaco/malt/pull/339))
- **cli/doctor:** report retained cask version count + size ([f78296d](https://github.com/indaco/malt/commit/f78296d)) ([#338](https://github.com/indaco/malt/pull/338))
- **cli/purge:** include cask per-version cache + Caskroom in --old-versions ([4087128](https://github.com/indaco/malt/commit/4087128)) ([#336](https://github.com/indaco/malt/pull/336))
- **cli/rollback:** support casks via per-version artefact retention ([ea21b2d](https://github.com/indaco/malt/commit/ea21b2d)) ([#335](https://github.com/indaco/malt/pull/335))
- **cli/rollback:** support --to <version> and --list ([19ec294](https://github.com/indaco/malt/commit/19ec294)) ([#333](https://github.com/indaco/malt/pull/333))

### 🩹 Fixes

- **cli/rollback:** stop mislabelling installed casks as missing ([508b266](https://github.com/indaco/malt/commit/508b266)) ([#334](https://github.com/indaco/malt/pull/334))

### 💅 Refactors

- **cli/doctor:** point broken-symlink hint at mt cleanup ([94ac164](https://github.com/indaco/malt/commit/94ac164)) ([#346](https://github.com/indaco/malt/pull/346))
- **update/notifier:** make heads-up sit cleanly under any subcommand ([5217dbc](https://github.com/indaco/malt/commit/5217dbc)) ([#337](https://github.com/indaco/malt/pull/337))

### 📖 Documentation

- update readme, contributing, and coverage badge ([e47eef3](https://github.com/indaco/malt/commit/e47eef3)) ([#347](https://github.com/indaco/malt/pull/347))
- **readme:** keep bug-report callout focused on the reader ([b08be3c](https://github.com/indaco/malt/commit/b08be3c)) ([#318](https://github.com/indaco/malt/pull/318))
- **benchmark:** update results 2026-05-11 ([be837d7](https://github.com/indaco/malt/commit/be837d7)) ([#314](https://github.com/indaco/malt/pull/314))

### 🏡 Chores

- **devbox:** add sqlite and update packages version ([2a2f7c6](https://github.com/indaco/malt/commit/2a2f7c6)) ([#341](https://github.com/indaco/malt/pull/341))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.11.6 - 2026-05-14

### 🩹 Fixes

- **macho/patcher:** make text-file replacements atomic ([4136068](https://github.com/indaco/malt/commit/4136068)) ([#329](https://github.com/indaco/malt/pull/329))
- **db/lock:** close double-fd race and adopt std.Io.File ([b3a6791](https://github.com/indaco/malt/commit/b3a6791)) ([#328](https://github.com/indaco/malt/pull/328))

### 💅 Refactors

- **app_ctx:** tighten environ bootstrap to match stdlib ([1061d51](https://github.com/indaco/malt/commit/1061d51)) ([#330](https://github.com/indaco/malt/pull/330))

### ✅ Tests

- **regressions:** keep upgrade-revision-bump green across schema bumps ([ee7aa0f](https://github.com/indaco/malt/commit/ee7aa0f)) ([#331](https://github.com/indaco/malt/pull/331))

### 🤖 CI

- update actions/download-artifact to v8 ([38afde1](https://github.com/indaco/malt/commit/38afde1)) ([#327](https://github.com/indaco/malt/pull/327))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.11.5 - 2026-05-13

### 🩹 Fixes

- **upgrade:** stop re-downloading tap casks when not needed ([e3b06d6](https://github.com/indaco/malt/commit/e3b06d6)) ([#323](https://github.com/indaco/malt/pull/323))
- **cask:** suppress subprocess noise on success, surface it on failure ([016b793](https://github.com/indaco/malt/commit/016b793)) ([#322](https://github.com/indaco/malt/pull/322))
- **upgrade:** show the same per-keg progress bar as install and migrate ([70d93f6](https://github.com/indaco/malt/commit/70d93f6)) ([#321](https://github.com/indaco/malt/pull/321))

### 💅 Refactors

- **list:** scope mt list to a single tap with --tap filter ([49d9911](https://github.com/indaco/malt/commit/49d9911)) ([#325](https://github.com/indaco/malt/pull/325))
- **info:** surface owning tap for casks in mt info ([6421c62](https://github.com/indaco/malt/commit/6421c62)) ([#324](https://github.com/indaco/malt/pull/324))
- **tap:** consolidate tap-fetch URL synthesis behind one seam ([30f9eeb](https://github.com/indaco/malt/commit/30f9eeb)) ([#315](https://github.com/indaco/malt/pull/315))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.11.4 - 2026-05-12

### 🩹 Fixes

- **macho:** relocate path literals embedded in cstring sections ([e0d58d1](https://github.com/indaco/malt/commit/e0d58d1)) ([#319](https://github.com/indaco/malt/pull/319))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.11.3 - 2026-05-12

### 🩹 Fixes

- **install/tap:** install third-party tap formulas with version-in-URL ([57012ab](https://github.com/indaco/malt/commit/57012ab)) ([#316](https://github.com/indaco/malt/pull/316))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.11.2 - 2026-05-10

### 🩹 Fixes

- **upgrade:** atomic DB updates and actionable failure messages ([24b3f76](https://github.com/indaco/malt/commit/24b3f76)) ([#312](https://github.com/indaco/malt/pull/312))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.11.1 - 2026-05-09

### 🩹 Fixes

- **bottle:** retry transient SHA256 mismatches and surface diagnostics ([16b1718](https://github.com/indaco/malt/commit/16b1718)) ([#310](https://github.com/indaco/malt/pull/310))
- **install/local:** parse cask DSL multi-arch sha256 and arch-token URLs ([a585b05](https://github.com/indaco/malt/commit/a585b05)) ([#308](https://github.com/indaco/malt/pull/308))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.11.0 - 2026-05-08

### Highlights

v0.11.0 lands the strategic features deferred from the brew-parity push - parallel migration with resume, machine-readable output across the mutating commands, and a passive update notifier - and folds in a broad fix-pass that paid down the regressions and rough edges introduced over the v0.10 cycle.

- **Parallel migrate that survives interruption.** `mt migrate --parallel` works through the Homebrew Cellar concurrently and persists progress, so a run that's interrupted picks up where it stopped instead of restarting. Kegs that no longer resolve through the Homebrew API still migrate via a Cellar-side fallback - including third-party taps, whose `post_install` hook now runs end-to-end on that path.
- **Scriptable output for the commands that change state.** Install, migrate, purge, uninstall, and upgrade now emit NDJSON on demand via `--output-format=ndjson`, with `mt purge` additionally producing a structured JSON summary alongside its sectioned text report. Automation can consume exactly what each step did - and tell a real scope failure apart from a clean no-op - instead of scraping prose.
- **Update checks that stay out of your way.** The post-command "is there a new malt?" probe runs in the background, never delays the command from returning, exits cleanly on Ctrl-C, and can no longer leave its cache in a half-written state.
- **Correctness fix-pass.** Three headline bugs that v0.10 users could trip into are fixed: `mt upgrade` no longer hangs on its own lock when pulling in a new transitive dep, `mt rollback` no longer leaves an orphaned cellar directory after a revision bump, and tap installs no longer leak a staging archive on every successful run. The broader sweep that lands alongside tightens migrate (accurate cancelled-vs-skipped accounting on Ctrl-C, deferred `post_install` ordering), uninstall and the on-disk store (transactional removal, no stranded refcount rows), the schema migration window, the update notifier, and the terminal UI - cursor and autowrap are restored after an aborted install, oversize labels can't crash the progress bar, and notice/warn stay distinguishable with colour and emoji disabled.
- **Quieter foundation under the hood.** `mt` is now a symlink to a single `malt` binary instead of two near-identical copies. The cycle's standard-library migration is wound up, bottle verification streams instead of buffering whole bottles into memory, and SHA comparisons run in constant time. None of this is user-visible on its own - it's the seam the next feature wave plugs into.

#### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **cli/purge:** distinguish swallowed scope failures from clean no-ops in ndjson ([82227e6](https://github.com/indaco/malt/commit/82227e6)) ([#262](https://github.com/indaco/malt/pull/262))
- **migrate:** copy-from-Cellar fallback for kegs not in the Homebrew API ([2e5f917](https://github.com/indaco/malt/commit/2e5f917)) ([#247](https://github.com/indaco/malt/pull/247))
- **cli/purge:** emit structured JSON and NDJSON for purge ([fa4c765](https://github.com/indaco/malt/commit/fa4c765)) ([#235](https://github.com/indaco/malt/pull/235))
- passive version-notify after dispatch ([0fbee72](https://github.com/indaco/malt/commit/0fbee72)) ([#214](https://github.com/indaco/malt/pull/214))
- **cli/migrate:** --parallel with resume manifest ([227dc30](https://github.com/indaco/malt/commit/227dc30)) ([#213](https://github.com/indaco/malt/pull/213))
- **cli:** --output-format=ndjson for mutating commands ([badb83a](https://github.com/indaco/malt/commit/badb83a)) ([#212](https://github.com/indaco/malt/pull/212))

### 🩹 Fixes

- **coverage:** skip subprocess tests under kcov ([10caa4c](https://github.com/indaco/malt/commit/10caa4c)) ([#303](https://github.com/indaco/malt/pull/303))
- **net/client:** make idle watchdog fire on TLS read stalls ([50c89f2](https://github.com/indaco/malt/commit/50c89f2)) ([#302](https://github.com/indaco/malt/pull/302))
- edge-case hardening ([47c8762](https://github.com/indaco/malt/commit/47c8762)) ([#298](https://github.com/indaco/malt/pull/298))
- propagate std.Io sleep cancellation through poll and retry loops ([e222c31](https://github.com/indaco/malt/commit/e222c31)) ([#296](https://github.com/indaco/malt/pull/296))
- **core/ruby_subprocess:** split TapNotFound into actionable failure modes ([0678220](https://github.com/indaco/malt/commit/0678220)) ([#293](https://github.com/indaco/malt/pull/293))
- **dsl/fallback_log:** warn when an OOM drops a fallback entry ([80cebac](https://github.com/indaco/malt/commit/80cebac)) ([#291](https://github.com/indaco/malt/pull/291))
- **ui:** restore cursor and autowrap when install/migrate aborts ([1a3a990](https://github.com/indaco/malt/commit/1a3a990)) ([#290](https://github.com/indaco/malt/pull/290))
- **cli/purge/scopes:** surface DB prepare failures in runStaleCasks ([9c39f2b](https://github.com/indaco/malt/commit/9c39f2b)) ([#289](https://github.com/indaco/malt/pull/289))
- **ui/progress:** clip oversize labels so long taps don't crash the bar ([51513c9](https://github.com/indaco/malt/commit/51513c9)) ([#286](https://github.com/indaco/malt/pull/286))
- **cli/purge/report:** print cache-pruning header for long cache paths ([e8bf57d](https://github.com/indaco/malt/commit/e8bf57d)) ([#285](https://github.com/indaco/malt/pull/285))
- **cli/uninstall:** decrement store ref atomically with DB delete ([b4272b2](https://github.com/indaco/malt/commit/b4272b2)) ([#282](https://github.com/indaco/malt/pull/282))
- **core/store:** wrap remove in a transaction to keep DB consistent ([ecd78ef](https://github.com/indaco/malt/commit/ecd78ef)) ([#281](https://github.com/indaco/malt/pull/281))
- **db/schema:** harden the v5 FK-off rebuild window ([976daaf](https://github.com/indaco/malt/commit/976daaf)) ([#280](https://github.com/indaco/malt/pull/280))
- **update/notifier:** honour SIGINT during the post-dispatch update probe ([fe2da30](https://github.com/indaco/malt/commit/fe2da30)) ([#279](https://github.com/indaco/malt/pull/279))
- **update/notifier:** atomic cache write to avoid torn states ([2f8b812](https://github.com/indaco/malt/commit/2f8b812)) ([#278](https://github.com/indaco/malt/pull/278))
- **install:** widen download_index to u16 ([388dae6](https://github.com/indaco/malt/commit/388dae6)) ([#274](https://github.com/indaco/malt/pull/274))
- **ui:** serialise concurrent stderr emit windows ([de71dca](https://github.com/indaco/malt/commit/de71dca)) ([#272](https://github.com/indaco/malt/pull/272))
- **core:** route post_install subprocess stdio via AppCtx ([1b7abb9](https://github.com/indaco/malt/commit/1b7abb9)) ([#273](https://github.com/indaco/malt/pull/273))
- **migrate/keg:** keep parallel workers moving when OOM forces inline post_install ([0eb1bd7](https://github.com/indaco/malt/commit/0eb1bd7)) ([#271](https://github.com/indaco/malt/pull/271))
- **migrate/keg:** shrink readInstallReceipt buffer to actual read length ([9b1412f](https://github.com/indaco/malt/commit/9b1412f)) ([#270](https://github.com/indaco/malt/pull/270))
- **cli/upgrade:** refresh tap-installed packages and self-heal dep opt links ([da2e3a0](https://github.com/indaco/malt/commit/da2e3a0)) ([#269](https://github.com/indaco/malt/pull/269))
- **core/bottle:** constant-time SHA compare on disk re-verify ([6057a85](https://github.com/indaco/malt/commit/6057a85)) ([#267](https://github.com/indaco/malt/pull/267))
- **dsl/inreplace:** preserve the real underlying error in atomic-write failures ([8ba2320](https://github.com/indaco/malt/commit/8ba2320)) ([#265](https://github.com/indaco/malt/pull/265))
- **ui:** keep notice and warn distinguishable in NO_COLOR / no-emoji mode ([34bd16c](https://github.com/indaco/malt/commit/34bd16c)) ([#263](https://github.com/indaco/malt/pull/263))
- **install/post_install:** only fall back to Ruby when the DSL actually skipped work ([b1d0351](https://github.com/indaco/malt/commit/b1d0351)) ([#261](https://github.com/indaco/malt/pull/261))
- **migrate/keg:** preserve full_name for tap+keg paths over 256 bytes ([e715e85](https://github.com/indaco/malt/commit/e715e85)) ([#258](https://github.com/indaco/malt/pull/258))
- **migrate/parallel:** distinguish cancelled kegs from already-installed ones ([e66fdc7](https://github.com/indaco/malt/commit/e66fdc7)) ([#256](https://github.com/indaco/malt/pull/256))
- **migrate:** run post_install for tap kegs migrated from the Cellar fallback ([48c0728](https://github.com/indaco/malt/commit/48c0728)) ([#255](https://github.com/indaco/malt/pull/255))
- **install/local:** stop tap installs leaking their staging archive ([efd5447](https://github.com/indaco/malt/commit/efd5447)) ([#254](https://github.com/indaco/malt/pull/254))
- **cli/rollback:** keep revision-bumped cellar dirs from being orphaned ([73c74f4](https://github.com/indaco/malt/commit/73c74f4)) ([#253](https://github.com/indaco/malt/pull/253))
- **cli/upgrade:** share malt.lock with installAll to avoid self-deadlock ([e733569](https://github.com/indaco/malt/commit/e733569)) ([#252](https://github.com/indaco/malt/pull/252))
- **migrate:** defer post_install hooks until every keg is linked ([88afd10](https://github.com/indaco/malt/commit/88afd10)) ([#248](https://github.com/indaco/malt/pull/248))
- **core/ruby_subprocess+sandbox:** make --use-system-ruby work end-to-end on macOS ([1a18ea4](https://github.com/indaco/malt/commit/1a18ea4)) ([#246](https://github.com/indaco/malt/pull/246))
- **install/post_install:** auto-include ruby keg in system-Ruby fallback ([3deb61e](https://github.com/indaco/malt/commit/3deb61e)) ([#245](https://github.com/indaco/malt/pull/245))
- **migrate:** hardening for parallel migration ([170408e](https://github.com/indaco/malt/commit/170408e)) ([#244](https://github.com/indaco/malt/pull/244))
- **core/formula:** route parseFormula allocs through parse arena ([42b79f9](https://github.com/indaco/malt/commit/42b79f9)) ([#241](https://github.com/indaco/malt/pull/241))
- **core/store:** drop the store_refs row when removing an orphan ([a0d6537](https://github.com/indaco/malt/commit/a0d6537)) ([#233](https://github.com/indaco/malt/pull/233))
- **cli/install:** refuse to install malt itself ([0d0f14b](https://github.com/indaco/malt/commit/0d0f14b)) ([#231](https://github.com/indaco/malt/pull/231))

### 💅 Refactors

- drop unused allocator params left over from fs_compat retirement ([ac0bd28](https://github.com/indaco/malt/commit/ac0bd28)) ([#294](https://github.com/indaco/malt/pull/294))
- **ui:** route stdin probes and prompt reads through pkg_io ([e0a6cd0](https://github.com/indaco/malt/commit/e0a6cd0)) ([#288](https://github.com/indaco/malt/pull/288))
- **cli/purge:** firm up --json and --ndjson emit semantics ([b2d065c](https://github.com/indaco/malt/commit/b2d065c)) ([#287](https://github.com/indaco/malt/pull/287))
- **update/notifier:** swap state through a single atomic helper ([b119186](https://github.com/indaco/malt/commit/b119186)) ([#284](https://github.com/indaco/malt/pull/284))
- **install:** defer-release the token-prefetch HTTP client ([0cea630](https://github.com/indaco/malt/commit/0cea630)) ([#276](https://github.com/indaco/malt/pull/276))
- **install/local:** split rb/cask retry into separate response handles ([85db885](https://github.com/indaco/malt/commit/85db885)) ([#275](https://github.com/indaco/malt/pull/275))
- **dsl/inreplace:** route stderr warning through output module ([cf0668b](https://github.com/indaco/malt/commit/cf0668b)) ([#266](https://github.com/indaco/malt/pull/266))
- **dsl/process:** drop unused io parameter from readPipeAll ([da8d4b6](https://github.com/indaco/malt/commit/da8d4b6)) ([#264](https://github.com/indaco/malt/pull/264))
- **migrate:** match install's progress bar TUI in serial and parallel ([d850931](https://github.com/indaco/malt/commit/d850931)) ([#249](https://github.com/indaco/malt/pull/249))
- **install:** inline keg path in MaterializeResult ([489c2ec](https://github.com/indaco/malt/commit/489c2ec)) ([#242](https://github.com/indaco/malt/pull/242))
- **cli/purge:** sectioned housekeeping output, summary table, --verbose ([216e8b0](https://github.com/indaco/malt/commit/216e8b0)) ([#232](https://github.com/indaco/malt/pull/232))
- ship single binary; mt is a symlink to malt ([5e4d87b](https://github.com/indaco/malt/commit/5e4d87b)) ([#230](https://github.com/indaco/malt/pull/230))
- retire fs/compat shim in favour of std.Io and AppCtx ([333bb94](https://github.com/indaco/malt/commit/333bb94)) ([#228](https://github.com/indaco/malt/pull/228))

### 📖 Documentation

- **benchmark:** update results 2026-05-08 ([3c35e42](https://github.com/indaco/malt/commit/3c35e42)) ([#304](https://github.com/indaco/malt/pull/304))
- update readme and code coverage badde ([84b4703](https://github.com/indaco/malt/commit/84b4703)) ([#305](https://github.com/indaco/malt/pull/305))
- **core/formula:** clarify bottle_files lifetime after parse-arena migration ([9f6c69d](https://github.com/indaco/malt/commit/9f6c69d)) ([#260](https://github.com/indaco/malt/pull/260))
- **benchmark:** update results 2026-05-04 ([735d1db](https://github.com/indaco/malt/commit/735d1db)) ([#234](https://github.com/indaco/malt/pull/234))

### ⚡ Performance

- **text-replace:** share the optimised byte-replace across DSL and macho ([ed41f3c](https://github.com/indaco/malt/commit/ed41f3c)) ([#295](https://github.com/indaco/malt/pull/295))
- **core/bottle:** stream-hash bottles instead of buffering whole file ([e664364](https://github.com/indaco/malt/commit/e664364)) ([#268](https://github.com/indaco/malt/pull/268))
- **install/post_install:** reuse the install path's FormulaCache ([45f2586](https://github.com/indaco/malt/commit/45f2586)) ([#259](https://github.com/indaco/malt/pull/259))

### ✅ Tests

- **smoke:** keep network smokes honest ([3429415](https://github.com/indaco/malt/commit/3429415)) ([#301](https://github.com/indaco/malt/pull/301))
- **install-parse-cache:** wipe TempDb dir before reopen ([e2f427c](https://github.com/indaco/malt/commit/e2f427c)) ([#300](https://github.com/indaco/malt/pull/300))
- **migrate:** pin post_install drain ordering vs linkOpt ([e36da02](https://github.com/indaco/malt/commit/e36da02)) ([#299](https://github.com/indaco/malt/pull/299))
- **cli:** expand dispatch coverage and fix kcov merge/hang ([da95097](https://github.com/indaco/malt/commit/da95097)) ([#240](https://github.com/indaco/malt/pull/240))
- **install:** kill flaky idempotent fall-through by skipping the network ([a2df415](https://github.com/indaco/malt/commit/a2df415)) ([#219](https://github.com/indaco/malt/pull/219))

### 🏡 Chores

- post-audit hygiene sweep ([5af8b69](https://github.com/indaco/malt/commit/5af8b69)) ([#297](https://github.com/indaco/malt/pull/297))
- **cli/bundle:** make null-ctx dispatcher panic explicit ([f9c0fde](https://github.com/indaco/malt/commit/f9c0fde)) ([#292](https://github.com/indaco/malt/pull/292))
- **update/swap:** make rollback delete the staged file explicitly ([717d6bc](https://github.com/indaco/malt/commit/717d6bc)) ([#283](https://github.com/indaco/malt/pull/283))
- **main:** isolate the interrupt flag across test cases ([222136e](https://github.com/indaco/malt/commit/222136e)) ([#277](https://github.com/indaco/malt/pull/277))
- **ui:** distinguish update-available notices from warnings ([a40916f](https://github.com/indaco/malt/commit/a40916f)) ([#251](https://github.com/indaco/malt/pull/251))
- **scripts:** group smoke tests under scripts/smokes/ ([c8dc0e6](https://github.com/indaco/malt/commit/c8dc0e6)) ([#250](https://github.com/indaco/malt/pull/250))
- **bench:** instrument warm-install variance source ([0d3cf16](https://github.com/indaco/malt/commit/0d3cf16)) ([#238](https://github.com/indaco/malt/pull/238))
- silence environmental noise from `zig build test` ([8619258](https://github.com/indaco/malt/commit/8619258)) ([#236](https://github.com/indaco/malt/pull/236))
- **devbox:** pin zig to 0.16.x ([d045b1e](https://github.com/indaco/malt/commit/d045b1e)) ([#229](https://github.com/indaco/malt/pull/229))
- **pins:** bump homebrew-core pin to 1292ccec7219 ([b255407](https://github.com/indaco/malt/commit/b255407)) ([#216](https://github.com/indaco/malt/pull/216))
- add just release-branch recipe ([49b6f28](https://github.com/indaco/malt/commit/49b6f28)) ([#211](https://github.com/indaco/malt/pull/211))
- add release-branch + patch workflow ([9e5cf9f](https://github.com/indaco/malt/commit/9e5cf9f)) ([#210](https://github.com/indaco/malt/pull/210))

### 🤖 CI

- **smoke:** align expected tag with released ref, add gh-auth fallback ([4d72979](https://github.com/indaco/malt/commit/4d72979)) ([#243](https://github.com/indaco/malt/pull/243))
- **bench:** fix README date refresh in benchmark workflow ([41d3268](https://github.com/indaco/malt/commit/41d3268)) ([#239](https://github.com/indaco/malt/pull/239))
- **bench:** update the PR title to follow conventional commits ([f2f7eea](https://github.com/indaco/malt/commit/f2f7eea)) ([#237](https://github.com/indaco/malt/pull/237))
- **release:** smoke-then-promote, pre-flight gate, rollback playbook ([4d3cdad](https://github.com/indaco/malt/commit/4d3cdad)) ([#222](https://github.com/indaco/malt/pull/222))
- bump actions/upload-artifact from 5 to 7 ([bcdf7e9](https://github.com/indaco/malt/commit/bcdf7e9)) ([#218](https://github.com/indaco/malt/pull/218))
- bump peter-evans/create-pull-request from 7 to 8 ([c47ea56](https://github.com/indaco/malt/commit/c47ea56)) ([#217](https://github.com/indaco/malt/pull/217))

### 🎉 New Contributors

- [@dependabot[bot]](https://github.com/dependabot[bot]) made their first contribution in [#218](https://github.com/indaco/malt/pull/218)

### ❤️ Contributors

- [@github-actions[bot]](https://github.com/github-actions[bot])
- [@indaco](https://github.com/indaco)
- [@dependabot[bot]](https://github.com/dependabot[bot])

## v0.10.3 - 2026-05-03

### 🩹 Fixes

- **core/deps:** isInstalled also requires the opt/<name> symlink ([54d1ce9](https://github.com/indaco/malt/commit/54d1ce9)) ([#226](https://github.com/indaco/malt/pull/226))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.10.2 - 2026-05-03

### 🩹 Fixes

- **cli:** preserve revision on rollback + pull new transitive deps on upgrade ([a57ee2d](https://github.com/indaco/malt/commit/a57ee2d)) ([#224](https://github.com/indaco/malt/pull/224))
- **db/schema:** broaden kegs UNIQUE to (name, version, revision) ([d3a08ab](https://github.com/indaco/malt/commit/d3a08ab)) ([#223](https://github.com/indaco/malt/pull/223))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.10.1 - 2026-05-02

### 🩹 Fixes

- **cli/install:** pre-wipe cellar dst so clonefile survives stale kegs ([af4e0f7](https://github.com/indaco/malt/commit/af4e0f7)) ([#220](https://github.com/indaco/malt/pull/220))
- **fs/atomic:** fsync tempfile + parent dir before/after rename ([b38854c](https://github.com/indaco/malt/commit/b38854c)) ([#215](https://github.com/indaco/malt/pull/215))

### ✅ Tests

- **install:** kill flaky idempotent fall-through by skipping the network ([0a0e6f8](https://github.com/indaco/malt/commit/0a0e6f8)) ([#219](https://github.com/indaco/malt/pull/219))

### 🏡 Chores

- **pins:** bump homebrew-core pin to 1292ccec7219 ([c041b20](https://github.com/indaco/malt/commit/c041b20)) ([#216](https://github.com/indaco/malt/pull/216))
- add just release-branch recipe ([66011db](https://github.com/indaco/malt/commit/66011db)) ([#211](https://github.com/indaco/malt/pull/211))
- add release-branch + patch workflow ([5eb5aec](https://github.com/indaco/malt/commit/5eb5aec)) ([#210](https://github.com/indaco/malt/pull/210))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.10.0 - 2026-04-28

### Highlights

If v0.9.3 was mostly an invisible release that paid down structural debt while fixing some long-standing tap issues, v0.10.0 is the visible one: a brew-parity push that closes the most-asked-for workflow gaps, plus a substantial speedup on the warm-install path that affects every reinstall, upgrade, devbox-style rebuild, and CI cache restore.

- **The everyday brew workflow now has malt-side equivalents.** `mt pin` / `mt unpin` hold a formula or cask at its installed version; `mt upgrade` honours the pin, and `mt outdated --pinned-only` audits drift on held-back versions for CVE watch. `mt shellenv` is a drop-in for `eval "$(brew shellenv)"` - same `HOMEBREW_*` exports so brew-aware scripts keep sniffing, plus malt's prefix on `PATH`. `mt which <bin>` is the reverse lookup that pairs with `mt uses` - "what keg owns this binary?" - answered offline in one call. `mt install --only-dependencies` materialises a dep set without the requested package (useful before a from-source build); `mt services logs --follow` tails launchd logs through SIGINT; `mt run --keep` caches the extracted bottle under `{cache}/run/<sha256>/` so subsequent ephemeral runs skip the download. `mt bundle cleanup` uninstalls packages absent from the Brewfile, and `mt doctor --fix` repairs the safe warning classes (stale lock, broken symlinks, refcount-0 store blobs) inline.
- **`mt outdated` is now instant.** A cached `outdated.json` snapshot - refreshed in the background and filtered through the live DB at read time, so an uninstalled or manually-upgraded keg can never appear - turns the command into something safe to wire into a shell prompt. `mt update --check` warms the snapshot without touching the API cache; the API fetches that _do_ run are now parallelised. The 24-hour TTL is overridable via `MALT_OUTDATED_MAX_AGE`, with `0` meaning "always recompute".
- **Warm installs got dramatically faster.** Four targeted patches collapse the per-dep cost on the warm path: a post-relocation keg cache keyed by bottle SHA256, a parsed-formula cache that takes 18–21 dep parses down to 6, a short-circuit when the keg is already present, and a skipped cask-ambiguity probe on the unambiguous warm path. Local Apple Silicon: warm `wget` (6 deps) drops from 37 ms to 5 ms, warm `ffmpeg` (11 deps) drops from 161 ms to 18 ms - roughly 7–9× across the multi-dep packages. The per-dep cost that used to dominate warm-install time is essentially gone.
- **The rough edges you would have hit.** Third-party tap casks shipping DMG, PKG, or zip-app payloads (anything with a non-bottle release shape) now route to the cask installer instead of failing through the formula path. `mt purge --unused-deps` walks the full transitive closure when looking for orphans, so deps-of-deps actually get reclaimed.

One small ask. v0.10.0 lands a lot on the install path; I don't expect regressions, but some may slip through. If you hit one, please open an issue.

---

### 🚀 Enhancements

- **cli/doctor:** --fix for safe warning classes ([e90d3be](https://github.com/indaco/malt/commit/e90d3be)) ([#200](https://github.com/indaco/malt/pull/200))
- **cli/bundle:** cleanup removes packages absent from Brewfile ([62f7899](https://github.com/indaco/malt/commit/62f7899)) ([#199](https://github.com/indaco/malt/pull/199))
- **cli:** instant mt outdated via cached snapshot ([477afca](https://github.com/indaco/malt/commit/477afca)) ([#195](https://github.com/indaco/malt/pull/195))
- **cli:** extend pinning to casks ([38cd035](https://github.com/indaco/malt/commit/38cd035)) ([#193](https://github.com/indaco/malt/pull/193))
- **cli:** --pinned-only audit and upgrade --pinned dry-run ([55e88a8](https://github.com/indaco/malt/commit/55e88a8)) ([#192](https://github.com/indaco/malt/pull/192))
- **cli/run:** --keep for cached ephemeral runs ([c8e63c3](https://github.com/indaco/malt/commit/c8e63c3)) ([#190](https://github.com/indaco/malt/pull/190))
- **cli/services:** logs --follow ([67b183e](https://github.com/indaco/malt/commit/67b183e)) ([#189](https://github.com/indaco/malt/pull/189))
- **cli/install:** --only-dependencies ([92f91e4](https://github.com/indaco/malt/commit/92f91e4)) ([#188](https://github.com/indaco/malt/pull/188))
- **cli:** mt which to resolve prefix binaries to kegs ([572662c](https://github.com/indaco/malt/commit/572662c)) ([#187](https://github.com/indaco/malt/pull/187))
- **cli:** mt shellenv for bash, zsh, fish ([eb802d5](https://github.com/indaco/malt/commit/eb802d5)) ([#186](https://github.com/indaco/malt/pull/186))
- **cli:** mt pin / mt unpin and upgrade honors pins ([11e94a0](https://github.com/indaco/malt/commit/11e94a0)) ([#185](https://github.com/indaco/malt/pull/185))

### 🩹 Fixes

- **cli/install:** route tap-hosted DMG/PKG/zip-app casks to cask installer ([235735a](https://github.com/indaco/malt/commit/235735a)) ([#196](https://github.com/indaco/malt/pull/196))
- **core/deps:** walk transitive closure when finding orphan deps ([9cac6e1](https://github.com/indaco/malt/commit/9cac6e1)) ([#197](https://github.com/indaco/malt/pull/197))

### 📖 Documentation

- restructure README around drop-in Homebrew positioning ([a624ade](https://github.com/indaco/malt/commit/a624ade)) ([#208](https://github.com/indaco/malt/pull/208))

### ⚡ Performance

- **install:** short-circuit when keg already present ([d366686](https://github.com/indaco/malt/commit/d366686)) ([#204](https://github.com/indaco/malt/pull/204))
- **install:** skip cask-ambiguity probe on unambiguous warm path ([c3b3272](https://github.com/indaco/malt/commit/c3b3272)) ([#203](https://github.com/indaco/malt/pull/203))
- **install:** parse each dep formula once per invocation ([96de238](https://github.com/indaco/malt/commit/96de238)) ([#202](https://github.com/indaco/malt/pull/202))
- **install:** cache post-relocation keg for instant warm reinstalls ([089011c](https://github.com/indaco/malt/commit/089011c)) ([#201](https://github.com/indaco/malt/pull/201))
- **cli/outdated:** parallelise API fetches ([595bfd7](https://github.com/indaco/malt/commit/595bfd7)) ([#191](https://github.com/indaco/malt/pull/191))

### ✅ Tests

- quiet just coverage noise on macOS ([8be68e0](https://github.com/indaco/malt/commit/8be68e0)) ([#205](https://github.com/indaco/malt/pull/205))

### 🤖 CI

- **benchmark:** update PR title and body ([84ad04f](https://github.com/indaco/malt/commit/84ad04f)) ([#207](https://github.com/indaco/malt/pull/207))
- open PR for benchmark refresh instead of pushing main ([61bf4d0](https://github.com/indaco/malt/commit/61bf4d0)) ([#198](https://github.com/indaco/malt/pull/198))

### Other

- update benchmark results 2026-04-28 ([1e38de5](https://github.com/indaco/malt/commit/1e38de5)) ([#206](https://github.com/indaco/malt/pull/206))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.9.3 - 2026-04-24

### Highlights

A mostly invisible release: third-party tap installs are fixed and given clearer error messages, and the internals are reorganised so the next wave of features has a clean place to land. The goal was to pay down structural debt and bring the codebase up to current conventions.

- **Better error messages on tap installation failures.** Each failure mode (rate limit, 404, network, malformed JSON) now surfaces its own message with the remediation named inline, instead of one opaque line hiding the real cause.
- **Bigger modules split along responsibility lines.** The largest command entry points are broken into focused submodules and the layering between the CLI, core, and bundle surfaces is untangled. The source tree now matches the mental model of the tool.
- **Clearer boundaries between logic and presentation.** Core operations return structured outcomes instead of drawing to the screen directly, and internal state is no longer leaked through public surfaces. This is the seam that headless and embedded use cases will plug into later.
- **Codebase brought up to current idioms.** A long tail of small refactors aligns the codebase with current Zig conventions - consistent naming, narrower error sets, and modern standard-library primitives in place of older migration shims.
- **Less noise in the code itself.** Silently-swallowed errors were triaged, repetitive I/O chains collapsed, multi-paragraph comments reduced to a single load-bearing line, and unit tests moved next to the code they exercise.

---

### 🩹 Fixes

- **cli/install:** resolve third-party tap HEAD commit reliably ([ceb2270](https://github.com/indaco/malt/commit/ceb2270)) ([#182](https://github.com/indaco/malt/pull/182))
- **cli/bundle:** honor global --dry-run in bundle install ([c092b59](https://github.com/indaco/malt/commit/c092b59)) ([#159](https://github.com/indaco/malt/pull/159))

### 💅 Refactors

- use @tagName for trivial enum label switches ([ceda21e](https://github.com/indaco/malt/commit/ceda21e)) ([#181](https://github.com/indaco/malt/pull/181))
- **ui,cli:** replace long "writeAll catch {}" chains with try ([fa80f81](https://github.com/indaco/malt/commit/fa80f81)) ([#179](https://github.com/indaco/malt/pull/179))
- triage swallowed catch sites ([9d9f676](https://github.com/indaco/malt/commit/9d9f676)) ([#177](https://github.com/indaco/malt/pull/177))
- **fs/compat:** close std.Io/std.posix migration shim ([583b311](https://github.com/indaco/malt/commit/583b311)) ([#175](https://github.com/indaco/malt/pull/175))
- **db/sqlite:** accept sentinel-terminated paths and SQL ([02c0c4f](https://github.com/indaco/malt/commit/02c0c4f)) ([#174](https://github.com/indaco/malt/pull/174))
- **core/sandbox:** use std.posix.rlimit_resource tags ([54ed0c2](https://github.com/indaco/malt/commit/54ed0c2)) ([#173](https://github.com/indaco/malt/pull/173))
- **core/deps:** BFS via std.Deque ([6b18c8b](https://github.com/indaco/malt/commit/6b18c8b)) ([#172](https://github.com/indaco/malt/pull/172))
- **core/pins:** store commit SHA as fixed array ([7d38dcf](https://github.com/indaco/malt/commit/7d38dcf)) ([#171](https://github.com/indaco/malt/pull/171))
- **core/services/plist:** StaticStringMap forbidden_heads ([1922634](https://github.com/indaco/malt/commit/1922634)) ([#170](https://github.com/indaco/malt/pull/170))
- **cli:** StaticStringMap flag parsing and command dispatch ([5d1afb0](https://github.com/indaco/malt/commit/5d1afb0)) ([#169](https://github.com/indaco/malt/pull/169))
- **cli/doctor:** table-driven checks + stream-write fix ([c17d673](https://github.com/indaco/malt/commit/c17d673)) ([#168](https://github.com/indaco/malt/pull/168))
- snake_case value constants (SCREAMING_SNAKE_CASE -> snake_case) ([74a9a13](https://github.com/indaco/malt/commit/74a9a13)) ([#167](https://github.com/indaco/malt/pull/167))
- **ui,cli:** adopt \*std.Io.Writer in place of writer anytype ([eb73880](https://github.com/indaco/malt/commit/eb73880)) ([#166](https://github.com/indaco/malt/pull/166))
- **core/cask,cli/run:** thread caller allocator to Child.init ([6a7a01a](https://github.com/indaco/malt/commit/6a7a01a)) ([#165](https://github.com/indaco/malt/pull/165))
- **core/dsl:** split interpreter context and decouple from formula ([dcd57d1](https://github.com/indaco/malt/commit/dcd57d1)) ([#164](https://github.com/indaco/malt/pull/164))
- privatise raw sqlite/lock handles; document borrowed slices ([be85162](https://github.com/indaco/malt/commit/be85162)) ([#163](https://github.com/indaco/malt/pull/163))
- parameter-object multi-arg entrypoints ([018de38](https://github.com/indaco/malt/commit/018de38)) ([#162](https://github.com/indaco/malt/pull/162))
- **cli/doctor:** split out render and post_install modules ([5c05a18](https://github.com/indaco/malt/commit/5c05a18)) ([#161](https://github.com/indaco/malt/pull/161))
- **cli/purge:** split into args, wipe, scopes ([a0cd039](https://github.com/indaco/malt/commit/a0cd039)) ([#160](https://github.com/indaco/malt/pull/160))
- **core:** return structured outcomes rather than emitting UI ([d512d7d](https://github.com/indaco/malt/commit/d512d7d)) ([#158](https://github.com/indaco/malt/pull/158))
- unify post_install routing between install and migrate ([3b8c0bc](https://github.com/indaco/malt/commit/3b8c0bc)) ([#156](https://github.com/indaco/malt/pull/156))
- **cli/install:** split entry into submodules ([0b265a8](https://github.com/indaco/malt/commit/0b265a8)) ([#155](https://github.com/indaco/malt/pull/155))
- **core/bundle:** invert runner -> cli direction ([049acc5](https://github.com/indaco/malt/commit/049acc5)) ([#154](https://github.com/indaco/malt/pull/154))

### 📖 Documentation

- **src:** collapse multi-paragraph comments to one load-bearing line ([6d0d7bb](https://github.com/indaco/malt/commit/6d0d7bb)) ([#176](https://github.com/indaco/malt/pull/176))

### ✅ Tests

- **src:** colocate unit tests as inline test blocks ([6fc14d5](https://github.com/indaco/malt/commit/6fc14d5)) ([#178](https://github.com/indaco/malt/pull/178))

### 🏡 Chores

- add `just clean` recipe and extend pre-commit hook to .sh files ([60d8d09](https://github.com/indaco/malt/commit/60d8d09)) ([#157](https://github.com/indaco/malt/pull/157))

### 🤖 CI

- **ci:** authenticate release install smoke API calls ([f1f2bed](https://github.com/indaco/malt/commit/f1f2bed)) ([#183](https://github.com/indaco/malt/pull/183))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.9.2 - 2026-04-23

### 🩹 Fixes

- **update:** cosign PATH lookup + twin 'malt'/'mt' swap ([592b2a7](https://github.com/indaco/malt/commit/592b2a7)) ([#152](https://github.com/indaco/malt/pull/152))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.9.1 - 2026-04-23

### Highlights

**Hardening**

This release is about making malt boring in the good way. Nineteen fixes plus ten safety-oriented refactors tighten memory ownership, propagate errors that were previously swallowed, strengthen randomness and constant-time compares at security-critical sites, and harden archive extraction, database locking, and self-update against edge cases. A few prompt-visible wins ride along — macOS 26 bottles install, .tar.gz casks with binary artifacts work again, and bottle downloads report the real failure cause — but most of the value is invisible by design.

Recommended for all users. See the changelog below for per-fix detail.

---

### 🩹 Fixes

- **update/swap:** fsync before swap rename ([bae1db6](https://github.com/indaco/malt/commit/bae1db6)) ([#148](https://github.com/indaco/malt/pull/148))
- **core/cellar:** grow overflowing Mach-O slots via install_name_tool ([b3665b0](https://github.com/indaco/malt/commit/b3665b0)) ([#147](https://github.com/indaco/malt/pull/147))
- **cli/install:** restore clean post_install for ca-certificates ([63d2f7f](https://github.com/indaco/malt/commit/63d2f7f)) ([#146](https://github.com/indaco/malt/pull/146))
- **fs/archive:** allow prefix-relative symlinks in bottle extraction ([79d6894](https://github.com/indaco/malt/commit/79d6894)) ([#145](https://github.com/indaco/malt/pull/145))
- **core/formula:** add arm64_tahoe platform tag for macOS 26 ([7574b1e](https://github.com/indaco/malt/commit/7574b1e)) ([#144](https://github.com/indaco/malt/pull/144))
- **net/client,net/ghcr:** surface real cause of bottle download failures ([d3050f1](https://github.com/indaco/malt/commit/d3050f1)) ([#143](https://github.com/indaco/malt/pull/143))
- **macho/parser:** bubble InvalidLoadCommand from parseFat ([057efdb](https://github.com/indaco/malt/commit/057efdb)) ([#140](https://github.com/indaco/malt/pull/140))
- **db/lock:** retry on EINTR and handle WouldBlock ([85a1f1e](https://github.com/indaco/malt/commit/85a1f1e)) ([#139](https://github.com/indaco/malt/pull/139))
- **core/cask:** install .tar.gz casks with binary artifacts ([b604866](https://github.com/indaco/malt/commit/b604866)) ([#137](https://github.com/indaco/malt/pull/137))
- **core/dsl/parser:** save full heredoc state on identifier[ peeks ([ac61bfc](https://github.com/indaco/malt/commit/ac61bfc)) ([#134](https://github.com/indaco/malt/pull/134))
- **net/ghcr:** return owned token from fetchToken ([393458a](https://github.com/indaco/malt/commit/393458a)) ([#133](https://github.com/indaco/malt/pull/133))
- **macho/patcher:** correct NUL-terminator boundary check ([e678965](https://github.com/indaco/malt/commit/e678965)) ([#132](https://github.com/indaco/malt/pull/132))
- **fs/clonefile:** read errno correctly ([0e414b0](https://github.com/indaco/malt/commit/0e414b0)) ([#130](https://github.com/indaco/malt/pull/130))
- **fs/compat:** use std.Io.random for randomBytes ([50c4de5](https://github.com/indaco/malt/commit/50c4de5)) ([#129](https://github.com/indaco/malt/pull/129))
- **cli/version_update:** errdefer path in writeDownload ([460eb9c](https://github.com/indaco/malt/commit/460eb9c)) ([#122](https://github.com/indaco/malt/pull/122))
- **core:** cleanup duped row strings on partial-dupe failure ([ce71fd9](https://github.com/indaco/malt/commit/ce71fd9)) ([#121](https://github.com/indaco/malt/pull/121))
- **cli/install:** free per-dep parsed formulas in collectFormulaJobs ([7b49ece](https://github.com/indaco/malt/commit/7b49ece)) ([#120](https://github.com/indaco/malt/pull/120))
- **cli/migrate:** close leaks and propagate iterator errors ([98be4ed](https://github.com/indaco/malt/commit/98be4ed)) ([#119](https://github.com/indaco/malt/pull/119))

### 💅 Refactors

- **db/sqlite:** raise path and SQL caps ([f423be5](https://github.com/indaco/malt/commit/f423be5)) ([#149](https://github.com/indaco/malt/pull/149))
- **core/dsl/parser:** split parsePrimary into form-specific helpers ([f2b657d](https://github.com/indaco/malt/commit/f2b657d)) ([#138](https://github.com/indaco/malt/pull/138))
- **core/bottle:** distinguish PathTooLong from OutOfMemory ([a051aa7](https://github.com/indaco/malt/commit/a051aa7)) ([#135](https://github.com/indaco/malt/pull/135))
- adopt constantTimeEql at remaining sha-compare sites ([a387684](https://github.com/indaco/malt/commit/a387684)) ([#131](https://github.com/indaco/malt/pull/131))
- bubble SqliteError through core helpers ([059b715](https://github.com/indaco/malt/commit/059b715)) ([#128](https://github.com/indaco/malt/pull/128))
- **cli/install:** fix post_install formula cleanup chain ([126b427](https://github.com/indaco/malt/commit/126b427)) ([#127](https://github.com/indaco/malt/pull/127))
- replace anyerror in vtable callbacks with narrow sets ([2a69f54](https://github.com/indaco/malt/commit/2a69f54)) ([#126](https://github.com/indaco/malt/pull/126))
- **core/dsl:** exhaustive switch on DslError ([ee9d8db](https://github.com/indaco/malt/commit/ee9d8db)) ([#125](https://github.com/indaco/malt/pull/125))
- **cli/install:** narrow localErrorIsAnnounced to InstallError ([1f096cf](https://github.com/indaco/malt/commit/1f096cf)) ([#124](https://github.com/indaco/malt/pull/124))
- replace "catch {}" with try or PartialFailure ([8791ccd](https://github.com/indaco/malt/commit/8791ccd)) ([#123](https://github.com/indaco/malt/pull/123))
- **core/dsl:** arena-own ExecContext path bindings ([669fee8](https://github.com/indaco/malt/commit/669fee8)) ([#118](https://github.com/indaco/malt/pull/118))

### ⚡ Performance

- **update/verify:** stream SHA for self-update tarball ([4b2ae33](https://github.com/indaco/malt/commit/4b2ae33)) ([#142](https://github.com/indaco/malt/pull/142))
- **cli/install:** bounded pool for collectFormulaJobs ([df870f8](https://github.com/indaco/malt/commit/df870f8)) ([#141](https://github.com/indaco/malt/pull/141))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.9.0 - 2026-04-21

### 🚀 Enhancements

- **migrate:** --json output, SIGINT check, lock-timeout env ([7884185](https://github.com/indaco/malt/commit/7884185)) ([#108](https://github.com/indaco/malt/pull/108))

### 🩹 Fixes

- **core/cask:** honour MALT_PREFIX when choosing applications dir ([897c691](https://github.com/indaco/malt/commit/897c691)) ([#117](https://github.com/indaco/malt/pull/117))
- **net/client:** plug leaks in redirect-follow HEAD state machine ([42d10a9](https://github.com/indaco/malt/commit/42d10a9)) ([#115](https://github.com/indaco/malt/pull/115))
- **fs/archive:** allow intra-bundle relative symlink targets ([a5f032c](https://github.com/indaco/malt/commit/a5f032c)) ([#114](https://github.com/indaco/malt/pull/114))
- **core/sandbox/macos:** reap child and fix FD double-close on error ([efc8cf3](https://github.com/indaco/malt/commit/efc8cf3)) ([#113](https://github.com/indaco/malt/pull/113))
- **fs/archive:** sanitise archive entry paths against tar-slip ([37eba14](https://github.com/indaco/malt/commit/37eba14)) ([#112](https://github.com/indaco/malt/pull/112))
- **core/ruby_subprocess:** escape Ruby interpolations and tighten prefix validator ([f7bd381](https://github.com/indaco/malt/commit/f7bd381)) ([#111](https://github.com/indaco/malt/pull/111))
- **core/cask:** return owned app name from findAppInDir ([c213606](https://github.com/indaco/malt/commit/c213606)) ([#110](https://github.com/indaco/malt/pull/110))
- **fs/compat:** honor allocator contract on short reads ([a1a3ba3](https://github.com/indaco/malt/commit/a1a3ba3)) ([#109](https://github.com/indaco/malt/pull/109))

### 🏡 Chores

- **scripts,justfile:** path-aware install smoke on pre-push ([8c8d0ae](https://github.com/indaco/malt/commit/8c8d0ae)) ([#116](https://github.com/indaco/malt/pull/116))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.8.1 - 2026-04-20

### 🩹 Fixes

- **cask:** handle extensionless download URLs via HEAD redirect resolution ([770bb34](https://github.com/indaco/malt/commit/770bb34)) ([#107](https://github.com/indaco/malt/pull/107))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.8.0 - 2026-04-20

### Highlights

The native DSL grows up, self-update becomes as trustworthy as the install script, and malt finally renders correctly on light terminals.

- **More of your toolchain installs end-to-end without touching Ruby.** v0.4.0 shipped the native interpreter; this release is the one where it actually covers the packages people install every day. `mt install zig` no longer trips a parse error on `llvm@21`. `openssl@3`, `gnupg`, `ca-certificates`, `libidn2` now run their post-install logic inline in Zig — the same work that used to require spawning a Ruby subprocess, with all the latency and ambient-trust cost that implied. And when a formula does reach for something the interpreter doesn't speak yet, you get a specific `--use-system-ruby=<name>` hint instead of a silent skip that pretended to succeed. "post_install completed" now means exactly that.
- **`mt version update` closes its own trust gap.** Every release is now verified with cosign keyless signatures over `checksums.txt` (pinned to the release workflow identity) and SHA256 against the verified manifest before a single byte lands on disk — the same posture `install.sh` has had since v0.6.0. The binary swap itself is rename-based and atomic with a `.old` rollback, so a mid-flight failure can no longer leave a half-written executable. And when malt was installed through Homebrew, the updater steps aside and points at `brew upgrade --cask malt` rather than quietly desyncing Homebrew's install receipts.
- **Light terminals render legibly.** A semantic palette spans four cells — dark vs. light × truecolor vs. basic — detected once at startup via OSC 11, with `COLORFGBG` and `MALT_THEME` fallbacks and every color pinned to WCAG AA contrast by unit test. Dark-terminal output is byte-identical to before; light-terminal users stop losing the `⚠` warn icon, the `--local` security warning, and `mt info` meta rows into the background.
- **The rough edges you would have hit otherwise.** Post-install no longer reads silent fallbacks as success, gains a `--debug` flag that prints every DSL diagnostic, and emits structured per-package `post_install` status under `--json`. The release smoke job can now tell "tag exists but the asset hasn't propagated yet" apart from "the release is missing", so cold-release lag stops tripping false alarms.

---

### 🚀 Enhancements

- **update:** defer self-update to brew for Homebrew-managed installs ([3879e10](https://github.com/indaco/malt/commit/3879e10)) ([#98](https://github.com/indaco/malt/pull/98))
- **update:** atomic rename-based binary swap with .old rollback ([b488d5e](https://github.com/indaco/malt/commit/b488d5e)) ([#97](https://github.com/indaco/malt/pull/97))
- **update:** verify releases with cosign + SHA256 before installing ([743196a](https://github.com/indaco/malt/commit/743196a)) ([#96](https://github.com/indaco/malt/pull/96))
- **update:** add SHA256 and cosign verification primitives ([0680186](https://github.com/indaco/malt/commit/0680186)) ([#95](https://github.com/indaco/malt/pull/95))
- **update:** classify install origin so self-update can respect brew ([6b873f9](https://github.com/indaco/malt/commit/6b873f9)) ([#93](https://github.com/indaco/malt/pull/93))
- **dsl:** module constants, Set.new, pkgetc + CI corpus + backlog dashboard ([fcc0620](https://github.com/indaco/malt/commit/fcc0620)) ([#92](https://github.com/indaco/malt/pull/92))
- **dsl:** comparison operators, .blank?, if-as-rvalue + corpus smoke ([82b3a04](https://github.com/indaco/malt/commit/82b3a04)) ([#91](https://github.com/indaco/malt/pull/91))
- **dsl:** shovel operator (<<) on Array and String ([1a2c7c4](https://github.com/indaco/malt/commit/1a2c7c4)) ([#90](https://github.com/indaco/malt/pull/90))
- **dsl:** Enumerable methods on hash receivers (.map/.each/.select/.reject) ([c7efb4d](https://github.com/indaco/malt/commit/c7efb4d)) ([#89](https://github.com/indaco/malt/pull/89))
- **dsl:** Version-style accessors on strings (.major/.minor/.patch/.to_i) ([6363afb](https://github.com/indaco/malt/commit/6363afb)) ([#88](https://github.com/indaco/malt/pull/88))
- **dsl:** def and return with sibling-helper extraction ([917e6f1](https://github.com/indaco/malt/commit/917e6f1)) ([#87](https://github.com/indaco/malt/pull/87))
- **ui:** semantic palette for light + dark terminals ([c0eb98f](https://github.com/indaco/malt/commit/c0eb98f)) ([#83](https://github.com/indaco/malt/pull/83))

### 🩹 Fixes

- **purge:** run unused-deps before store-orphans in housekeeping ([57f756b](https://github.com/indaco/malt/commit/57f756b)) ([#106](https://github.com/indaco/malt/pull/106))
- **github:** make bug report form label parse cleanly ([2777172](https://github.com/indaco/malt/commit/2777172)) ([#105](https://github.com/indaco/malt/pull/105))
- **ui:** light palette — meta info recedes, basic variants align ([2017220](https://github.com/indaco/malt/commit/2017220)) ([#102](https://github.com/indaco/malt/pull/102))
- **dsl:** harden post_install DSL — block-pass, ::, diagnostics ([4cc6d01](https://github.com/indaco/malt/commit/4cc6d01)) ([#86](https://github.com/indaco/malt/pull/86))
- **release:** widen smoke wait and distinguish lag from missing release ([9f3514e](https://github.com/indaco/malt/commit/9f3514e)) ([#81](https://github.com/indaco/malt/pull/81))

### 💅 Refactors

- **update:** extract release-asset selection into src/update/release.zig ([fdbf2b1](https://github.com/indaco/malt/commit/fdbf2b1)) ([#94](https://github.com/indaco/malt/pull/94))

### 📖 Documentation

- **readme:** use the qualified tap form in the brew-install hint ([e16a375](https://github.com/indaco/malt/commit/e16a375)) ([#101](https://github.com/indaco/malt/pull/101))
- **update:** document cosign verification, brew guard, and bypass asymmetry ([ca1435c](https://github.com/indaco/malt/commit/ca1435c)) ([#99](https://github.com/indaco/malt/pull/99))

### 🏡 Chores

- update coverage badge ([6685ce6](https://github.com/indaco/malt/commit/6685ce6)) ([#104](https://github.com/indaco/malt/pull/104))
- **github:** add issue forms and PR template ([5d03683](https://github.com/indaco/malt/commit/5d03683)) ([#103](https://github.com/indaco/malt/pull/103))
- **update:** tighten idioms, fill test gaps, add --cleanup ([4b2612e](https://github.com/indaco/malt/commit/4b2612e)) ([#100](https://github.com/indaco/malt/pull/100))

### 🤖 CI

- **release:** trigger the release workflow on tag push ([4a0ee06](https://github.com/indaco/malt/commit/4a0ee06)) ([#82](https://github.com/indaco/malt/pull/82))

### Other

- update benchmark results 2026-04-20 ([fa7db3a](https://github.com/indaco/malt/commit/fa7db3a))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.7.0 - 2026-04-18

### 🚀 Enhancements

- **install:** install formulas from a local .rb file ([6d66d1e](https://github.com/indaco/malt/commit/6d66d1e)) ([#78](https://github.com/indaco/malt/pull/78))

### 🩹 Fixes

- **cask:** hash multi-chunk downloads correctly ([524c52d](https://github.com/indaco/malt/commit/524c52d)) ([#80](https://github.com/indaco/malt/pull/80))
- **install:** install revisioned formulas at versioned_revision dir ([e05f041](https://github.com/indaco/malt/commit/e05f041)) ([#79](https://github.com/indaco/malt/pull/79))
- **install:** widen API retry budget for cold-release propagation ([635c801](https://github.com/indaco/malt/commit/635c801)) ([#76](https://github.com/indaco/malt/pull/76))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.6.2 - 2026-04-18

### 🩹 Fixes

- **install:** restore source-fallback after API failure ([0526027](https://github.com/indaco/malt/commit/0526027)) ([#75](https://github.com/indaco/malt/pull/75))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.6.1 - 2026-04-18

### Highlights

This release is the follow-through on v0.6's security pass: the fail-closed gates it
introduced were correctly wired, but silently empty in practice. Plus a rough edge in the install UX.

- **`post_install` actually runs for the packages that need it.** The allowlist that authorizes malt to execute a formula's Ruby `post_install` shipped empty in v0.6, so side effects like `ca-certificates` rebuilding the cert bundle, `openssl@3` wiring its cert store, or `node` configuring npm were silently skipped on every install. `scripts/gen-pins.sh` now enumerates every formula in homebrew-core with `post_install_defined` straight from the Homebrew API, and a parallel hashing bug that made every entry mismatch at runtime is fixed. A monthly CI workflow opens an auto-PR to refresh the pin, and a drift guard on every PR fails if the manifest falls out of sync. "Fail-closed" now means something.
- **Tap installs feel like everything else.** `malt install user/tap/formula` used to sit silent until the archive landed - no progress bar, no feedback. It now streams through the same progress renderer as formula bottles and cask DMGs.

---

### 🩹 Fixes

- **pins:** authorize post_install for common TLS + language formulas ([1acbaba](https://github.com/indaco/malt/commit/1acbaba)) ([#70](https://github.com/indaco/malt/pull/70))
- **install:** show progress bar for tap installs ([645c74b](https://github.com/indaco/malt/commit/645c74b)) ([#69](https://github.com/indaco/malt/pull/69))

### ✅ Tests

- **release:** smoke the live release install end-to-end ([116f817](https://github.com/indaco/malt/commit/116f817)) ([#68](https://github.com/indaco/malt/pull/68))

### 🤖 CI

- **release:** disable zig-cache so poisoned entries can't block a release ([54192e0](https://github.com/indaco/malt/commit/54192e0)) ([#72](https://github.com/indaco/malt/pull/72))
- **release:** run the live-install smoke in-sequence, not on a parallel trigger ([65922e0](https://github.com/indaco/malt/commit/65922e0)) ([#71](https://github.com/indaco/malt/pull/71))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.6.0 - 2026-04-17

### Highlights

This release is a security pass. Every path from curl … | bash through malt install has been tightened against a concrete threat.

- **Release signing closes the install-path trust gap.** Every GitHub release is now signed keyless via cosign/Sigstore, and install.sh verifies the signature against the signing workflow's identity before it trusts the checksum. The build-from-source fallback clones at a tagged release instead of whatever main happens to point at. Together these close the last "just trust whatever HTTPS returned" step on the install path - a compromised GitHub token is no longer enough to ship a malicious malt binary.
- **post_install runs in a real sandbox.** The --use-system-ruby path - previously a full Ruby interpreter running with your UID and no containment - now runs inside a sandbox-exec profile confined to the formula's own cellar, with a scrubbed environment, resource limits, and terminal escape sequences filtered before they hit your scrollback. A hostile formula's blast radius shrinks from "your home directory" to "its own install prefix." The flag is also per-formula now, so one package's post_install failing can't silently widen the trust boundary for the rest of an install batch.
- **Third-party formula sources are pinned.** Ruby formulas from homebrew-core are SHA256-verified against an embedded manifest at a specific pinned commit. Third-party taps (malt tap user/repo) pin their HEAD commit at tap time; advancing the pin is an explicit `malt tap --refresh`. A force-pushed tap or a rewritten branch cannot swap a formula's bottle URL out from under malt.
- **Boundary validation, everywhere.** `MALT_PREFIX`, launchd service definitions, the install script's checksum paths, and the HTTP client's redirect chain all fail-closed on malformed or suspicious input. Malformed prefixes exit with a clear error; hostile service blocks can't launch /bin/sh at login; HTTPS requests can't be silently downgraded to plaintext mid-chain.
- **Posture visibility in malt doctor.** Weak permissions on `/opt/malt` - world-writable files, group-writable directories, paths owned by an unexpected user - now show up as warnings with a count and a short list. Multi-user machines can see their attack surface at a glance.
- **Lock-in for what was already clean.** The argv-only spawn convention (no `sh -c` anywhere in the codebase) and the install script's fail-closed checksum behavior are now covered by regression tests and CI gates, so neither can quietly drift.

---

### 🚀 Enhancements

- **security:** pin third-party taps to a commit SHA ([a02a2aa](https://github.com/indaco/malt/commit/a02a2aa)) ([#64](https://github.com/indaco/malt/pull/64))
- **security:** audit /opt/malt permissions in malt doctor ([0386e02](https://github.com/indaco/malt/commit/0386e02)) ([#63](https://github.com/indaco/malt/pull/63))
- **security:** filter terminal escapes from ruby post_install output ([c162bdf](https://github.com/indaco/malt/commit/c162bdf)) ([#62](https://github.com/indaco/malt/pull/62))
- **security:** refuse https → http redirect downgrades ([e4a6250](https://github.com/indaco/malt/commit/e4a6250)) ([#61](https://github.com/indaco/malt/pull/61))
- **security:** pin install.sh source fallback to a release tag ([cc5f697](https://github.com/indaco/malt/commit/cc5f697)) ([#60](https://github.com/indaco/malt/pull/60))
- **security:** validate MALT_PREFIX at the env boundary ([ba6c786](https://github.com/indaco/malt/commit/ba6c786)) ([#59](https://github.com/indaco/malt/pull/59))
- **security:** harden post-install pipeline and service declarations ([b9be902](https://github.com/indaco/malt/commit/b9be902)) ([#58](https://github.com/indaco/malt/pull/58))

### 🩹 Fixes

- **doctor:** match the rest of malt's UI palette ([de612d4](https://github.com/indaco/malt/commit/de612d4)) ([#66](https://github.com/indaco/malt/pull/66))

### 📖 Documentation

- **readme:** document the new security surface ([83ed26a](https://github.com/indaco/malt/commit/83ed26a)) ([#65](https://github.com/indaco/malt/pull/65))

### 🏡 Chores

- normalize scripts and lint on pre push hook ([675f94b](https://github.com/indaco/malt/commit/675f94b)) ([#56](https://github.com/indaco/malt/pull/56))

### 🤖 CI

- **release:** run goreleaser before publishing release notes ([cb3bde5](https://github.com/indaco/malt/commit/cb3bde5)) ([#67](https://github.com/indaco/malt/pull/67))
- **release:** sign artifacts with cosign keyless ([387aedc](https://github.com/indaco/malt/commit/387aedc)) ([#57](https://github.com/indaco/malt/pull/57))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.5.1 - 2026-04-16

### 🩹 Fixes

- **cli:** make --version and --help/-h dispatch as commands ([f56a965](https://github.com/indaco/malt/commit/f56a965)) ([#55](https://github.com/indaco/malt/pull/55))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.5.0 - 2026-04-16

### 🚀 Enhancements

- **upgrade:** dim already-at-latest lines so real work pops ([883a9cf](https://github.com/indaco/malt/commit/883a9cf)) ([#48](https://github.com/indaco/malt/pull/48))

### 🩹 Fixes

- **install:** collapse keg-only "not linking" line into ✓ suffix ([10ba32e](https://github.com/indaco/malt/commit/10ba32e)) ([#53](https://github.com/indaco/malt/pull/53))
- **install:** verify checksum, support env prefix override ([e42bede](https://github.com/indaco/malt/commit/e42bede)) ([#51](https://github.com/indaco/malt/pull/51))
- **upgrade:** skip "Upgrading…" line when dry-running ([f80f9d1](https://github.com/indaco/malt/commit/f80f9d1)) ([#49](https://github.com/indaco/malt/pull/49))
- **tests:** run zig build test without deadlocking ([6f8b49b](https://github.com/indaco/malt/commit/6f8b49b)) ([#47](https://github.com/indaco/malt/pull/47))
- **install:** heal dep opt/ symlinks so bottled binaries keep loading ([95ce71d](https://github.com/indaco/malt/commit/95ce71d)) ([#46](https://github.com/indaco/malt/pull/46))

### 📖 Documentation

- **readme:** add version badge ([ec90dee](https://github.com/indaco/malt/commit/ec90dee))
- add polished-output bullet and extend demo with info ([fe89ee3](https://github.com/indaco/malt/commit/fe89ee3)) ([#52](https://github.com/indaco/malt/pull/52))

### 🏡 Chores

- update coverage badge ([c2e4813](https://github.com/indaco/malt/commit/c2e4813))
- **bench:** drop bru from benchmark comparison ([8c001ed](https://github.com/indaco/malt/commit/8c001ed)) ([#50](https://github.com/indaco/malt/pull/50))
- **info:** cleaner output with bold header and aligned dim keys ([1d203dd](https://github.com/indaco/malt/commit/1d203dd)) ([#45](https://github.com/indaco/malt/pull/45))
- migrate to Zig 0.16 with faster installs and a smaller release binary ([d9bb663](https://github.com/indaco/malt/commit/d9bb663)) ([#44](https://github.com/indaco/malt/pull/44))

### 🤖 CI

- **bench:** make benchmark numbers fair and noise-visible ([6aae849](https://github.com/indaco/malt/commit/6aae849)) ([#54](https://github.com/indaco/malt/pull/54))

### Other

- update benchmark results 2026-04-16 ([7bd11be](https://github.com/indaco/malt/commit/7bd11be))
- update benchmark results 2026-04-16 ([12bad7e](https://github.com/indaco/malt/commit/12bad7e))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.4.1 - 2026-04-15

### 🩹 Fixes

- **cli:** exit non-zero on every user-facing failure ([e7993d6](https://github.com/indaco/malt/commit/e7993d6)) ([#41](https://github.com/indaco/malt/pull/41))
- **json:** escape strings in --json output ([0a1f0d6](https://github.com/indaco/malt/commit/0a1f0d6)) ([#40](https://github.com/indaco/malt/pull/40))
- **help:** send --help output to stdout ([3b336ae](https://github.com/indaco/malt/commit/3b336ae)) ([#38](https://github.com/indaco/malt/pull/38))
- **rollback:** exit non-zero on failure ([568763c](https://github.com/indaco/malt/commit/568763c)) ([#37](https://github.com/indaco/malt/pull/37))

### 💅 Refactors

- **cli:** drop redundant flag re-parsing ([f00d9a1](https://github.com/indaco/malt/commit/f00d9a1)) ([#42](https://github.com/indaco/malt/pull/42))

### 📖 Documentation

- **readme:** note --casks / --formulae plural aliases ([25c0c9e](https://github.com/indaco/malt/commit/25c0c9e)) ([#43](https://github.com/indaco/malt/pull/43))

### 🤖 CI

- bypass zig test-runner deadlock by running test binaries directly ([18733e8](https://github.com/indaco/malt/commit/18733e8)) ([#39](https://github.com/indaco/malt/pull/39))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.4.0 - 2026-04-15

### Highlights

- **Native Zig interpreter for Homebrew `post_install`.** The defining change in this release. Most Homebrew-compatible clients either skip `post_install` entirely or shell out to Ruby. malt now runs those blocks inline in Zig, so packages like `node`, `openssl`, `fontconfig`, and `docbook` arrive fully configured — no Ruby subprocess, no "install succeeded but nothing works" surprises. When a block uses a construct outside the interpreter's vocabulary, `--use-system-ruby` falls through to whatever Ruby is already on the box; no hard dependency.
- **Discovery catches up to brew.** `mt search` now returns every formula and cask whose name contains the query (not just exact matches). `mt info` shows full Homebrew metadata for packages that aren't installed locally, and both work on a completely fresh machine. New `mt uses <formula>` answers "what depends on this?" with an optional `--recursive` mode for the full transitive closure.
- **Two install paths that used to silently fail now work.** User taps can ship `.zip` archives — HashiCorp's lineup (terraform, consul, vault) and anything following the same release shape. Inline `user/tap/formula` installs route correctly, and `mt untap` actually untaps.
- **Homebrew parity for a real workflow.** `mt services` manages long-running launchd services (start / stop / status / logs). `mt bundle` installs and exports Brewfile / Maltfile.json sets.
- **Self-update, finally.** `mt version update` was broken end-to-end since the first release: the asset matcher missed every GoReleaser tarball, a shared stack buffer turned the on-disk copy into a no-op, and the binary layout inside the archive didn't match the code's expectations. All three are fixed, with tests. Every distribution path (script, Homebrew, release tarball, `zig build`) now ships both `malt` and `mt`.
- **Housekeeping, hardened.** `mt purge` replaces the scattered `cleanup` / `gc` / `autoremove` commands with a single scope-gated command. Mach-O parsing is overflow-safe. The Zig codebase received a hardening pass across allocators, error paths, and arg handling.

### Upgrading

`mt version update`

If you're on an older release, grab the installer or use Homebrew:

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash

# or
brew install --cask indaco/tap/malt
```

---

### 🚀 Enhancements

- **uses:** reverse-dependency query command ([83171e6](https://github.com/indaco/malt/commit/83171e6)) ([#34](https://github.com/indaco/malt/pull/34))
- **install:** support .zip archives for tap formulae ([5adc5ba](https://github.com/indaco/malt/commit/5adc5ba)) ([#32](https://github.com/indaco/malt/pull/32))
- **search:** match brew's substring behavior ([cf4b51f](https://github.com/indaco/malt/commit/cf4b51f)) ([#29](https://github.com/indaco/malt/pull/29))
- add `mt services` and `mt bundle` (Homebrew parity) ([5601d5c](https://github.com/indaco/malt/commit/5601d5c)) ([#20](https://github.com/indaco/malt/pull/20))
- **dsl:** native Zig interpreter for post_install blocks ([c86a8d7](https://github.com/indaco/malt/commit/c86a8d7)) ([#19](https://github.com/indaco/malt/pull/19))
- **install:** --use-system-ruby post_install stopgap ([7ebb542](https://github.com/indaco/malt/commit/7ebb542)) ([#18](https://github.com/indaco/malt/pull/18))

### 🩹 Fixes

- **version-update:** make self-update actually replace the binary ([9254b57](https://github.com/indaco/malt/commit/9254b57)) ([#35](https://github.com/indaco/malt/pull/35))
- **info:** brew-style output on fresh machines ([d1d379b](https://github.com/indaco/malt/commit/d1d379b))
- mt install user/tap/formula + untap ([e194971](https://github.com/indaco/malt/commit/e194971)) ([#28](https://github.com/indaco/malt/pull/28))
- **core:** overflow-safe Mach-O parsing + system tar extraction ([96567bf](https://github.com/indaco/malt/commit/96567bf)) ([#17](https://github.com/indaco/malt/pull/17))

### 💅 Refactors

- dedupe list --json emission ([5ceebd8](https://github.com/indaco/malt/commit/5ceebd8)) ([#27](https://github.com/indaco/malt/pull/27))
- zig hardening pass ([cb468a0](https://github.com/indaco/malt/commit/cb468a0)) ([#25](https://github.com/indaco/malt/pull/25))
- unify housekeeping commands under `mt purge` ([559dab6](https://github.com/indaco/malt/commit/559dab6)) ([#21](https://github.com/indaco/malt/pull/21))

### 📖 Documentation

- document bru cache caveat via Methodology callout ([3caece9](https://github.com/indaco/malt/commit/3caece9)) ([#36](https://github.com/indaco/malt/pull/36))
- correct cold start timing in README ([b6414cb](https://github.com/indaco/malt/commit/b6414cb)) ([#33](https://github.com/indaco/malt/pull/33))
- tighten README and normalize binary size units ([5bcee31](https://github.com/indaco/malt/commit/5bcee31)) ([#24](https://github.com/indaco/malt/pull/24))
- **justfile:** clarify bench env var usage ([44035a9](https://github.com/indaco/malt/commit/44035a9))

### 🏡 Chores

- update .gitignore ([ab4e340](https://github.com/indaco/malt/commit/ab4e340))

### 🤖 CI

- drop unused binary artifact upload ([50288e4](https://github.com/indaco/malt/commit/50288e4)) ([#31](https://github.com/indaco/malt/pull/31))
- **benchmark:** only commit README updates when running on main ([69aa746](https://github.com/indaco/malt/commit/69aa746)) ([#26](https://github.com/indaco/malt/pull/26))
- run only on zig source changes ([9e33f36](https://github.com/indaco/malt/commit/9e33f36))

### Other

- update benchmark results 2026-04-14 ([a578f69](https://github.com/indaco/malt/commit/a578f69))
- update benchmark results 2026-04-13 ([fffa8bf](https://github.com/indaco/malt/commit/fffa8bf))
- update benchmark results 2026-04-13 ([368680e](https://github.com/indaco/malt/commit/368680e))
- update benchmark results 2026-04-12 ([17d48e3](https://github.com/indaco/malt/commit/17d48e3))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.3.1 - 2026-04-12

### 🩹 Fixes

- **core/deps:** free orphaned dep strings in resolve BFS ([8c137d2](https://github.com/indaco/malt/commit/8c137d2)) ([#15](https://github.com/indaco/malt/pull/15))

### 📖 Documentation

- **readme:** fix callouts types ([00e8664](https://github.com/indaco/malt/commit/00e8664))
- **readme:** use INFO callouts on the benchmark section ([f7bbb69](https://github.com/indaco/malt/commit/f7bbb69))
- **readme:** fix typos in github callouts types ([e7209f0](https://github.com/indaco/malt/commit/e7209f0))

### ✅ Tests

- raise code coverage ([6d6e4e3](https://github.com/indaco/malt/commit/6d6e4e3)) ([#16](https://github.com/indaco/malt/pull/16))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.3.0 - 2026-04-11

### 🚀 Enhancements

- **cli:** add `mt purge` to wipe a malt installation ([a70ccae](https://github.com/indaco/malt/commit/a70ccae)) ([#10](https://github.com/indaco/malt/pull/10))
- **cli:** add backup and restore commands ([16ac579](https://github.com/indaco/malt/commit/16ac579)) ([#7](https://github.com/indaco/malt/pull/7))
- **cli:** add `completions` command for bash, zsh, and fish ([6393b06](https://github.com/indaco/malt/commit/6393b06)) ([#5](https://github.com/indaco/malt/pull/5))
- **install:** download progress bars and materialize spinner ([9a265ad](https://github.com/indaco/malt/commit/9a265ad)) ([#4](https://github.com/indaco/malt/pull/4))

### 🩹 Fixes

- multi-package install correctness sweep ([ea64fc4](https://github.com/indaco/malt/commit/ea64fc4)) ([#11](https://github.com/indaco/malt/pull/11))
- **cli:** honour global --dry-run flag in subcommands ([75da6a6](https://github.com/indaco/malt/commit/75da6a6)) ([#6](https://github.com/indaco/malt/pull/6))

### 📖 Documentation

- **readme:** add demo gif and recording tape ([ab8176e](https://github.com/indaco/malt/commit/ab8176e))
- **readme:** added mt backup and mt restore sections ([fcef76b](https://github.com/indaco/malt/commit/fcef76b)) ([#9](https://github.com/indaco/malt/pull/9))

### ⚡ Performance

- faster warm installs, cleaner install pipeline ([06962ec](https://github.com/indaco/malt/commit/06962ec)) ([#13](https://github.com/indaco/malt/pull/13))

### 🎨 Styling

- **readme:** reformat benchmark tables ([24dc7b2](https://github.com/indaco/malt/commit/24dc7b2))

### 🏡 Chores

- add code coverage tooling (kcov + Codecov) ([f7721f9](https://github.com/indaco/malt/commit/f7721f9)) ([#12](https://github.com/indaco/malt/pull/12))
- **justfile:** add `install` recipe delegating to scripts/install.sh ([4d1fc81](https://github.com/indaco/malt/commit/4d1fc81))
- **devbox:** reuse justfile recipes in shell scripts ([64c1b9d](https://github.com/indaco/malt/commit/64c1b9d)) ([#8](https://github.com/indaco/malt/pull/8))

### Other

- update benchmark results 2026-04-11 ([d78c146](https://github.com/indaco/malt/commit/d78c146))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.2.1 - 2026-04-09

### 🩹 Fixes

- **cellar:** always substitute @@HOMEBREW\_\*@@ placeholders in text files ([bbc4cc1](https://github.com/indaco/malt/commit/bbc4cc1)) ([#3](https://github.com/indaco/malt/pull/3))
- **cellar:** resolve nested directory in keg after bottle extraction ([47426a2](https://github.com/indaco/malt/commit/47426a2)) ([#2](https://github.com/indaco/malt/pull/2))

**Full Changelog:** [v0.2.0...v0.2.1](https://github.com/indaco/malt/compare/v0.2.0...v0.2.1)

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.2.0 - 2026-04-09

### 🚀 Enhancements

- cask command parity for info, outdated, cleanup ([64cac0c](https://github.com/indaco/malt/commit/64cac0c)) ([#1](https://github.com/indaco/malt/pull/1))

### Other

- update benchmark results 2026-04-09 ([71ef557](https://github.com/indaco/malt/commit/71ef557))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.1.1 - 2026-04-09

### 🩹 Fixes

- **search:** consistent TUI output and working JSON mode ([1b3daaf](https://github.com/indaco/malt/commit/1b3daaf))
- **net:** use streamRemaining for HTTP body reads ([cbab4bc](https://github.com/indaco/malt/commit/cbab4bc))

### 🤖 CI

- replace deprecated archives.format with archives.formats in goreleaser config ([8ad73e0](https://github.com/indaco/malt/commit/8ad73e0))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.1.0 - 2026-04-09

### 🏡 Chores

- Initial Release

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
