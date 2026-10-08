# malt

**Homebrew's whole ecosystem, none of its weight.** malt is a ~5 MB Zig binary. It uses every Homebrew bottle and formula. It runs post-install work natively: the Homebrew install steps and the Ruby `post_install` blocks that taps still ship. Thus, packages work correctly. malt has a CLI and a TUI, and both use themes.

malt installs to its own prefix, `/opt/malt`. A cold start takes ~3 ms. A human designed malt. AI wrote the code.

![Version](https://img.shields.io/github/v/tag/indaco/malt?label=version&sort=semver&color=4c1&logo=git&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green?logo=opensourceinitiative&logoColor=white)
![macOS only](https://img.shields.io/badge/platform-macOS-blue?logo=apple&logoColor=white)
![Zig 0.16.x](https://img.shields.io/badge/zig-0.16.x-F7A41D?logo=zig)
[![codecov](https://codecov.io/gh/indaco/malt/branch/main/graph/badge.svg)](https://codecov.io/gh/indaco/malt)
[![Signed by cosign](https://img.shields.io/badge/signed-cosign-brightgreen?logo=data:image/svg%2Bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0iI2ZmZiI+PHBhdGggZD0iTTEyIDFhNSA1IDAgMCAwLTUgNXYzSDZhMiAyIDAgMCAwLTIgMnYxMGEyIDIgMCAwIDAgMiAyaDEyYTIgMiAwIDAgMCAyLTJWMTFhMiAyIDAgMCAwLTItMmgtMVY2YTUgNSAwIDAgMC01LTV6bTAgMmEzIDMgMCAwIDEgMyAzdjNIOVY2YTMgMyAwIDAgMSAzLTN6bTAgMTBhMiAyIDAgMCAxIDEgMy43VjE5aC0ydi0yLjNBMiAyIDAgMCAxIDEyIDEzeiIvPjwvc3ZnPg==)](#safety-and-security)
[![Built with Devbox](https://www.jetify.com/img/devbox/shield_galaxy.svg)](https://www.jetify.com/devbox/docs/contributor-quickstart/)

<p align="center">
  <b><a href="#why-this-and-whats-different">Why malt</a></b> &middot;
  <b><a href="#installation">Install</a></b> &middot;
  <b><a href="#first-commands">First commands</a></b> &middot;
  <b><a href="#theming">Theming</a></b> &middot;
  <b><a href="#interactive-dashboard">TUI</a></b> &middot;
  <b><a href="#command-reference">Reference</a></b> &middot;
  <b><a href="#safety-and-security">Security</a></b> &middot;
  <b><a href="ARCHITECTURE.md">Architecture</a></b> &middot;
  <b><a href="#benchmarks">Benchmarks</a></b>
</p>

<p align="center">
  <img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/demo.gif" alt="malt install jq tree ripgrep - demo" width="800">
</p>
<p align="center">
  <sub>The demo does not show all of the latest features. The workflow in the demo is still correct.</sub>
</p>

> [!IMPORTANT]
> **malt is experimental and under active development.** It works well for common packages. I use it every day as my primary package manager on macOS. But some functions can fail on your setup. The CLI is stable, and large breaking changes are unlikely. Bugs are still likely.
>
> If you find a bug, [open an issue](https://github.com/indaco/malt/issues/new). Bugs that users report get first priority, and their fixes ship in patch releases.
>
> This README follows `main`, the development branch. It can document features that are not in the latest release yet. For the features that `install.sh` and the cask install, read the README on the current `release/0.X` branch. That branch is the supported minor line, and it agrees with its patch releases.

## Why this, and what's different

malt is a **client** for the Homebrew registry, not a fork. It uses every formula, bottle, cask, tap, and `Brewfile` in the ecosystem. It installs to its own prefix, `/opt/malt`, and it does not change Homebrew files. If `brew` is installed, malt sends each command that it does not implement to `brew`. These are the differences:

- **It completes the install.** Most alternative clients stop before post-install, and some packages then do not work. malt runs the two kinds of post-install work natively. The first kind is the Homebrew declarative steps: `post_install_steps` for formulae (v6) and flight steps for casks (v7). homebrew-core now uses these steps everywhere. The second kind is the Ruby `post_install` blocks that third-party taps still ship. A built-in Zig interpreter runs them. → [Post-install](ARCHITECTURE.md#post-install-and-flight-steps)
- **Repeat installs are free.** malt stores bottles by SHA256, and kegs are APFS `clonefile()` copies. Thus, malt never downloads or extracts the same bottle two times. Reinstalls and rollbacks use no network and no additional disk space. An `ffmpeg` install from an existing store completes in **tens of milliseconds**. → [Benchmarks](#benchmarks)
- **Safety with a fast start.** malt checks the SHA256 of each download while it streams. Each install has 9 atomic steps, and the old version stays unchanged until the new version passes verification. A 30 s lock stops concurrent changes. Subprocesses run in a sandbox. The binary is ~5 MB and starts in ~3 ms. → [Safety and security](ARCHITECTURE.md#safety-and-security)
- **One theme for all output.** One `MALT_THEME` palette sets the colours of the CLI and of the `mt tui` dashboard. → [Theming](#theming)
- **A dashboard that runs the real CLI.** From one screen, `mt tui` can search, install, upgrade, control services, and run doctor. It sends each action to `mt <subcommand>`. It needs no daemon and no second binary. → [Interactive dashboard](#interactive-dashboard)
- **Taps on all major forges.** malt supports GitHub, GitLab (also self-hosted), Codeberg/Forgejo/Gitea, and Gogs. It uses the forge API and does not clone the full repository. For private taps, each forge has its own token. → [Supported forges](#supported-forges)
- **Signed releases that you can verify.** Each release has a keyless cosign signature through GitHub OIDC. `install.sh` and `mt version update` verify the signature before they trust the checksum. → [Safety and security](ARCHITECTURE.md#safety-and-security)

malt has more functions. `mt run <pkg>` runs a package without a permanent install. Other commands control services, bundles, doctor, purge, backup and restore, migration, and reverse-dependency queries. Many commands give `--json` or `--output-format=ndjson` output for scripts. Refer to the [Command reference](#command-reference).

> [!NOTE]
> **Compatibility note.** "Drop-in" applies to the directives that a typical `Brewfile` uses: `tap`, `brew`, `cask`, `mas`, and `vscode`. It also applies to hash options and Ruby symbols. The parser reads and writes `mas` and `vscode` lines, but malt does not install them yet. Ruby `do … end` blocks and conditionals such as `if OS.mac?` are _not_ supported. Both cause a clear error. malt is for macOS only. Linux and Windows are out of scope.

> [!NOTE]
> **Built by human-directed AI.** A human did the design and the architecture, and a human reviews each merged change. [Claude Code](https://claude.ai/code) wrote all of the Zig code. A set of skills and guideline frameworks controls it: [ruflo](https://github.com/ruvnet/ruflo), [superpowers](https://github.com/obra/superpowers), [andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills), [improve](https://github.com/shadcn/improve), and project-specific skills. These frameworks apply the discipline that a human would otherwise apply manually. malt had more than one full refactor of the install protocol, the `post_install` interpreter, and the Mach-O patcher. ADRs and security reviews controlled each refactor. The repository, the test suite, and the tool itself are the evidence.

## Installation

There are three install methods. Select the method that matches your setup.

### One-liner script

The script does these steps:

1. It downloads the latest release.
2. It verifies the SHA256 checksum **and a cosign keyless signature** against the GitHub Actions workflow that made the release.
3. It installs the binary in `/usr/local/bin/`.
4. It creates `/opt/malt` with the correct ownership.

```bash
curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash
```

The script needs [`cosign`](https://docs.sigstore.dev/cosign/system_config/installation/) on your `PATH`. To skip verification, set `MALT_ALLOW_UNVERIFIED=1` (not recommended). If no release matches your platform, the script builds malt from source.

To verify `install.sh` separately, download it from a release tag. The example uses the latest tag, but you can use any release that you trust. Then compare its SHA256 with the value in the release notes:

```bash
curl -fsSL "https://raw.githubusercontent.com/indaco/malt/v0.25.0/scripts/install.sh" -o install.sh
shasum -a 256 install.sh
bash install.sh
```

### Via Homebrew

malt is available as a Homebrew cask:

```bash
brew install --cask indaco/tap/malt
```

The full `<tap>/<cask>` name adds the tap automatically. To upgrade, use `brew upgrade --cask malt`. If Homebrew manages the install, `mt version update` tells you to use `brew upgrade --cask malt`.

### From source

Clone the repository and run the install script. The script finds the local checkout and builds malt from source:

```bash
git clone https://github.com/indaco/malt.git
cd malt
./scripts/install.sh
```

The build needs [Zig 0.16.x](https://ziglang.org/download/). It puts `malt` in `zig-out/bin/`, and `mt` in the same directory as a symlink to `malt`. For development builds (debug, tests, universal binary), refer to [CONTRIBUTING](CONTRIBUTING.md#build--test).

## First commands

Before you start, add the malt binaries to the `PATH` of new shells. `mt shellenv` is a drop-in replacement for `eval "$(brew shellenv)"`:

```bash
echo 'eval "$(mt shellenv)"' >> ~/.zshrc          # or ~/.bashrc
mt shellenv fish | source                          # fish: set -gx, not export
```

This is an example of a first session:

```bash
mt install jq wget ripgrep        # parallel downloads, single lock
mt list --versions                # see what landed
mt info ripgrep                   # version, tap, cellar path, pinned status
mt outdated                       # what has updates available
mt upgrade ripgrep                # atomic; old version is restored on failure
```

`mt` and `malt` are the same binary. `mt` is a symlink to `malt`, and all install methods include it. There are two more aliases: `remove` for `uninstall` and `ls` for `list`. Each command that accepts `--formula` or `--cask` also accepts `--formulae` or `--casks`.

If malt does not implement a command, malt looks for `brew` and sends the command to it without a message. If `brew` is not installed, malt shows this error:

```text
malt: '<cmd>' is not a malt command and brew was not found.
Install Homebrew: https://brew.sh
```

## Theming

`MALT_THEME` selects the palette for _all_ malt output, in the CLI and in `mt tui`. Thus, `MALT_THEME=dracula mt outdated` and `MALT_THEME=dracula mt tui` use the same colours. malt has a **default** palette that adapts to the terminal background, and ten named palettes. This table groups the palettes by the terminal background that they are for:

| Background | Themes                                                                                          |
| ---------- | ----------------------------------------------------------------------------------------------- |
| Adaptive   | `default` - follows the terminal background (`auto`/`light`/`dark` select it)                   |
| Dark       | `dracula`, `catppuccin-mocha`, `rose-pine`, `nord`, `tokyo-night`, `gruvbox-dark`, `everforest` |
| Light      | `catppuccin-latte`, `rose-pine-dawn`, `gruvbox-light`                                           |

<details>
<summary><b>The default palette and all named themes</b>: CLI and <code>mt tui</code> side by side</summary>
<br>

<table align="center">
  <tr>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-default-dark.png" alt="default theme on a dark terminal - CLI and mt tui" width="440" /><br/><sub><code>default</code> (dark terminal)</sub></td>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-default-light.png" alt="default theme on a light terminal - CLI and mt tui" width="440" /><br/><sub><code>default</code> (light terminal)</sub></td>
  </tr>
  <tr>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-dracula.png" alt="dracula theme - CLI and mt tui" width="440" /><br/><sub><code>MALT_THEME=dracula</code></sub></td>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-catppuccin-mocha.png" alt="catppuccin-mocha theme - CLI and mt tui" width="440" /><br/><sub><code>MALT_THEME=catppuccin-mocha</code></sub></td>
  </tr>
  <tr>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-rose-pine.png" alt="rose-pine theme - CLI and mt tui" width="440" /><br/><sub><code>MALT_THEME=rose-pine</code></sub></td>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-nord.png" alt="nord theme - CLI and mt tui" width="440" /><br/><sub><code>MALT_THEME=nord</code></sub></td>
  </tr>
  <tr>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-tokyo-night.png" alt="tokyo-night theme - CLI and mt tui" width="440" /><br/><sub><code>MALT_THEME=tokyo-night</code></sub></td>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-gruvbox-dark.png" alt="gruvbox-dark theme - CLI and mt tui" width="440" /><br/><sub><code>MALT_THEME=gruvbox-dark</code></sub></td>
  </tr>
  <tr>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-catppuccin-latte.png" alt="catppuccin-latte theme - CLI and mt tui" width="440" /><br/><sub><code>MALT_THEME=catppuccin-latte</code></sub></td>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-rose-pine-dawn.png" alt="rose-pine-dawn theme - CLI and mt tui" width="440" /><br/><sub><code>MALT_THEME=rose-pine-dawn</code></sub></td>
  </tr>
  <tr>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-gruvbox-light.png" alt="gruvbox-light theme - CLI and mt tui" width="440" /><br/><sub><code>MALT_THEME=gruvbox-light</code></sub></td>
    <td align="center" valign="middle"><img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/themes/theme-everforest.png" alt="everforest theme - CLI and mt tui" width="440" /><br/><sub><code>MALT_THEME=everforest</code></sub></td>
  </tr>
</table>

</details>

`light`, `dark`, and `auto` keep the default palette, which adapts to the background. `auto` finds the background through OSC 11. Named themes need a truecolor terminal. malt uses the default palette instead in two conditions: on a basic terminal, and when the terminal background does not agree with the theme (for example, a dark theme on a light terminal).

### Custom themes

To define your own palettes, put them in a JSON file at `MALT_THEMES_FILE`. If that variable is not set, malt uses `{prefix}/etc/malt/themes.json`. malt reads the file one time at start and handles its themes as built-in themes. Thus, custom themes set the colours of the CLI and of `mt tui`. To select a custom theme, set `MALT_THEME=<name>`. To apply a theme when `MALT_THEME` is not set, put its name in the `default` field of the file. A built-in name always has priority, so a custom theme cannot replace `dracula`.

<details>
<summary><b>File format</b>: an example theme, colour syntax, and validation</summary>

```json
{
  "version": 1,
  "default": "my-dark",
  "themes": {
    "my-dark": {
      "polarity": "dark",
      "accent": "#bd93f9",
      "secondary": [139, 233, 253],
      "success": "#50fa7b",
      "warning": "#ffb86c",
      "danger": "#ff5555",
      "muted": 240
    }
  }
}
```

Each theme needs a `polarity` (`dark` or `light`) and all six roles. A colour is one of these: a hex string (`"#rgb"` or `"#rrggbb"`), an `[r, g, b]` array (0–255), or one integer from 0 to 255 (a 256-colour index).

malt validates the full file as one unit. If one value is not valid, malt rejects the full file and keeps the built-in themes. It shows a one-line notice and does not crash. A custom theme has the same conditions as a built-in theme. It applies only when its polarity matches the background that malt finds. Also, the terminal must support the deepest colour of the theme. A hex or `[r,g,b]` colour needs truecolor (`COLORTERM=truecolor` or `24bit`). A 256-colour index needs a terminal with 256 colours or more (`COLORTERM`, or a `TERM` that contains `256color`). If the terminal cannot show a theme, malt uses the default palette for all colours.

</details>

## Interactive dashboard

`mt tui` opens a dashboard that stays open and adapts to the window size. From one screen, you can search, install, upgrade, control services, and run doctor. Each action runs `mt <subcommand>`. The dashboard needs no daemon and no additional install.

<p align="center">
  <img src="https://raw.githubusercontent.com/indaco/gh-assets/main/malt/tui-demo.gif" alt="mt tui - search, install, services, doctor" width="800">
</p>

```bash
mt tui                                   # launch the dashboard
MALT_THEME=dracula mt tui                # launch with a named theme
```

> [!NOTE]
> `mt tui` needs a real terminal. On a pipe, in CI, or when `NO_COLOR` is set, it does not start and exits with 2. Thus, it does not write escape sequences to an output that is not a TTY.

The dashboard has five tabs. Each tab shows live data from `mt … --json`:

| Tab       | Shows                                             | Acts via                         |
| --------- | ------------------------------------------------- | -------------------------------- |
| Search    | `mt search` hits, basket select across queries    | `mt install` the basket          |
| Installed | every keg + cask with a detail pane               | `mt uninstall`                   |
| Outdated  | upgradable packages, multi-select (pinned greyed) | `mt upgrade`                     |
| Services  | launchd services + runtime state                  | `mt services start/stop/restart` |
| Doctor    | structured `mt doctor` findings, errors first     | `mt doctor --fix <class>`        |

Use the mouse or the keyboard. Click a tab to open it. Click a row to select it. Use the wheel to scroll the active list. The footer of each tab shows its action keys.

- **Batch installs across searches.** `space` adds a result to a basket. The basket stays when you start a new query. `i` installs all packages in the basket, and `l` opens the basket for review. In the basket, `space` or `d` removes a package, and `n` removes all packages.
- **Reads with `--json`, runs the real commands.** Each action runs the real `mt <subcommand>` inline. Thus, output and prompts stay in your scrollback. The dashboard has no install, upgrade, or fix code of its own.
- **Live resize.** The columns adapt when you change the window size. If the window is too small, the dashboard shows a "terminal too small" notice instead of a damaged frame.

## Command reference

The commands are in groups by task. All commands work with `malt` or `mt`. `mt <command> --help` and `man malt` list all flags. [Global flags](#global-flags) lists the flags that many commands share: `--quiet`, `--dry-run` for commands that make changes, and `--json` where applicable.

Summary from `malt -h`:

```text
malt - Homebrew's whole ecosystem, none of its weight.
Reuses every formula, bottle, and Brewfile; runs post-install steps and Ruby post_install natively.
Themeable TUI and CLI.

Usage: malt <command> [options] [arguments]
       mt <command> [options] [arguments]    (alias)

Commands:
  install       Install formulas, casks, or tap formulas
  reinstall     Wipe and re-materialise an installed package
  uninstall     Remove installed packages
  upgrade       Upgrade installed packages
  update        Refresh metadata cache
  outdated      List packages whose installed version differs from the tap
  list          List installed packages
  info          Show detailed package information
  search        Search formulas and casks
  uses          Show installed packages that depend on a formula
  deps          Show what a formula depends on (forward of `uses`)
  which         Resolve a prefix binary (or path) to its keg
  vulns         Report open advisories for installed formulae
  doctor        System health check
  tap/untap     Manage taps
  migrate       Import existing Homebrew installation
  rollback      Revert a package to its previous version
  link          Create symlinks for an installed keg
  unlink        Remove symlinks (keg stays installed)
  pin           Protect an installed formula or cask from `upgrade`
  unpin         Lift the pin so `upgrade` resumes touching it
  run           Run a package binary without installing
  completions   Generate shell completion scripts (bash, zsh, fish)
  shellenv      Print PATH/MANPATH/HOMEBREW_PREFIX exports for shell init
  backup        Dump installed packages to a restorable text file
  restore       Reinstall every package listed in a backup file
  purge         Housekeeping or full wipe (--store-orphans, --unused-deps,
                --cache, --downloads, --stale-casks, --old-versions,
                --housekeeping, --wipe)
  cleanup       Shorthand for `purge --housekeeping`
  services      Manage long-running launchd services (start/stop/status/logs)
  tui           Interactive dashboard (search, installed, outdated, services, doctor)
  bundle        Install or export a Brewfile/Maltfile.json set of packages
  version       Show version (use 'version update' to self-update)
```

### Get and remove software

```bash
mt install wget                          # auto-detect formula or cask
mt install --cask firefox                # explicit cask
mt install user/tap/formula              # inline tap, no separate tap step
mt install openssl@3                     # versioned formula
mt install jq wget ripgrep               # parallel downloads, single lock
mt install --only-dependencies wget      # transitive deps only
mt install --force wget                  # overwrite an existing install
mt install --local ./hello.rb            # local formula (see Local formulas below)
mt install --dry-run jq                  # preview without installing

mt reinstall jq                          # re-materialise an installed formula or tap package
mt run jq -- --version                   # run a binary without installing
mt run --keep ripgrep -- --help          # ...and cache the bottle for next time

mt uninstall wget                        # refuses while other packages depend on it
mt uninstall --cask firefox              # --force skips the dependents check, never a running app
mt migrate --dry-run                     # preview importing an existing Homebrew install
```

- **Unverified recipes.** A tap or local recipe with `sha256 :no_check` installs only with `--allow-unpinned`. The flag also applies to dependencies, and malt shows a warning for each one. `mt restore` and `mt bundle` never use this flag.
- **`--use-system-ruby` applies to one formula at a time.** Thus, one failed `post_install` cannot make the sandbox wider for a full batch. For one package, use the flag without a value (`mt install jq --use-system-ruby`). For more packages, name each one (`--use-system-ruby=jq`). `mt migrate` does not accept the flag without a value.
- **Uninstall is all-or-nothing.** malt checks all names first. If one name is not installed, malt stops the run. malt does not remove a cask while its application runs, also with `--force`. If a name is installed as a formula and as a cask, malt removes the formula and shows a warning (as `brew` does). If malt cannot read the casks or kegs table, it stops the run. To continue, use `--formula` or `--cask` to select the side. Store entries stay until you run `mt purge --store-orphans`.
- **`mt migrate`** installs each Homebrew keg again through malt and does not change Homebrew. If malt cannot run the `post_install` of a keg, malt skips the keg and reports it. `--parallel` runs 4 workers by default (`MALT_MIGRATE_PARALLEL_WORKERS`). If a run stops before completion, the next run continues from that point.

#### Local formulas: the trust boundary

`mt install --local ./formula.rb` can execute code. The `.rb` file sets the archive URL and the SHA256 of the files that malt installs. Thus, when you install it, you trust that file. Use it for your own formulas, for in-house formulas, or to try upstream changes before they are in a tap. Do not use it for a `.rb` file that you did not read.

- **Visible.** On each install, malt prints the canonical realpath. If the `.rb` is world-writable or another user owns it, malt also prints a ⚠ line.
- **Detection.** malt treats a `.rb` path as local if it starts with `./`, `/`, or `~/`, or if it contains a slash. A bare name such as `wget.rb` needs `--local`.
- **Strict inputs.** The archive URL must use `https://`. malt rejects `http`, `file://`, `ftp://`, and `data:` before it downloads. It compares the SHA256 in constant time. It rejects a path, file name, or `version` that contains a control character.
- **Refused combinations.** malt does not accept `--local` with `--cask`, `--formula`, or `--use-system-ruby`.
- **No upstream.** `mt upgrade` and `mt outdated` skip a local keg. To update it, run `mt install --local <path>` again.

<details>
<summary><b>What a local <code>.rb</code> can contain</b>: supported fields, service blocks, and an example</summary>

For local installs, malt reads these fields:

- The bottle-style `version` + `url` + `sha256` triple. It can be under `on_macos`, `on_arm`, or `on_intel`.
- The per-arch `arch` and `sha256 arm:, intel:` of a cask, at top level or under `on_macos`.
- The runtime `depends_on` names.
- A `service do` block. Its `run` uses keg-relative paths (`opt_bin/"x"`, `var/"..."`, `Formula["dep"].opt_bin/"x"`) or plain strings. A string can interpolate these values of the same formula: `opt_bin`, `opt_sbin`, `opt_libexec`, `opt_prefix`, `bin`, `sbin`, `libexec`, `prefix`, `var`, `etc`, or `HOMEBREW_PREFIX`. Thus, `"--config=#{etc}/x.conf"` is correct, but `#{Formula["dep"].opt_bin}` is not. If malt cannot translate a block, it skips the block and shows a warning.

Some blocks only name a plist that the formula installs (`name macos: "..."`). malt reads that plist from `<label>.plist` in the keg and makes a malt service from it. malt does not relocate the text in tap and local archives, so the plist must already contain the malt prefix. If the plist uses a launchd key that malt does not support, malt skips the plist and shows a warning with the key name. Keg-relative roots (`bin/"x"`, `libexec/"x"`) attach the plist to the Cellar path of the installed version. If the service must continue to work after `mt rollback`, use `opt_bin/"x"`. If you installed a keg before malt recognised its service, the next `mt install --force` or `mt upgrade` adds the service.

malt does not evaluate `post_install` for local installs. If you need it, publish the formula to a tap and install it with `mt install user/tap/formula`. malt skips all content in `on_linux`, in a macOS-release block (`on_ventura :or_newer`), and in an `if MacOS.version` branch. If a package declares its download only there, malt refuses the package and does not guess. malt also refuses a `url` that uses an interpolation other than `#{version}` and `#{arch}`.

The supported archive formats are `.tar.gz`, `.tgz`, `.tar.xz`, and `.zip`. The formula name comes from the basename of the file: `hello.rb` installs `hello`. This is a minimal compatible `.rb`:

```ruby
class Hello < Formula
  version "1.2.3"
  on_macos do
    on_arm do
      url "https://example.com/hello-#{version}-arm64.tar.gz"
      sha256 "aaaa…"   # 64 hex chars
    end
    on_intel do
      url "https://example.com/hello-#{version}-x86_64.tar.gz"
      sha256 "bbbb…"
    end
  end
end
```

For single-arch archives, a flat `url` and `sha256` at the top level is sufficient. For an example that you can run, refer to `scripts/fixtures/local_formulae/hello.rb`.

</details>

### Stay current

The upgrade cycle uses three commands:

```bash
mt update                                # refresh API cache + drop outdated snapshot
mt update --check                        # write a fresh outdated snapshot only

mt outdated                              # installed version differs from the tap
mt outdated --pinned-only                # CVE watch on held-back versions
mt outdated --refresh                    # bypass the cached snapshot

mt upgrade <name>                        # upgrade a specific formula or cask
mt upgrade --formula                     # all outdated formulas
mt upgrade --cask                        # all outdated casks
mt upgrade --pinned --dry-run            # audit pinned drift without mutating
mt upgrade --force <name>                # bypass a pin for one upgrade
mt upgrade --allow-unpinned <name>       # upgrade a sha256 :no_check tap package
```

- **Unverified tap packages.** Without `--allow-unpinned`, a bulk `mt upgrade` skips a tap package with `sha256 :no_check`. If you name the package, the upgrade fails.
- **`mt outdated`** reads a cached snapshot and filters it through the live DB. Thus, a removed keg or a keg that you upgraded manually never shows. The snapshot TTL is 5 min. To change it, set `MALT_OUTDATED_MAX_AGE=<minutes>`. With `0`, malt always calculates a new snapshot.
- **`mt upgrade`** installs and verifies the new version, then changes the symlinks atomically. It removes the old version only after a successful upgrade. If the upgrade fails, malt restores the old version.
- **`mt pin` / `mt unpin`** keep a package at its version. `mt upgrade` skips a pinned package and shows a "pinned, skipped" line. A formula and a cask with the same name have separate pins. A bare name selects the formula and shows a warning (as `brew` does).
- **`mt rollback <package>`** goes back to the previous version. If a name is installed as a formula and as a cask, malt rolls back the formula and shows a warning. To select the side, use `--cask` or `--formula`. A formula comes back from the store without a new download. A cask downloads again if its cached artefact is not available. `--list` shows the kept versions, and `--to <version>` selects one.

### Inspect what's installed

```bash
mt list                                  # columns on a terminal, bare names when piped
mt list -v                               # one per line, with [pinned]
mt list --versions --formula             # narrow + show versions
mt list --pinned                         # held-back versions only
mt list --json

mt info wget                             # version, tap, cellar path, pinned status
mt info --cask firefox                   # a bare name installed as both kinds shows the formula, with a warning

mt search ripgrep                        # brew-parity: queries the Homebrew API
mt search ripgrep --formula              # narrow
mt search ripgrep --installed            # local DB only; no network
mt search ripgrep --all                  # local + API, merged

mt uses openssl@3                        # direct dependents
mt uses --recursive openssl@3            # full transitive closure
mt deps ffmpeg                           # direct deps (forward of `uses`)
mt deps --recursive ffmpeg               # full forward closure
mt deps --installed -r node@20           # restrict to locally-resolved kegs
mt which jq                              # reverse lookup: bin -> keg-path

mt vulns                                 # open advisories for every installed formula
mt vulns --severity high                 # high and critical only
mt vulns abcde curl                      # only these formulae; exits 1 when anything is open, 2 if some could not be checked
mt vulns --json
```

- **`mt which`** accepts a bare name or the path of a symlink that malt manages. It prints `<name> <version> <keg-path>`. It does not make changes and does not use the network. For a binary that malt does not own, it exits with a non-zero code.
- **`mt search`** works as `brew search` by default and queries the Homebrew API. `--installed` searches the local DB without the network. `--all` merges the two results. `--offline` (or `MALT_OFFLINE=1`) changes all scopes to `--installed`.
- **`mt deps`** answers "_what does X depend on?_". It is the reverse of `mt uses`. malt reads installed kegs from the local DB and other kegs from the API. With `--installed`, it does not use the network.

### Maintain malt

`mt doctor` runs a set of health checks. It exits with 0 (OK), 1 (warnings), or 2 (errors).

```bash
mt doctor
mt doctor --fix                          # repair safe-class warnings
mt doctor --fix --dry-run                # preview the repair plan
mt doctor --post-install-status          # which post-install work runs natively, per keg
```

<details>
<summary><b>All doctor checks</b>: the pass condition and the meaning of each failure</summary>

| Check               | Pass                                          | Fail                                     |
| ------------------- | --------------------------------------------- | ---------------------------------------- |
| Database schema     | Schema version is one this malt can operate   | Error: written by a newer malt, upgrade  |
| SQLite integrity    | `PRAGMA integrity_check` returns `ok`         | Error: database corrupt                  |
| Directory structure | All required directories exist under prefix   | Warn: missing directory                  |
| Stale lock          | No lock file, or lock PID is running          | Warn: suggest removal                    |
| APFS volume         | `/opt/malt` is on APFS                        | Warn: clonefile unavailable              |
| API reachable       | HEAD to `formulae.brew.sh` returns 2xx        | Warn: offline                            |
| Orphaned store      | All store entries referenced by a keg         | Warn: suggest `mt purge --store-orphans` |
| Missing kegs        | All DB keg paths exist on disk                | Error: suggest reinstall                 |
| Cellar package dirs | No `Cellar/<name>` is a symlink               | Warn: installs there are refused         |
| Broken symlinks     | All symlinks in bin/, lib/ etc. resolve       | Warn: suggest `mt cleanup`               |
| Newer-macOS bottles | Every core keg's bottle loads on this macOS   | Warn: suggest `mt reinstall`/`uninstall` |
| Disk space          | > 1 GB free on prefix volume                  | Warn: low disk space                     |
| Post-install DSL    | All installed post_install formulae parseable | Warn: unsupported construct              |

</details>

`--fix` repairs only the **safe** classes. A safe repair is reversible and does not change user data. The safe classes are stale advisory locks (the recorded PID is dead), broken symlinks under `bin/`, `lib/`, `include/`, `share/`, and `sbin/`, and orphaned store entries. For dangerous classes, malt shows only a manual repair hint. These classes are a corrupt DB, missing kegs, missing prefix directories, weak permissions, and unpatched relocation placeholders.

Use `mt purge` for housekeeping or for a full wipe. You must give a scope flag.

```bash
# Safe scopes
mt purge --store-orphans
mt purge --unused-deps
mt purge --cache=30
mt purge --stale-casks
mt purge --housekeeping

# Destructive
mt purge --downloads
mt purge --old-versions
mt purge --wipe
mt purge --wipe --backup ~/snapshot.txt --remove-binary --yes
```

| Scope               | Removes                                                                   | Confirm gate        |
| ------------------- | ------------------------------------------------------------------------- | ------------------- |
| `--store-orphans`   | Store blobs no installed keg references                                   | none                |
| `--unused-deps`     | Indirect-install kegs no other package needs                              | none                |
| `--cache[=DAYS]`    | Cache files older than DAYS (default 30)                                  | none                |
| `--downloads`       | Entire `{cache}/downloads` directory                                      | type `downloads`    |
| `--stale-casks`     | Cask cache + Caskroom entries for uninstalled casks                       | none                |
| `--old-versions`    | Non-latest version directories in `{prefix}/Cellar`                       | type `old-versions` |
| `--broken-symlinks` | Prefix symlinks whose target no longer exists                             | none                |
| `--housekeeping`    | = `--store-orphans --unused-deps --cache --stale-casks --broken-symlinks` | none                |
| `--wipe`            | Every malt artefact on disk except `{prefix}/var` (mutually exclusive)    | type `purge`        |

- **Before you delete.** `--dry-run` (`-n`) shows a preview. `--yes` (`-y`) skips the typed confirmation. `--backup <path>` first writes a manifest that `mt restore` can read. Only `--wipe` accepts `--keep-cache` and `--remove-binary`.
- **Scripts.** `--json` prints one summary object. `--output-format=ndjson` streams events, one per line. The output on stderr stays human-readable. If a scope cannot run, the command exits with 1. If a newer malt wrote the database, it exits with 4. Thus, a script can tell a refusal from a run with nothing to remove.
- **Scopes.** You cannot use `--wipe` with other scopes. The other scopes can run together under one lock. `mt purge` obeys `MALT_PREFIX` and `MALT_CACHE`. To try it safely, use a temporary prefix.
- **`mt cleanup`** is the Homebrew-style alias for `mt purge --housekeeping`. It passes trailing flags through (`mt cleanup --dry-run`).
- **`mt link` / `mt unlink`** manage the prefix symlinks of a keg. If there is a conflict, `link` stops, unless you use `--overwrite` or `--force`. `unlink` does not remove the keg.

### Background services

`mt services` is a drop-in replacement for `brew services`:

```bash
mt services list                         # registered services + runtime state
mt services start postgresql@16          # launchctl bootstrap into gui/<uid>
mt services stop postgresql@16
mt services restart postgresql@16
mt services status postgresql@16
mt services logs postgresql@16 --tail 50
mt services logs postgresql@16 --stderr
mt services logs postgresql@16 -f        # tail and follow until SIGINT
```

- **Registration.** malt registers the `service` block of a formula during the install (for example, `postgresql@16` or `redis`). This also applies to tap and `--local` formulas. Some blocks only name the plist of the formula. malt reads that plist from `<label>.plist` in the keg if its paths already point to the malt prefix. The plist, the logs, and the service definition are in `{prefix}/var/malt/services/<label>/`.
- **Upgrades.** `mt upgrade` renders the plist again, but `mt rollback` does not. A running service keeps the old definition until you run `mt services restart <name>`. If a new version has no `service` block, malt removes the registration. `mt reinstall <name>` restores it, but `mt rollback` does not. `mt uninstall` also removes the registration, and `mt cleanup` removes it with an unused dependency. But a job that is still loaded keeps its registration, so `mt services stop` can stop it.
- **Environment.** A service gets the `environment_variables` of its formula, and `$HOMEBREW_PREFIX` changes to the malt prefix. Some formulas set `HOME` or a data directory (for example, `caddy` or `ejabberd`). After malt renders their plist again, they can start with an empty data directory. To apply the environment to a keg that is already on the current version, run `mt reinstall <name>`, then `mt services restart <name>`. Tap and `--local` formulas do not read `environment_variables` yet. For these formulas, malt shows a warning and registers the service without the variables.
- **Your overrides.** Put your settings in `~/.config/malt/services/<formula>.env` (or `$XDG_CONFIG_HOME/malt/services/<formula>.env`). Use the formula name, not the launchd label. Write one `KEY=VALUE` per line. A `#` starts a comment. malt does no quoting or expansion. Each time malt writes the plist, it merges these values over the formula environment. Thus, an edit applies at the next `mt services restart <formula>`. malt refuses `PATH`, `HOME`, and `DYLD_*`.
- **Override file checks.** The file must be a regular file that you own and that no other user can write. If it is not, or if a line is not valid, malt ignores the full file and shows a warning. On start or restart, the plist then stays the same. On install, upgrade, or reinstall, malt registers the service with only the formula environment. If an older malt registered the service, run `mt reinstall <formula>` one time to read the file.

### Reproducible setups

`mt bundle` is a drop-in replacement for `brew bundle`. It needs no Brewfile conversion:

```bash
mt bundle install                        # ./Brewfile or ./Maltfile.json
mt bundle install path/to/Brewfile
mt bundle install --file path/to/Brewfile # brew bundle's spelling, same as above
mt bundle install --dry-run
mt bundle cleanup                        # remove direct packages absent from Brewfile
mt bundle cleanup --yes                  # skip the typed confirmation
mt bundle create                         # snapshot installed -> ./Brewfile
mt bundle create --format json my.json
mt bundle export                         # print to stdout
mt bundle list                           # registered bundles
mt bundle remove devtools                # unregister; --purge also uninstalls
mt bundle import path/to/Brewfile        # register without installing
```

- **Lookup order.** If you do not give a path, `install` and `cleanup` look for these files in this order: `./Brewfile` → `./Maltfile.json` → `~/.config/malt/Brewfile` → `~/.config/malt/Maltfile.json`.
- **Unknown flags are refused.** malt exits with 1 and does not ignore the flag. Thus, a typo such as `--dryrun` cannot start a real cleanup.
- **Brewfile syntax.** malt reads `tap`, `brew`, `cask`, `mas`, and `vscode` lines, hash options (`version:`, `restart_service:`, `link:`), and Ruby symbols. malt refuses conditionals and `do … end` blocks, and tells you to use `Maltfile.json`.
- **Bundle names.** `install` and `import` register a bundle by the `name` in its Maltfile.json. If there is no name (as in all Brewfiles), they use the absolute path of the file, which `list` shows. `remove` and `export` accept any path to that file. `remove --purge` uninstalls the members recorded at the last `install` or `import`, not the packages that the file lists now. If a bundle has no recorded members (an older malt only imported it), malt refuses `--purge` until you import its file again. For an unknown name, the command exits with 1. If an older malt registered a bundle as `unnamed` or by a relative path, the bundle keeps that name. To fix it, run `mt bundle remove <name>`, then import the file again.
- **Local recipes** have no Brewfile line. `create` and `export` skip them and show a rebuild hint. `cleanup` and `remove --purge` do not remove them. `cleanup` also keeps all packages that a remaining package depends on.

`mt backup` and `mt restore` are for a simpler case. They use a plain-text manifest of the packages that you installed directly. You can edit this file manually or keep it in your dotfiles:

```bash
mt backup                                # writes malt-backup-<timestamp>.txt to cwd
mt backup -o my-setup.txt                # custom path; "-o -" writes to stdout
mt backup --versions                     # record each entry's installed version

mt restore my-setup.txt
mt restore my-setup.txt --dry-run
mt restore my-setup.txt --force
```

The manifest records only the packages that you installed directly. Each line is `formula <name>` or `cask <token>`, and tap packages use `<user>/<repo>/<name>`. A `#` starts a comment. Restore resolves the dependencies. A recorded version is for information only: restore installs the current release. A `--local` keg stays in the file as a comment, and restore prints the command to build it again. If a line is not valid, restore skips it and shows a warning. Restore installs the other lines, then exits with a non-zero code (a dry run exits with 0).

### Custom sources

```bash
mt tap user/repo                                  # register a tap
mt tap                                            # list registered taps
mt tap user/repo --repo owner/exact-repo          # prefixless GitHub repo
mt tap user/repo --repo owner/exact-repo --force  # rebind to a new repo
mt untap user/repo                                # remove a tap (refuses while its packages are installed)
mt untap --force user/repo                        # remove it anyway, keeping its packages
```

The install resolves taps automatically (`mt install user/repo/formula`). Thus, `mt tap` is optional. Use it if you want the explicit Homebrew-style workflow.

#### Supported forges

GitHub is the default. For other forges, use `--host` and an explicit `--repo`, because the `homebrew-<repo>` convention applies only to GitHub. Or use one `--url https://<host>/<owner>/<repo>`. `--url` works for all forges, but you cannot use it with `--host` or `--repo`.

| Forge                      | Hosts                                     | Token env var       |
| -------------------------- | ----------------------------------------- | ------------------- |
| GitHub                     | `github.com`                              | `MALT_GITHUB_TOKEN` |
| GitLab (incl. self-hosted) | `gitlab.com`, `gitlab.gnome.org`, custom  | `MALT_GITLAB_TOKEN` |
| Codeberg / Forgejo / Gitea | `codeberg.org`, self-hosted Forgejo/Gitea | `MALT_GITEA_TOKEN`  |
| Gogs                       | self-hosted Gogs                          | `MALT_GITEA_TOKEN`  |

malt finds the forge from the host only for `gitlab.*` and `codeberg.org`. All other hosts need `--forge` (`gitlab`, `gitea`, or `gogs`), with `--host` or with `--url`. Gogs always needs `--forge`. It uses the Gitea API and `MALT_GITEA_TOKEN`, but its pin endpoint is different. For how malt sends each token, refer to [environment variables](#environment-variables).

<details>
<summary><b>Registration examples for all forges</b>: <code>--host</code> + <code>--repo</code> and <code>--url</code></summary>

```bash
# Each forge takes the --host + --repo pair or the equivalent --url.

# GitHub (default)
mt tap user/repo --repo owner/exact-repo
mt tap user/repo --url https://github.com/owner/exact-repo

# GitLab (gitlab.* auto-classifies from the host)
mt tap grp/tap --host gitlab.com --repo grp/homebrew-tap
mt tap grp/tap --url https://gitlab.com/grp/homebrew-tap

# Self-hosted GitLab (host can't classify - name the forge)
mt tap acme/tap --host code.acme.com --forge gitlab --repo acme/tap
mt tap acme/tap --url https://code.acme.com/acme/tap --forge gitlab

# Codeberg / Forgejo / Gitea (codeberg.org auto-classifies)
mt tap org/tap --host codeberg.org --repo org/homebrew-tap
mt tap org/tap --url https://codeberg.org/org/homebrew-tap

# Self-hosted Forgejo/Gitea (host can't classify - name the forge)
mt tap org/tap --host git.acme.com --forge gitea --repo org/tap
mt tap org/tap --url https://git.acme.com/org/tap --forge gitea

# Gogs (never auto-classifies - always name the forge)
mt tap org/tap --host git.acme.com --forge gogs --repo org/tap
mt tap org/tap --url https://git.acme.com/org/tap --forge gogs
```

</details>

A tap that is not on GitHub registers without a pin. `mt tap --refresh <slug>` pins its current HEAD. `mt doctor` lists each registered tap and its forge host. Use it to make sure that a `--host` registration uses the correct host.

#### Pinning caveat: prefer release assets over generated archives

The forge server can generate GitLab `/-/archive/` and Gitea/Gogs `/archive/` tarballs again. Thus, a pinned `sha256` can stop matching, also when the contents did not change. Pin a **release-asset** URL instead. A `Sha256Mismatch` on a generated-archive URL usually means that the forge generated the tarball again. It does not usually mean that the download is corrupt.

### Manage malt

```bash
mt version                               # show current version
mt version update                        # interactive self-update
mt version update --check                # check only, no download
mt version update --yes                  # non-interactive (CI / scripts)
mt version update --cleanup              # remove stale .old + orphaned staging files

eval "$(mt shellenv)"                    # PATH/MANPATH; auto-detect from $SHELL
mt shellenv fish | source                # fish needs `set -gx`

eval "$(malt completions zsh)"           # run AFTER `compinit`
malt completions bash > /usr/local/etc/bash_completion.d/malt
malt completions fish > ~/.config/fish/completions/malt.fish
```

`mt version update` verifies the release with cosign and SHA256, against the same trust anchor as `install.sh`. Then it replaces the binary atomically and keeps the previous binary at `<target>.old`. `--cleanup` removes these files and the orphaned staging files from stopped updates. It does not use the network. If Homebrew installed malt, the command tells you to use `brew upgrade --cask malt`.

To skip cosign, `install.sh` accepts `MALT_ALLOW_UNVERIFIED=1` (strongly discouraged). `mt version update` needs the env var **and** `--no-verify`, because you run the update command many times:

```bash
MALT_ALLOW_UNVERIFIED=1 mt version update --no-verify
```

`mt shellenv` exports `HOMEBREW_PREFIX`, `HOMEBREW_CELLAR`, and `HOMEBREW_REPOSITORY`. Thus, scripts that use these brew variables continue to work. It also adds the malt paths to the start of `PATH`, `MANPATH`, and `INFOPATH`. Without an argument, it finds the shell from `$SHELL`. If it does not recognise the shell, it fails closed.

`mt completions` prints a `bash`, `zsh`, or `fish` completion script to stdout. The script includes subcommands, per-command flags, and global flags. For an unknown shell, the command exits with a non-zero code.

### Global flags

| Flag                     | Description                                                                                                      |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| `--verbose`, `-v`        | Verbose output                                                                                                   |
| `--debug`                | Surface every DSL diagnostic (implies verbose); pair with issue reports                                          |
| `--quiet`, `-q`          | Suppress non-error output                                                                                        |
| `--json`                 | JSON output (read commands; also emits per-package `post_install` status lines)                                  |
| `--output-format=ndjson` | Stream one JSON event per state transition (stdout); human output stays on stderr                                |
| `--dry-run`              | Preview without executing                                                                                        |
| `--offline`              | Serve every fetch from the snapshot cache; fail fast with `OfflineRequired` on a miss (mirrors `MALT_OFFLINE=1`) |
| `--help`, `-h`           | Show help                                                                                                        |
| `--version`              | Show version                                                                                                     |

### Environment variables

| Variable                           | Description                                                                                                                                                                          | Default                         |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------- |
| `MALT_PREFIX`                      | Override install prefix                                                                                                                                                              | `/opt/malt`                     |
| `MALT_CACHE`                       | Override cache directory                                                                                                                                                             | `{prefix}/cache`                |
| `MALT_APPDIR`                      | Where cask `app` bundles land and what the `appdir` base of a cask's flight steps resolves to (brew's `--appdir`); absolute canonical path (no `..`, `//`), anything else is ignored | `/Applications`                 |
| `MALT_BREW_PATH`                   | Override the real `brew` binary that unknown commands fall back to (custom install prefix)                                                                                           | probes standard install paths   |
| `NO_COLOR`                         | Disable colored output. Unconditional veto: it wins over `CLICOLOR_FORCE`                                                                                                            | unset                           |
| `CLICOLOR`                         | Set to `0` to disable colored output                                                                                                                                                 | unset                           |
| `CLICOLOR_FORCE`                   | Set to a non-empty value other than `0` to emit colored output even when stderr is not a terminal (piping into `less -R`, ANSI in CI logs)                                           | unset                           |
| `MALT_NO_EMOJI`                    | Disable emoji in output                                                                                                                                                              | unset                           |
| `MALT_NO_VERSION_NOTIFIER`         | Set to `1` to suppress the "newer malt available" notice                                                                                                                             | unset                           |
| `MALT_VERSION_NOTIFIER_ASSUME_TTY` | Testing/automation: set to `1` to bypass the non-TTY suppression so a scripted run can assert the notice without a pty (bypasses only the TTY gate)                                  | unset                           |
| `MALT_PROGRESS`                    | Progress reporter for `install`/`upgrade`/`migrate`: `tty`, `plain`, or `none` (`CI=true` or `GITHUB_ACTIONS=true` flip the default to `plain`)                                      | `tty`                           |
| `MALT_THEME`                       | Colour theme for all output (CLI and `mt tui`). See [Theming](#theming) for the palette list and fallback rules.                                                                     | `auto`                          |
| `XDG_CONFIG_HOME`                  | Base directory for per-service environment overrides only (`$XDG_CONFIG_HOME/malt/services/<formula>.env`); ignored unless absolute                                                  | `~/.config`                     |
| `MALT_THEMES_FILE`                 | Path to a JSON file of custom themes (see "Custom themes"); read once at boot, else `{prefix}/etc/malt/themes.json` is used if present                                               | `{prefix}/etc/malt/themes.json` |
| `HOMEBREW_GITHUB_API_TOKEN`        | GitHub token for higher API rate limits                                                                                                                                              | unset                           |
| `MALT_GITHUB_TOKEN`                | GitHub token sent as `Authorization: Bearer` on tap `/commits/HEAD` calls only                                                                                                       | unset                           |
| `MALT_GITLAB_TOKEN`                | GitLab token (PAT) sent as `PRIVATE-TOKEN` on tap commit + raw `.rb` calls for GitLab-hosted taps                                                                                    | unset                           |
| `MALT_GITEA_TOKEN`                 | Codeberg/Forgejo (Gitea) token sent as `Authorization: token` on tap commit + raw `.rb` calls; covers Codeberg and self-hosted Forgejo/Gitea                                         | unset                           |
| `MALT_HTTP_IDLE_TIMEOUT_SECS`      | HTTP idle (no-progress) read timeout in seconds (clamped to `[5, 600]`)                                                                                                              | `30`                            |
| `HTTP(S)_PROXY`, `ALL_PROXY`       | Route every fetch through an HTTP `CONNECT` proxy (`[http://][user:pass@]host:port`, lower-case names work). `NO_PROXY` is not read; `socks5://` ignored                             | unset                           |
| `MALT_API_DOMAIN`                  | Override metadata API base URL; HTTPS only; falls back to `HOMEBREW_API_DOMAIN`                                                                                                      | `https://formulae.brew.sh/api`  |
| `MALT_BOTTLE_DOMAIN`               | Override bottle registry base URL; HTTPS only; falls back to `HOMEBREW_BOTTLE_DOMAIN`                                                                                                | `https://ghcr.io`               |
| `MALT_OFFLINE`                     | Set to `1`/`true` to route every fetch through the snapshot cache; misses surface `OfflineRequired` instead of stalling on connect (mirrors `--offline`)                             | unset                           |
| `MALT_MIGRATE_PARALLEL_WORKERS`    | Worker count for `mt migrate --parallel` (clamped to `[1, 32]`)                                                                                                                      | `4`                             |
| `MALT_OUTDATED_MAX_AGE`            | TTL in minutes for the `outdated.json` snapshot                                                                                                                                      | `5`                             |
| `MALT_ALLOW_RAW_POST_INSTALL`      | Disable the terminal escape filter on `post_install` output, on both the native and ruby paths (children then keep a TTY)                                                            | unset                           |
| `MALT_ALLOW_UNVERIFIED`            | Skip signature + checksum verification - in `install.sh`, and in `mt version update --no-verify` (use only when cosign is unavailable)                                               | unset                           |
| `MALT_ALLOW_UNVERIFIED_SOURCE`     | Allow `install.sh` to clone `main` when no release tag resolves                                                                                                                      | unset                           |

## Safety and security

malt verifies the SHA256 of each download before extraction. It installs atomically, and each release has a cosign signature. For the full safety and supply-chain model, refer to [ARCHITECTURE.md](ARCHITECTURE.md#safety-and-security).

## Benchmarks

<!-- BENCH:META:START -->
- Install times on macOS 26 (Apple Silicon).
- Benchmarked releases:
  - malt `0.25.0`
  - nanobrew `v0.1.213`
  - zerobrew `v0.3.5`
<!-- BENCH:META:END -->

<!-- BENCH:COLD:START -->
### Cold Install (median ±σ)

| Package | malt | nanobrew | zerobrew | Homebrew |
| ------- | ---- | -------- | -------- | -------- |
| **tree** (0 deps) | 0.347±0.018s | 0.438±0.283s | 1.000±0.083s | 1.483±0.503s |
| **wget** (7 deps) | 3.527±0.762s | 9.107±1.270s | 7.824±2.962s | 22.378±3.747s |
| **ffmpeg** (14 deps) | 4.515±0.815s | 8.441±1.052s | 11.221±1.075s | 19.218±1.048s |
| **openjdk** (29 deps) | 18.240±1.807s | 29.129±3.795s | 34.277±7.731s | 23.124±3.621s |
| **tesseract** (37 deps) | 12.078±1.300s | 22.073±4.210s | 32.432±1.069s | 23.078±2.029s |
<!-- BENCH:COLD:END -->

<!-- BENCH:WARM:START -->
### Warm Install

| Package | malt | nanobrew | zerobrew |
| ------- | ---- | -------- | -------- |
| **tree** (0 deps) | 0.016s | 0.074s | 0.400s |
| **wget** (7 deps) | 0.026s | 0.693s | 2.565s |
| **ffmpeg** (14 deps) | 0.031s | 3.898s | 5.290s |
| **openjdk** (29 deps) | 0.026s | 6.974s | 5.998s |
| **tesseract** (37 deps) | 0.021s | 1.303s | 4.591s |
<!-- BENCH:WARM:END -->

> Apple Silicon (GitHub Actions macos-26), 2026-10-06. Auto-updated weekly via the [benchmark workflow](.github/workflows/benchmark.yml).

Binary sizes and the methodology are in [BENCHMARKS.md](BENCHMARKS.md).

## Contributing

Contributions are welcome. Before you submit a large change, open an issue to discuss it. Refer to [CONTRIBUTING](CONTRIBUTING.md).

## Security

If you find a vulnerability, report it privately. Do not open a public issue. Refer to [SECURITY](.github/SECURITY.md).

## License

malt uses the [MIT License](LICENSE). The [LICENSE](LICENSE) file acknowledges third-party components and upstream projects, for example Homebrew (BSD-2-Clause) and homebrew-core (BSD-2-Clause).
