//! malt — per-command help text
//! Returns help text for each subcommand, displayed on -h / --help.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;

/// Check if args contain -h or --help. If so, print help to stdout (so the
/// output is pipeable — `malt install --help | less`) and return true.
pub fn showIfRequested(ctx: *const AppCtx, args: []const []const u8, command: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            ctx.stdout.writeStreamingAll(ctx.io, helpFor(command)) catch {};
            return true;
        }
    }
    return false;
}

/// Return the help text for a given command, or a generic fallback. Exposed
/// so tests can assert content without spawning the binary.
pub fn helpFor(command: []const u8) []const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "install", install_help },
        .{ "reinstall", reinstall_help },
        .{ "uninstall", uninstall_help },
        .{ "upgrade", upgrade_help },
        .{ "update", update_help },
        .{ "outdated", outdated_help },
        .{ "list", list_help },
        .{ "info", info_help },
        .{ "search", search_help },
        .{ "doctor", doctor_help },
        .{ "tap", tap_help },
        .{ "migrate", migrate_help },
        .{ "rollback", rollback_help },
        .{ "run", run_help },
        .{ "link", link_help },
        .{ "unlink", unlink_help2 },
        .{ "completions", completions_help },
        .{ "shellenv", shellenv_help },
        .{ "backup", backup_help },
        .{ "restore", restore_help },
        .{ "purge", purge_help },
        .{ "cleanup", cleanup_help },
        .{ "uses", uses_help },
        .{ "deps", deps_help },
        .{ "which", which_help },
        .{ "pin", pin_help },
        .{ "unpin", unpin_help },
    });
    return map.get(command) orelse "No help available.\n";
}

const install_help =
    \\Usage: malt install <package> [<package> ...] [flags]
    \\
    \\Install formulas, casks, or tap formulas.
    \\
    \\  malt install <name>                    auto-detect formula or cask
    \\  malt install <name>@<version>          specific version
    \\  malt install --cask <app>              explicit cask
    \\  malt install --formula <name>          explicit formula
    \\  malt install <user>/<tap>/<formula>    inline tap
    \\  malt install --local <path.rb>         install from a local Ruby formula
    \\
    \\Flags:
    \\  --cask             Force cask installation
    \\  --formula          Force formula installation
    \\  --local            Install from a local .rb file path (code-exec surface:
    \\                     only pass files you trust)
    \\  --dry-run          Show what would be installed
    \\  --force            Overwrite existing installations
    \\  --only-deps        Install transitive deps but skip the requested package
    \\                     (deps are recorded as `dependency` so `mt purge --unused-deps`
    \\                     can later GC them). `--only-dependencies` accepted for
    \\                     brew-parity.
    \\  --download-only    Warm the bottle store (formulas), the Cask cache (casks),
    \\                     or the tap archive cache (`<prefix>/cache/Tap/` for
    \\                     `user/repo/<formula>`) and stop before materialise/link/
    \\                     record. The Cellar, /Applications, and DB stay untouched;
    \\                     a follow-up `mt install` consumes the cached bytes.
    \\                     Refused with --only-deps.
    \\  --use-system-ruby[=<name>,...]  Run post_install via the system Ruby interpreter
    \\                     (experimental, sandboxed). A bare flag requires a single
    \\                     package; use =<name>,... to scope when installing multiple.
    \\  --isolate-deps     Keep every transitive dep out of <prefix>/bin and
    \\                     <prefix>/sbin. The package(s) you named still link
    \\                     normally; deps land in the Cellar with their `opt/`
    \\                     anchor (Mach-O dependents stay resolvable) but their
    \\                     bin/sbin contents are skipped. The choice is recorded
    \\                     per-keg so a later `mt upgrade` replays it. Shell-
    \\                     based formulas that bare-name-exec their deps
    \\                     (e.g. `python` vs `/full/path/python`) may break;
    \\                     use `mt link <dep>` to undo per-keg.
    \\                     `--isolate-dependencies` accepted as an alias.
    \\  --quiet, -q        Suppress non-error output
    \\  --json             Output result as JSON
    \\
;

const reinstall_help =
    \\Usage: malt reinstall <package> [flags]
    \\
    \\Wipe and re-materialise an already-installed package through the
    \\shared install pipeline. The discoverable peer of `malt install
    \\--force`; lets you fix a corrupted Cellar entry or re-run the
    \\install protocol without retyping the --force flag.
    \\
    \\Reinstall is package-scoped — transitive dependencies are NOT
    \\reinstalled. To rebuild a dep, name it explicitly.
    \\
    \\Flags pass through to `install`; the common ones:
    \\  --cask               Force cask path (auto-detected from the DB row)
    \\  --dry-run            Show what would be reinstalled
    \\  --quiet, -q          Suppress non-error output
    \\  --json               JSON output (mirrors `mt install --json`)
    \\  --isolate-deps       New deps follow the flag; existing rows keep
    \\                       whatever isolation policy they were recorded with
    \\  --output-format=ndjson
    \\                       Stream one event per state transition
    \\
    \\Examples:
    \\  malt reinstall wget
    \\  malt reinstall --cask firefox
    \\
;

const uninstall_help =
    \\Usage: malt uninstall <package> [flags]
    \\
    \\Remove installed packages.
    \\
    \\Flags:
    \\  --force        Remove even if other packages depend on it
    \\  --zap          Deep clean (cask only)
    \\  --dry-run      Show what would be removed
    \\
;

const upgrade_help =
    \\Usage: malt upgrade [<package>] [flags]
    \\
    \\Upgrade installed packages to latest versions. Pinned kegs and
    \\casks are skipped with a "pinned, skipped" line; pass --force to
    \\override.
    \\
    \\Flags:
    \\  --all          Upgrade everything (formulas + casks)
    \\  --cask         Upgrade casks only
    \\  --formula      Upgrade formulas only
    \\  --dry-run      Show what would be upgraded
    \\  --pinned       Audit pinned formulas + casks (requires --dry-run or --force)
    \\  --force, -f    Bypass pin protection (dangerous; user-initiated)
    \\  --isolate-deps New deps pulled in by this upgrade keep their bins
    \\                 out of <prefix>/bin and <prefix>/sbin. Existing kegs
    \\                 replay whatever they were already recorded with.
    \\                 `--isolate-dependencies` accepted as an alias.
    \\
;

const update_help =
    \\Usage: malt update [flags]
    \\
    \\Refresh the local formula/cask metadata cache and the outdated snapshot.
    \\
    \\Flags:
    \\  --check     Refresh only the outdated snapshot (skip API cache wipe)
    \\  --quiet, -q Suppress status messages
    \\
;

const outdated_help =
    \\Usage: malt outdated [flags]
    \\
    \\List packages with newer versions available.
    \\
    \\Flags:
    \\  --json         Output as JSON
    \\  --formula      Show outdated formulas only
    \\  --cask         Show outdated casks only
    \\  --pinned-only  Audit pinned formulas + casks only (CVE watch)
    \\  --tap <label>  Only packages from <label> (e.g. `user/repo`).
    \\                 Strict equality: legacy v6-era casks with no
    \\                 recorded tap won't match. Forces a live recompute.
    \\  --refresh      Force live recompute, bypassing the cached snapshot
    \\  --quiet, -q    Suppress status messages
    \\
    \\Reads the cached snapshot at {cache}/outdated.json when fresh
    \\(<= MALT_OUTDATED_MAX_AGE hours, default 24); falls back to a live
    \\recompute on miss or --refresh.
    \\
;

const list_help =
    \\Usage: malt list [flags]
    \\
    \\List installed packages.
    \\
    \\Flags:
    \\  --versions     Show version numbers
    \\  --formula      Formulas only
    \\  --cask         Casks only
    \\  --pinned       Pinned packages only
    \\  --tap <label>  Only packages from <label> (e.g. `user/repo`).
    \\                 Strict equality: legacy v6-era casks with no
    \\                 recorded tap won't match — run `mt upgrade <token>`
    \\                 to trigger attribution, or omit the filter.
    \\  --json         Output as JSON
    \\  --quiet, -q    Names only, one per line
    \\
;

const info_help =
    \\Usage: malt info <package> [flags]
    \\
    \\Show detailed information about a formula or cask. If the package
    \\has retained rollback versions (multi-version store entries for
    \\formulas, cask_versions history for casks), they are listed under
    \\an "Available rollback versions" section so `mt rollback <pkg>`
    \\and `mt info <pkg>` agree on what's retrievable. The same listing
    \\is exposed in `--json` as the `available_rollback_versions` array.
    \\
    \\Flags:
    \\  --formula      Show formula info only
    \\  --cask         Show cask info only
    \\  --json         Output as JSON
    \\
;

const search_help =
    \\Usage: malt search <query> [flags]
    \\
    \\Search formulas and casks by name.
    \\
    \\Default scope: query the Homebrew API (same as `brew search`). Use
    \\--installed when you only want to know what's already on disk.
    \\
    \\Scope:
    \\  --installed    Query kegs.name + casks.token only. No network.
    \\  --api          Explicit form of the default (Homebrew API).
    \\  --all          Run both passes and merge results, deduped + sorted.
    \\  --offline      Alias of --installed (mirrors MALT_OFFLINE=1).
    \\
    \\Kind filter:
    \\  --formula      Search formulas only
    \\  --cask         Search casks only
    \\
    \\Output:
    \\  --json         Output as JSON
    \\
;

const doctor_help =
    \\Usage: malt doctor [--fix]
    \\
    \\Run system health checks: database integrity, orphaned store
    \\entries, broken symlinks, disk space, API reachability, and more.
    \\
    \\Trailing report:
    \\  Retained cask versions — for every cask token whose
    \\  `cask_versions` history has rows that are not the live
    \\  install, the count + on-disk bytes are summarised. Empty
    \\  state stays silent. Read-only: `mt purge --old-versions`
    \\  is what actually reclaims the space.
    \\
    \\Options:
    \\  --fix          Apply the safe-class fixers (stale lock,
    \\                 orphaned store entries, broken symlinks).
    \\                 Pair with --dry-run to preview the plan.
    \\                 Dangerous classes (corrupt DB, missing kegs)
    \\                 still print a manual remediation command.
    \\  --verbose      List every offender under the count-only
    \\                 checks (Mach-O placeholders, broken symlinks,
    \\                 missing kegs) on its own indented line, and
    \\                 include the per-(token version) breakdown
    \\                 under the retained-cask-versions summary.
    \\  --json         Emit the retained-cask-versions report as a
    \\                 stable `{cask_history: {retained_versions,
    \\                 bytes}}` payload on stdout. Empty state still
    \\                 surfaces with zero values.
    \\
;

const tap_help =
    \\Usage: malt tap [<user>/<repo>]
    \\       malt tap <user>/<repo> --repo <owner>/<exact-repo> [--force]
    \\       malt tap <slug> --host <forge-host> [--forge <provider>] --repo <owner>/<repo>
    \\       malt tap <slug> --url https://<host>/<owner>/<repo>
    \\       malt tap --refresh <user>/<repo>
    \\       malt tap --refresh --all [--yes] [--json]
    \\       malt tap --pin <user>/<repo> <sha>
    \\       malt untap <user>/<repo>
    \\
    \\Manage taps. Without arguments, lists registered taps + their
    \\pinned commit. `tap <slug>` resolves the repo's HEAD commit at
    \\that moment and stores it; subsequent installs from the tap fetch
    \\against the pin, not whatever HEAD happens to point to later.
    \\
    \\Flags:
    \\  --refresh [<slug>]   Advance the pin to the current HEAD. With a
    \\                       slug, refreshes that one tap; with --all,
    \\                       walks every registered tap.
    \\  --all                Pairs with --refresh: batch every tap, print
    \\                       a per-row `old_sha[..7] -> new_sha[..7]` diff,
    \\                       and refuse to apply without --yes when any
    \\                       tap moved.
    \\  --pin <slug> <sha>   Explicitly pin <slug> to <sha>. The SHA is
    \\                       validated for reachability through the tap's own
    \\                       forge's commits/<sha> endpoint before it lands.
    \\  --repo <owner>/<exact-repo>
    \\                       Point the tap at a GitHub repo whose name
    \\                       does NOT carry the `homebrew-` prefix
    \\                       (e.g. `mt tap aeroxy/ast-outline --repo
    \\                       aeroxy/ast-outline`). Without this flag the
    \\                       tap resolves against `homebrew-<repo>`.
    \\  --host <forge-host>  Register the tap against a non-GitHub forge
    \\                       (e.g. gitlab.com, gitlab.gnome.org). Requires an
    \\                       explicit --repo — the `homebrew-<repo>` default
    \\                       only applies to github.com. The tap registers
    \\                       unpinned; `mt tap --refresh <slug>` pins its HEAD.
    \\  --forge <provider>   Pin the forge explicitly (github, gitlab,
    \\                       gitea, or gogs) when the host can't reveal it
    \\                       — a custom-domain GitLab like code.acme.com or
    \\                       a self-hosted Forgejo/Gitea/Gogs. gitlab.* and
    \\                       codeberg.org auto-classify, so this is only
    \\                       needed for non-obvious domains.
    \\  --url <repo-url>     Derive (host, owner, repo) from a full
    \\                       `https://<host>/<owner>/<repo>` URL instead of
    \\                       naming --host and --repo separately.
    \\  --force              Allow rebinding an existing tap to a new
    \\                       --repo target. Clears the stale commit SHA
    \\                       and ETag because the new repo has its own HEAD.
    \\  --yes, -y            Confirm the apply step of --refresh --all.
    \\  --json               Emit the --refresh --all diff as
    \\                       `{"taps":[{"tap","old_sha","new_sha","status"}]}`.
    \\
    \\Taps are auto-resolved during install, so explicit `tap` is
    \\usually unnecessary — the auto-tap also pins the SHA on first use.
    \\
;

const migrate_help =
    \\Usage: malt migrate [flags]
    \\
    \\Import an existing Homebrew installation into malt.
    \\Does NOT modify the Homebrew installation.
    \\
    \\Flags:
    \\  --dry-run          Show what would be migrated
    \\  --parallel         Migrate kegs concurrently with a bounded worker pool
    \\                     (default 4 workers; override with
    \\                     MALT_MIGRATE_PARALLEL_WORKERS=N). Successful kegs are
    \\                     recorded in {prefix}/cache/migrate.progress.json so a
    \\                     re-run after a crash or ^C resumes where it stopped.
    \\  --json             Emit a machine-readable summary on stdout (pairs with
    \\                     --dry-run to list kegs, or with a real run to report
    \\                     per-category names + counts for migrated / skipped /
    \\                     failed).
    \\  --use-system-ruby=<name>,...  Run post_install via the system Ruby interpreter
    \\                     (experimental, sandboxed) for the named kegs only. A bare
    \\                     `--use-system-ruby` is not allowed here — it would widen
    \\                     the trust boundary to every keg discovered in the Cellar.
    \\
;

const rollback_help =
    \\Usage: malt rollback <package> [flags]
    \\       malt rollback --list <package>
    \\       malt rollback --to <version> <package>
    \\
    \\Revert a formula or cask to a previous version. Formulas
    \\reuse the content-addressable store (no re-download). Casks
    \\reuse the per-version cache when present and re-download from
    \\the recorded URL otherwise; SHA256 is verified either way.
    \\
    \\Without --to, lands on the most recent previous entry.
    \\
    \\Flags:
    \\  --list             Print every retained version for <package>
    \\                     and exit without changes
    \\  --to <version>     Roll back to the exact version if present;
    \\                     otherwise refuse and print --list. A --to
    \\                     of the currently-installed version is a
    \\                     clean no-op (exit 0)
    \\  --json             Emit --list output as JSON (scriptable)
    \\  --dry-run          Show what would happen
    \\
;

const run_help =
    \\Usage: malt run [--keep] <package> [-- <args...>]
    \\
    \\Run a package binary without installing it. Downloads to a
    \\temp directory, executes, and cleans up. If the package is
    \\already installed, runs the installed binary directly.
    \\
    \\Flags:
    \\  --keep    Cache the extracted bottle under {cache}/run/<sha256>/
    \\            so subsequent runs skip download. Wipe with
    \\            `mt purge --cache`.
    \\
    \\Example:
    \\  malt run jq -- --version
    \\  malt run --keep jq -- --version
    \\
;

const link_help =
    \\Usage: malt link <formula> [flags]
    \\       malt link --isolate <name>
    \\       malt link --isolate --all
    \\
    \\Default form: create symlinks for an installed keg in the prefix
    \\(bin/, lib/, etc.). Re-linking a previously isolated dep also
    \\clears the isolation flag so DB and filesystem agree.
    \\
    \\`--isolate <name>` removes the keg's bin/sbin symlinks and marks
    \\the row `bin_isolated=1`. Useful retroactively on a dep that
    \\predates `--isolate-deps`. Refused on `install_reason='direct'`
    \\kegs — uninstall first if you want a direct keg hidden from PATH.
    \\
    \\`--isolate --all` isolates every dep keg currently linking
    \\bin/sbin.
    \\
    \\Flags:
    \\  --overwrite    Replace existing symlinks
    \\  --force, -f    Same as --overwrite
    \\  --isolate      Remove bin/sbin symlinks; mark the keg isolated
    \\  --all          With --isolate: operate on every dep keg
    \\
;

const unlink_help2 =
    \\Usage: malt unlink <formula>
    \\
    \\Remove symlinks for an installed keg from the prefix.
    \\The keg remains installed in the Cellar.
    \\
;

const completions_help =
    \\Usage: malt completions <shell>
    \\
    \\Generate a shell completion script. The script is printed to stdout
    \\so it can be eval'd for the current shell or redirected to a file.
    \\
    \\Shells:
    \\  bash    Source with: eval "$(malt completions bash)"
    \\  zsh     Source with: eval "$(malt completions zsh)"
    \\  fish    Source with: malt completions fish | source
    \\
    \\Permanent install:
    \\  bash    malt completions bash > /usr/local/etc/bash_completion.d/malt
    \\  zsh     malt completions zsh  > "${fpath[1]}/_malt"
    \\  fish    malt completions fish > ~/.config/fish/completions/malt.fish
    \\
;

const shellenv_help =
    \\Usage: malt shellenv [bash|zsh|fish]
    \\
    \\Print shell-init lines that export HOMEBREW_PREFIX and prepend
    \\malt's bin/sbin/man/info dirs onto PATH/MANPATH/INFOPATH. With no
    \\argument the shell is detected from $SHELL.
    \\
    \\Source from your rc file:
    \\  bash/zsh   eval "$(malt shellenv)"
    \\  fish       malt shellenv fish | source
    \\
;

const backup_help =
    \\Usage: malt backup [flags]
    \\
    \\Dump the list of directly-installed formulae and casks to a plain-text
    \\file that `malt restore` can consume to reproduce the environment on
    \\another machine.
    \\
    \\By default the file is written to the current directory with a
    \\timestamped name, e.g. `malt-backup-2026-04-10T14-32-05.txt`.
    \\
    \\Flags:
    \\  --output, -o <path>  Write to a specific file (use `-` for stdout)
    \\  --versions           Pin each entry to its current version (@ver)
    \\  --services           Include auto-start services so `malt restore`
    \\                       re-bootstraps launchd state on the destination
    \\  --quiet, -q          Suppress non-error output
    \\
    \\Examples:
    \\  malt backup
    \\  malt backup -o ~/dotfiles/packages.txt
    \\  malt backup --versions -o - > snapshot.txt
    \\  malt backup --services -o ~/dotfiles/packages.txt
    \\
;

const purge_help =
    \\Usage: malt purge <scope> [<scope>...] [flags]
    \\
    \\Unified housekeeping and full-wipe command. At least one scope flag
    \\is required — running `malt purge` with no scope is an error.
    \\
    \\Scopes (one or more required):
    \\  --store-orphans      Refcount-0 blobs in {prefix}/store
    \\  --unused-deps        Indirect-install kegs no other package needs
    \\  --cache[=DAYS]       Cache files older than DAYS (default 30)
    \\  --downloads          Wipe {cache}/downloads entirely        (typed confirm)
    \\  --stale-casks        Cask cache + Caskroom for uninstalled casks
    \\  --old-versions       Non-latest Cellar versions + retained cask history (typed confirm)
    \\  --housekeeping       = --store-orphans --unused-deps --cache --stale-casks
    \\  --wipe               Nuclear: every malt artefact on disk    (typed confirm)
    \\
    \\Shared flags:
    \\  --dry-run, -n        Preview only
    \\  --yes, -y            Skip every typed confirmation prompt
    \\  --quiet, -q          Suppress per-item output
    \\  --verbose, -v        Show every per-scope item (no truncation, full SHAs)
    \\  --backup, -b <path>  Write a `mt restore`-compatible manifest first
    \\
    \\Structured output (stdout; stderr stays the human surface):
    \\  --json                  Single summary object: version, dry_run, scopes,
    \\                          totals, time_ms.
    \\  --output-format=ndjson  One {"event":...} line per state transition
    \\                          (scope_started, scope_completed, purge_complete).
    \\
    \\--wipe-only flags:
    \\  --keep-cache         Do not delete the cache directory
    \\  --remove-binary      Also unlink /usr/local/bin/{mt,malt}
    \\
    \\Examples:
    \\  malt purge --housekeeping
    \\  malt purge --store-orphans --dry-run
    \\  malt purge --cache=60 --stale-casks
    \\  malt purge --old-versions --yes
    \\  malt purge --wipe --backup ~/malt-snapshot.txt --remove-binary --yes
    \\
    \\For per-package removal use `mt uninstall <name>`.
    \\
;

const cleanup_help =
    \\Usage: malt cleanup [flags]
    \\
    \\Shorthand for `malt purge --housekeeping` — the safe daily-driver
    \\scope (store-orphans + unused-deps + cache + stale-casks). For the
    \\full menu (downloads scrub, old-versions, wipe) use `mt purge`.
    \\
    \\Flags pass through to `purge`; the common ones:
    \\  --dry-run, -n        Preview only
    \\  --yes, -y            Skip every typed confirmation
    \\  --quiet, -q          Suppress per-item output
    \\  --verbose, -v        Show every per-scope item, full SHAs
    \\  --cache=<DAYS>       Override the 30-day cache cutoff
    \\  --backup, -b <path>  Write a `mt restore`-compatible manifest first
    \\  --json               Single summary object on stdout
    \\  --output-format=ndjson
    \\                       One event per scope start/complete
    \\
    \\Examples:
    \\  malt cleanup
    \\  malt cleanup --dry-run
    \\  malt cleanup --cache=7 --yes
    \\
;

const restore_help =
    \\Usage: malt restore <file> [flags]
    \\
    \\Read a backup file produced by `malt backup` and install every entry
    \\it lists. Formulae and casks are installed in a single batched run each
    \\so dependency resolution and parallel downloads apply normally.
    \\
    \\Flags:
    \\  --dry-run     Print the list of packages that would be installed
    \\  --force       Pass --force to the underlying install
    \\  --quiet, -q   Suppress non-error output
    \\
    \\Example:
    \\  malt restore malt-backup-2026-04-10T14-32-05.txt
    \\
;

const pin_help =
    \\Usage: malt pin <name>
    \\
    \\Mark an installed formula or cask as pinned so `malt upgrade` skips
    \\it. The pin survives across upgrades and is visible in
    \\`mt list --pinned`. Use `mt unpin <name>` to lift it, or
    \\`mt upgrade --force <name>` to override the pin once.
    \\
;

const unpin_help =
    \\Usage: malt unpin <name>
    \\
    \\Lift the pin on an installed formula or cask so subsequent
    \\`malt upgrade` runs touch it again.
    \\
;

const uses_help =
    \\Usage: malt uses <formula> [flags]
    \\
    \\Show installed packages that depend on <formula>. By default only
    \\direct dependents are shown — pass --recursive for the transitive
    \\closure.
    \\
    \\Flags:
    \\  --recursive, -r   Include transitive dependents
    \\  --json            Output as JSON
    \\  --quiet, -q       Suppress status messages
    \\
    \\Examples:
    \\  malt uses openssl@3
    \\  malt uses --recursive icu4c@78
    \\  malt --json uses node@20
    \\
;

const deps_help =
    \\Usage: malt deps <formula> [flags]
    \\
    \\Show what <formula> depends on — the forward symmetric of
    \\`mt uses`. Installed kegs read from the local DB; uninstalled
    \\formulas walk the upstream API.
    \\
    \\Flags:
    \\  --recursive, -r   Walk the transitive closure
    \\  --installed       Restrict to kegs that resolve locally (skips
    \\                    the API fallback; offline-safe)
    \\  --json            Emit `[{"formula","depends_on":[…]}, …]`
    \\  --quiet, -q       Suppress status messages
    \\
    \\Examples:
    \\  malt deps openssl@3
    \\  malt deps --recursive ffmpeg
    \\  malt deps --installed -r node@20
    \\  malt --json deps wget
    \\
;

const which_help =
    \\Usage: malt which <name|path>
    \\
    \\Resolve a prefix binary to the keg that owns it. Accepts a bare
    \\name (resolved through `{prefix}/bin/<name>`) or an absolute path
    \\to a malt-managed symlink. Pairs with `mt uses` as the
    \\forward/reverse lookup pair.
    \\
    \\Flags:
    \\  --json   Emit `{"name", "version", "keg"}` as JSON
    \\
    \\Examples:
    \\  malt which jq
    \\  malt which /opt/malt/bin/jq
    \\  malt --json which jq
    \\
;
