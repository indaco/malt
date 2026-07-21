//! malt — completions command
//! Prints shell completion scripts for bash, zsh, or fish to stdout.

const std = @import("std");

const AppCtx = @import("../app_ctx.zig").AppCtx;
const help = @import("help.zig");

pub const Shell = enum { bash, zsh, fish };

/// Parse a shell name into a Shell enum. Returns null for unknown shells.
pub fn parseShell(name: []const u8) ?Shell {
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "zsh")) return .zsh;
    if (std.mem.eql(u8, name, "fish")) return .fish;
    return null;
}

/// Return the completion script for a given shell.
pub fn scriptFor(shell: Shell) []const u8 {
    return switch (shell) {
        .bash => bash_script,
        .zsh => zsh_script,
        .fish => fish_script,
    };
}

pub fn execute(ctx: *const AppCtx, args: []const []const u8) !void {
    if (help.showIfRequested(ctx, args, "completions")) return;

    if (args.len == 0) {
        printUsage(ctx);
        std.process.exit(2);
    }

    const shell = parseShell(args[0]) orelse {
        const stderr = ctx.stderr;
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "malt: unknown shell '{s}'. Supported shells: bash, zsh, fish\n",
            .{args[0]},
        ) catch "malt: unknown shell. Supported shells: bash, zsh, fish\n";
        // exit(2) below is the real signal; a closed stderr shouldn't block that.
        stderr.writeStreamingAll(ctx.io, msg) catch {};
        std.process.exit(2);
    };

    ctx.stdout.writeStreamingAll(ctx.io, scriptFor(shell)) catch {};
}

fn printUsage(ctx: *const AppCtx) void {
    const usage =
        \\Usage: malt completions <shell>
        \\
        \\Generate a shell completion script for bash, zsh, or fish.
        \\The script is printed to stdout so it can be eval'd or redirected.
        \\
        \\Shells:
        \\  bash    source with: eval "$(malt completions bash)"
        \\  zsh     source with: eval "$(malt completions zsh)"
        \\  fish    source with: malt completions fish | source
        \\
    ;
    // Usage is diagnostic; caller always follows with exit(2).
    ctx.stderr.writeStreamingAll(ctx.io, usage) catch {};
}

// ---------------------------------------------------------------------------
// bash
// ---------------------------------------------------------------------------

pub const bash_script =
    \\# bash completion for malt
    \\#
    \\# Install (temporary, current shell only):
    \\#   eval "$(malt completions bash)"
    \\#
    \\# Install (permanent):
    \\#   malt completions bash > /usr/local/etc/bash_completion.d/malt
    \\#
    \\# Requires bash-completion (brew install bash-completion@2).
    \\
    \\_malt_complete() {
    \\    local cur words cword
    \\    cur="${COMP_WORDS[COMP_CWORD]}"
    \\    words=("${COMP_WORDS[@]}")
    \\    cword=$COMP_CWORD
    \\
    \\    local commands="install reinstall uninstall remove upgrade update outdated list ls info search uses deps which doctor tap untap migrate rollback link unlink pin unpin run version completions shellenv backup restore purge cleanup services tui bundle help"
    \\    local global_flags="--verbose -v --debug --quiet -q --json --output-format=ndjson --dry-run --offline --help -h --version"
    \\
    \\    # Find the first non-flag word after the program — that's the subcommand.
    \\    local cmd="" i
    \\    for (( i=1; i<cword; i++ )); do
    \\        if [[ "${words[i]}" != -* ]]; then
    \\            cmd="${words[i]}"
    \\            break
    \\        fi
    \\    done
    \\
    \\    if [[ -z "$cmd" ]]; then
    \\        if [[ "$cur" == -* ]]; then
    \\            COMPREPLY=( $(compgen -W "$global_flags" -- "$cur") )
    \\        else
    \\            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\        fi
    \\        return 0
    \\    fi
    \\
    \\    case "$cmd" in
    \\        completions|shellenv)
    \\            if [[ "$cur" != -* ]]; then
    \\                COMPREPLY=( $(compgen -W "bash zsh fish" -- "$cur") )
    \\                return 0
    \\            fi
    \\            ;;
    \\        version)
    \\            if [[ "$cur" != -* ]]; then
    \\                COMPREPLY=( $(compgen -W "update" -- "$cur") )
    \\                return 0
    \\            fi
    \\            ;;
    \\        help)
    \\            if [[ "$cur" != -* ]]; then
    \\                COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\                return 0
    \\            fi
    \\            ;;
    \\        services)
    \\            if [[ "$cur" != -* ]]; then
    \\                COMPREPLY=( $(compgen -W "list start stop restart status logs" -- "$cur") )
    \\                return 0
    \\            fi
    \\            ;;
    \\        bundle)
    \\            if [[ "$cur" != -* ]]; then
    \\                COMPREPLY=( $(compgen -W "install cleanup create list remove export import" -- "$cur") )
    \\                return 0
    \\            fi
    \\            ;;
    \\        doctor)
    \\            # `--fix <id>` takes one of the safe-fix class ids as its value.
    \\            if [[ "${words[cword-1]}" == "--fix" ]]; then
    \\                COMPREPLY=( $(compgen -W "stale_lock orphaned_store broken_symlinks" -- "$cur") )
    \\                return 0
    \\            fi
    \\            ;;
    \\    esac
    \\
    \\    local cmd_flags=""
    \\    case "$cmd" in
    \\        install)          cmd_flags="--cask --formula --local --dry-run --force --download-only --only-deps --only-dependencies --isolate-deps --isolate-dependencies --use-system-ruby= --quiet -q --json" ;;
    \\        reinstall)        cmd_flags="--cask --dry-run --isolate-deps --isolate-dependencies --quiet -q --json" ;;
    \\        backup)           cmd_flags="--output -o --versions --services --quiet -q" ;;
    \\        restore)          cmd_flags="--dry-run --force --quiet -q" ;;
    \\        purge)            cmd_flags="--store-orphans --unused-deps --cache --cache= --downloads --stale-casks --old-versions --housekeeping --wipe --backup -b --keep-cache --remove-binary --yes -y --dry-run -n" ;;
    \\        uninstall|remove) cmd_flags="--cask --force --dry-run" ;;
    \\        upgrade)          cmd_flags="--cask --formula --dry-run --pinned --force -f --isolate-deps --isolate-dependencies --use-system-ruby=" ;;
    \\        outdated)         cmd_flags="--json --formula --formulae --cask --casks --pinned-only --tap --refresh --quiet -q" ;;
    \\        update)           cmd_flags="--check --quiet -q" ;;
    \\        version)          cmd_flags="--check --yes -y --no-verify --cleanup" ;;
    \\        list|ls)          cmd_flags="--versions --formula --formulae --cask --casks --pinned --tap --json --size --linked --quiet -q" ;;
    \\        info)             cmd_flags="--formula --cask --json" ;;
    \\        search)           cmd_flags="--formula --formulae --cask --casks --json --installed --api --all --offline" ;;
    \\        uses)             cmd_flags="--recursive -r --json --quiet -q" ;;
    \\        deps)             cmd_flags="--recursive -r --installed --json --quiet -q" ;;
    \\        which)            cmd_flags="--json" ;;
    \\        migrate)          cmd_flags="--dry-run --parallel --use-system-ruby=" ;;
    \\        rollback)         cmd_flags="--dry-run --list --to --json" ;;
    \\        link)             cmd_flags="--overwrite --force -f --isolate --all" ;;
    \\        services)         cmd_flags="--tail --stderr --follow -f --json" ;;
    \\        bundle)           cmd_flags="--dry-run -n --format --services --purge --yes -y --isolate-deps --isolate-dependencies" ;;
    \\        run)              cmd_flags="--keep" ;;
    \\        doctor)           cmd_flags="--fix --dry-run --post-install-status" ;;
    \\        tap)              cmd_flags="--refresh --all --pin --repo --host --forge --url --force --yes -y --json" ;;
    \\    esac
    \\
    \\    if [[ "$cur" == -* ]]; then
    \\        COMPREPLY=( $(compgen -W "$cmd_flags $global_flags" -- "$cur") )
    \\    fi
    \\    return 0
    \\}
    \\
    \\complete -F _malt_complete malt
    \\complete -F _malt_complete mt
    \\
;

// ---------------------------------------------------------------------------
// zsh
// ---------------------------------------------------------------------------

pub const zsh_script =
    \\#compdef malt mt
    \\#
    \\# zsh completion for malt
    \\#
    \\# Install (temporary, current shell only) — run AFTER `compinit`:
    \\#   eval "$(malt completions zsh)"
    \\#
    \\# Install (permanent):
    \\#   malt completions zsh > "${fpath[1]}/_malt"
    \\#
    \\# Requires: autoload -Uz compinit && compinit
    \\
    \\_malt() {
    \\    local curcontext="$curcontext" state line
    \\    local -a commands
    \\
    \\    commands=(
    \\        'install:Install formulas, casks, or tap formulas'
    \\        'reinstall:Wipe and re-materialise an installed package'
    \\        'uninstall:Remove installed packages'
    \\        'remove:Remove installed packages (alias for uninstall)'
    \\        'upgrade:Upgrade installed packages'
    \\        'update:Refresh metadata cache'
    \\        'outdated:List packages with newer versions available'
    \\        'list:List installed packages'
    \\        'ls:List installed packages (alias for list)'
    \\        'info:Show detailed package information'
    \\        'search:Search formulas and casks'
    \\        'uses:Show installed packages that depend on a formula'
    \\        'deps:Show what a formula depends on (forward of `uses`)'
    \\        'which:Resolve a prefix binary to its owning keg'
    \\        'doctor:System health check'
    \\        'tap:Manage taps'
    \\        'untap:Remove a tap'
    \\        'migrate:Import existing Homebrew installation'
    \\        'rollback:Revert a package to its previous version'
    \\        'link:Create symlinks for an installed keg'
    \\        'unlink:Remove symlinks (keg stays installed)'
    \\        'pin:Protect an installed formula or cask from upgrade'
    \\        'unpin:Lift the pin on an installed formula or cask'
    \\        'run:Run a package binary without installing'
    \\        'version:Show version or self-update'
    \\        'completions:Generate shell completion scripts'
    \\        'shellenv:Print PATH/MANPATH/HOMEBREW_PREFIX exports for shell init'
    \\        'backup:Dump installed packages to a restorable text file'
    \\        'restore:Reinstall every package listed in a backup file'
    \\        'purge:Housekeeping or full wipe (requires a scope flag)'
    \\        'cleanup:Shorthand for purge --housekeeping (safe daily-driver)'
    \\        'services:Manage long-running launchd services'
    \\        'tui:Interactive dashboard (search, installed, outdated, services, doctor)'
    \\        'bundle:Install or export a Brewfile/Maltfile.json bundle'
    \\        'help:Show help'
    \\    )
    \\
    \\    _arguments -C \
    \\        '(--verbose -v)'{--verbose,-v}'[Verbose output]' \
    \\        '--debug[Surface every DSL diagnostic (implies verbose)]' \
    \\        '(--quiet -q)'{--quiet,-q}'[Suppress non-error output]' \
    \\        '--json[JSON output]' \
    \\        '--output-format=ndjson[Stream one JSON event per state transition]' \
    \\        '--dry-run[Preview without executing]' \
    \\        '--offline[Serve every fetch from the snapshot cache; fail fast on a miss]' \
    \\        '(- : *)'{--help,-h}'[Show help]' \
    \\        '(- : *)--version[Show version]' \
    \\        '1: :->command' \
    \\        '*:: :->args' && return 0
    \\
    \\    case $state in
    \\        command)
    \\            _describe -t commands 'malt command' commands
    \\            ;;
    \\        args)
    \\            case $words[1] in
    \\                install)
    \\                    _arguments \
    \\                        '--cask[Force cask installation]' \
    \\                        '--formula[Force formula installation]' \
    \\                        '--local[Install from a local .rb path]:formula:_files -g "*.rb"' \
    \\                        '--dry-run[Show what would be installed]' \
    \\                        '--force[Overwrite existing installations]' \
    \\                        '--download-only[Warm the bottle, cask, or tap-archive cache; skip install]' \
    \\                        '--only-deps[Install transitive deps, skip the requested package]' \
    \\                        '--only-dependencies[Brew-parity alias of --only-deps]' \
    \\                        '--isolate-deps[Keep transitive deps out of <prefix>/bin and <prefix>/sbin]' \
    \\                        '--isolate-dependencies[Alias of --isolate-deps]' \
    \\                        '--use-system-ruby=[Run post_install via system Ruby for the named kegs]:names:' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress non-error output]' \
    \\                        '--json[Output result as JSON]' \
    \\                        '*::package:'
    \\                    ;;
    \\                reinstall)
    \\                    _arguments \
    \\                        '--cask[Force cask path (auto-detected from the DB)]' \
    \\                        '--dry-run[Show what would be reinstalled]' \
    \\                        '--isolate-deps[Apply isolation to any newly fetched dep]' \
    \\                        '--isolate-dependencies[Alias of --isolate-deps]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress non-error output]' \
    \\                        '--json[Output result as JSON]' \
    \\                        '*::package:'
    \\                    ;;
    \\                uninstall|remove)
    \\                    _arguments \
    \\                        '--cask[Treat the name as a cask]' \
    \\                        '--force[Remove even if depended on]' \
    \\                        '--dry-run[Show what would be removed]' \
    \\                        '*::package:'
    \\                    ;;
    \\                upgrade)
    \\                    _arguments \
    \\                        '--cask[Upgrade casks only]' \
    \\                        '--formula[Upgrade formulas only]' \
    \\                        '--dry-run[Show what would be upgraded]' \
    \\                        '--pinned[Audit pinned formulas + casks (requires --dry-run or --force)]' \
    \\                        '(--force -f)'{--force,-f}'[Bypass pin protection]' \
    \\                        '--isolate-deps[Apply isolation to deps newly pulled in by this upgrade]' \
    \\                        '--isolate-dependencies[Alias of --isolate-deps]' \
    \\                        '--use-system-ruby=[Run post_install via system Ruby for the named kegs]:names:' \
    \\                        '*::package:'
    \\                    ;;
    \\                pin|unpin)
    \\                    _arguments '*::keg:'
    \\                    ;;
    \\                run)
    \\                    _arguments \
    \\                        '--keep[Cache extracted bottle under {cache}/run/<sha256>/]' \
    \\                        '*::package:'
    \\                    ;;
    \\                uses)
    \\                    _arguments \
    \\                        '(--recursive -r)'{--recursive,-r}'[Include transitive dependents]' \
    \\                        '--json[Output as JSON]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress status messages]' \
    \\                        '*::package:'
    \\                    ;;
    \\                deps)
    \\                    _arguments \
    \\                        '(--recursive -r)'{--recursive,-r}'[Walk transitive deps]' \
    \\                        '--installed[Restrict to locally-resolved kegs]' \
    \\                        '--json[Output as JSON]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress status messages]' \
    \\                        '*::package:'
    \\                    ;;
    \\                which)
    \\                    _arguments \
    \\                        '--json[Output as JSON]' \
    \\                        '*::name-or-path:'
    \\                    ;;
    \\                outdated)
    \\                    _arguments \
    \\                        '--json[Output as JSON]' \
    \\                        '--formula[Show outdated formulas only]' \
    \\                        '--formulae[Alias of --formula]' \
    \\                        '--cask[Show outdated casks only]' \
    \\                        '--casks[Alias of --cask]' \
    \\                        '--pinned-only[Audit pinned formulas + casks only]' \
    \\                        '--tap[Only packages from <label> (e.g. user/repo)]:tap label:' \
    \\                        '--refresh[Force live recompute, bypass the cached snapshot]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress status messages]'
    \\                    ;;
    \\                update)
    \\                    _arguments \
    \\                        '--check[Refresh only the outdated snapshot, skip API cache wipe]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress status messages]'
    \\                    ;;
    \\                list|ls)
    \\                    _arguments \
    \\                        '--versions[Show version numbers]' \
    \\                        '--formula[Formulas only]' \
    \\                        '--formulae[Alias of --formula]' \
    \\                        '--cask[Casks only]' \
    \\                        '--casks[Alias of --cask]' \
    \\                        '--pinned[Pinned packages only]' \
    \\                        '--tap[Only packages from <label> (e.g. user/repo)]:tap label:' \
    \\                        '--json[Output as JSON]' \
    \\                        '--size[With --json: add on-disk size_bytes per row]' \
    \\                        '--linked[With --json: add link status per row]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Names only]'
    \\                    ;;
    \\                info)
    \\                    _arguments \
    \\                        '--formula[Show formula info only]' \
    \\                        '--cask[Show cask info only]' \
    \\                        '--json[Output as JSON]' \
    \\                        '*::package:'
    \\                    ;;
    \\                search)
    \\                    _arguments \
    \\                        '--formula[Search formulas only]' \
    \\                        '--formulae[Alias of --formula]' \
    \\                        '--cask[Search casks only]' \
    \\                        '--casks[Alias of --cask]' \
    \\                        '--installed[Local DB only, no network]' \
    \\                        '--api[Force Homebrew API path]' \
    \\                        '--all[Run local + API and merge results]' \
    \\                        '--offline[Alias of --installed (mirrors MALT_OFFLINE)]' \
    \\                        '--json[Output as JSON]' \
    \\                        '*::query:'
    \\                    ;;
    \\                migrate)
    \\                    _arguments \
    \\                        '--dry-run[Preview without executing]' \
    \\                        '--parallel[Migrate kegs concurrently with a bounded worker pool]' \
    \\                        '--use-system-ruby=[Run post_install via system Ruby for the named kegs]:names:'
    \\                    ;;
    \\                rollback)
    \\                    _arguments \
    \\                        '--dry-run[Preview without executing]' \
    \\                        '--list[List every reachable store entry for <package>]' \
    \\                        '--to[Roll back to a specific store entry]:version:' \
    \\                        '--json[Emit --list output as JSON]' \
    \\                        '*::package:'
    \\                    ;;
    \\                link)
    \\                    _arguments \
    \\                        '--overwrite[Replace existing symlinks]' \
    \\                        '(--force -f)'{--force,-f}'[Same as --overwrite]' \
    \\                        '--isolate[Remove bin/sbin links and mark a dep isolated]' \
    \\                        '--all[With --isolate: every dep keg]' \
    \\                        '*::formula:'
    \\                    ;;
    \\                completions|shellenv)
    \\                    _values 'shell' bash zsh fish
    \\                    ;;
    \\                help)
    \\                    _describe -t commands 'malt command' commands
    \\                    ;;
    \\                backup)
    \\                    _arguments \
    \\                        '(--output -o)'{--output,-o}'[Write to a specific file]:path:_files' \
    \\                        '--versions[Pin each entry to its current version]' \
    \\                        '--services[Include auto-start services so restore re-bootstraps launchd]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress non-error output]'
    \\                    ;;
    \\                restore)
    \\                    _arguments \
    \\                        '--dry-run[Preview without installing]' \
    \\                        '--force[Pass --force to the install]' \
    \\                        '(--quiet -q)'{--quiet,-q}'[Suppress non-error output]' \
    \\                        '*:file:_files'
    \\                    ;;
    \\                purge)
    \\                    _arguments \
    \\                        '--store-orphans[Refcount-0 store blobs]' \
    \\                        '--unused-deps[Orphaned dependency kegs]' \
    \\                        '--cache=-[Prune cache files older than N days]::days:' \
    \\                        '--cache[Prune cache files older than 30 days]' \
    \\                        '--downloads[Wipe the downloads cache]' \
    \\                        '--stale-casks[Remove cache + Caskroom for uninstalled casks]' \
    \\                        '--old-versions[Remove non-latest Cellar versions + retained cask history]' \
    \\                        '--housekeeping[All safe scopes at once]' \
    \\                        '--wipe[Nuclear: remove every malt artefact]' \
    \\                        '(--backup -b)'{--backup,-b}'[Write a restorable manifest before deleting]:path:_files' \
    \\                        '--keep-cache[--wipe only: leave the cache directory intact]' \
    \\                        '--remove-binary[--wipe only: also unlink /usr/local/bin/{mt,malt}]' \
    \\                        '(--yes -y)'{--yes,-y}'[Skip every typed confirmation]' \
    \\                        '(--dry-run -n)'{--dry-run,-n}'[Preview without removing]' \
    \\                        '(--verbose -v)'{--verbose,-v}'[Show every per-scope item; no truncation, full SHAs]' \
    \\                        '--json[Single summary object on stdout for scripts]' \
    \\                        '--output-format=ndjson[Stream one event per scope start/complete + purge_complete]'
    \\                    ;;
    \\                version)
    \\                    _arguments \
    \\                        '--check[Only report whether a newer release exists]' \
    \\                        '(--yes -y)'{--yes,-y}'[Skip the confirmation prompt]' \
    \\                        '--no-verify[Skip signature/checksum verification]' \
    \\                        '--cleanup[Remove .old backups and staging files]' \
    \\                        '1:subcommand:(update)'
    \\                    ;;
    \\                services)
    \\                    _arguments \
    \\                        '--tail[Number of trailing log lines]:lines:' \
    \\                        '--stderr[Read stderr instead of stdout]' \
    \\                        '(--follow -f)'{--follow,-f}'[Tail appended bytes until SIGINT]' \
    \\                        '--json[Output as JSON]' \
    \\                        '1:subcommand:(list start stop restart status logs)'
    \\                    ;;
    \\                bundle)
    \\                    _arguments \
    \\                        '(--dry-run -n)'{--dry-run,-n}'[Preview without installing/uninstalling]' \
    \\                        '--format[Output format]:format:(brewfile json)' \
    \\                        '--services[Include auto-start services (JSON only)]' \
    \\                        '--purge[With remove: also uninstall the members]' \
    \\                        '(--yes -y)'{--yes,-y}'[Skip the confirmation prompt]' \
    \\                        '--isolate-deps[Apply isolation to transitive deps of every member]' \
    \\                        '--isolate-dependencies[Alias of --isolate-deps]' \
    \\                        '1:subcommand:(install cleanup create list remove export import)'
    \\                    ;;
    \\                tap)
    \\                    _arguments \
    \\                        '--refresh[Advance the pin to current HEAD]' \
    \\                        '--all[With --refresh: walk every registered tap]' \
    \\                        '--pin[Explicitly pin <slug> to <sha>]' \
    \\                        '--repo[Point the tap at owner/exact-repo (no homebrew- prefix)]:owner/exact-repo:' \
    \\                        '--host[Register the tap on a non-GitHub forge (e.g. gitlab.com)]:forge-host:' \
    \\                        '--forge[Pin the provider for a custom-domain host]:provider:(github gitlab gitea gogs)' \
    \\                        '--url[Derive (host, owner, repo) from a full repo URL]:repo-url:' \
    \\                        '--force[Rebind an existing tap to a new --repo target]' \
    \\                        '(--yes -y)'{--yes,-y}'[Confirm --refresh --all apply]' \
    \\                        '--json[Emit refresh-all diff as JSON]' \
    \\                        '*::slug:'
    \\                    ;;
    \\                doctor)
    \\                    _arguments \
    \\                        '--fix[Apply safe-class fixers; with <id>, only that class]::fix-id:(stale_lock orphaned_store broken_symlinks)' \
    \\                        '--dry-run[Preview the fix plan without applying]' \
    \\                        '--post-install-status[Report post_install state per keg]'
    \\                    ;;
    \\            esac
    \\            ;;
    \\    esac
    \\}
    \\
    \\# When sourced via `eval`, register the completion with the running shell.
    \\# When placed in fpath as `_malt`, the `#compdef` line above handles it and
    \\# this call is harmless.
    \\compdef _malt malt mt 2>/dev/null || true
    \\
;

// ---------------------------------------------------------------------------
// fish
// ---------------------------------------------------------------------------

pub const fish_script =
    \\# fish completion for malt
    \\#
    \\# Install (temporary, current shell only):
    \\#   malt completions fish | source
    \\#
    \\# Install (permanent):
    \\#   malt completions fish > ~/.config/fish/completions/malt.fish
    \\
    \\function __malt_needs_command
    \\    set -l tokens (commandline -opc)
    \\    set -l i 2
    \\    while test $i -le (count $tokens)
    \\        if not string match -q -- '-*' $tokens[$i]
    \\            return 1
    \\        end
    \\        set i (math $i + 1)
    \\    end
    \\    return 0
    \\end
    \\
    \\function __malt_using_command
    \\    set -l tokens (commandline -opc)
    \\    set -l i 2
    \\    while test $i -le (count $tokens)
    \\        if not string match -q -- '-*' $tokens[$i]
    \\            if test "$tokens[$i]" = "$argv[1]"
    \\                return 0
    \\            end
    \\            return 1
    \\        end
    \\        set i (math $i + 1)
    \\    end
    \\    return 1
    \\end
    \\
    \\for __malt_bin in malt mt
    \\    complete -c $__malt_bin -f
    \\
    \\    # Global flags
    \\    complete -c $__malt_bin -s v -l verbose -d 'Verbose output'
    \\    complete -c $__malt_bin      -l debug   -d 'Surface every DSL diagnostic (implies verbose)'
    \\    complete -c $__malt_bin -s q -l quiet   -d 'Suppress non-error output'
    \\    complete -c $__malt_bin      -l json    -d 'JSON output'
    \\    complete -c $__malt_bin      -l output-format=ndjson -d 'Stream one JSON event per state transition'
    \\    complete -c $__malt_bin      -l dry-run -d 'Preview without executing'
    \\    complete -c $__malt_bin      -l offline -d 'Serve every fetch from the snapshot cache; fail fast on a miss'
    \\    complete -c $__malt_bin -s h -l help    -d 'Show help'
    \\    complete -c $__malt_bin      -l version -d 'Show version'
    \\
    \\    # Subcommands
    \\    complete -c $__malt_bin -n __malt_needs_command -a install     -d 'Install formulas, casks, or tap formulas'
    \\    complete -c $__malt_bin -n __malt_needs_command -a reinstall   -d 'Wipe and re-materialise an installed package'
    \\    complete -c $__malt_bin -n __malt_needs_command -a uninstall   -d 'Remove installed packages'
    \\    complete -c $__malt_bin -n __malt_needs_command -a remove      -d 'Remove installed packages (alias)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a upgrade     -d 'Upgrade installed packages'
    \\    complete -c $__malt_bin -n __malt_needs_command -a update      -d 'Refresh metadata cache'
    \\    complete -c $__malt_bin -n __malt_needs_command -a outdated    -d 'List packages with newer versions'
    \\    complete -c $__malt_bin -n __malt_needs_command -a list        -d 'List installed packages'
    \\    complete -c $__malt_bin -n __malt_needs_command -a ls          -d 'List installed packages (alias)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a info        -d 'Show detailed package information'
    \\    complete -c $__malt_bin -n __malt_needs_command -a search      -d 'Search formulas and casks'
    \\    complete -c $__malt_bin -n __malt_needs_command -a uses        -d 'Show packages that depend on a formula'
    \\    complete -c $__malt_bin -n __malt_needs_command -a deps        -d 'Show what a formula depends on'
    \\    complete -c $__malt_bin -n __malt_needs_command -a which       -d 'Resolve a prefix binary to its owning keg'
    \\    complete -c $__malt_bin -n __malt_needs_command -a doctor      -d 'System health check'
    \\    complete -c $__malt_bin -n __malt_needs_command -a tap         -d 'Manage taps'
    \\    complete -c $__malt_bin -n __malt_needs_command -a untap       -d 'Remove a tap'
    \\    complete -c $__malt_bin -n __malt_needs_command -a migrate     -d 'Import existing Homebrew'
    \\    complete -c $__malt_bin -n __malt_needs_command -a rollback    -d 'Revert package to previous version'
    \\    complete -c $__malt_bin -n __malt_needs_command -a link        -d 'Create symlinks for a keg'
    \\    complete -c $__malt_bin -n __malt_needs_command -a unlink      -d 'Remove symlinks (keg stays)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a pin         -d 'Protect an installed formula or cask from upgrade'
    \\    complete -c $__malt_bin -n __malt_needs_command -a unpin       -d 'Lift the pin on an installed formula or cask'
    \\    complete -c $__malt_bin -n __malt_needs_command -a run         -d 'Run package binary without installing'
    \\    complete -c $__malt_bin -n __malt_needs_command -a version     -d 'Show version or self-update'
    \\    complete -c $__malt_bin -n __malt_needs_command -a completions -d 'Generate shell completion scripts'
    \\    complete -c $__malt_bin -n __malt_needs_command -a shellenv    -d 'Print shell init exports (PATH, MANPATH, HOMEBREW_PREFIX)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a backup      -d 'Dump installed packages to a text file'
    \\    complete -c $__malt_bin -n __malt_needs_command -a restore     -d 'Reinstall every package in a backup file'
    \\    complete -c $__malt_bin -n __malt_needs_command -a purge       -d 'Housekeeping or full wipe (requires a scope)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a cleanup     -d 'Shorthand for purge --housekeeping (safe daily-driver)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a services    -d 'Manage long-running launchd services'
    \\    complete -c $__malt_bin -n __malt_needs_command -a tui         -d 'Interactive dashboard (search, installed, outdated, services, doctor)'
    \\    complete -c $__malt_bin -n __malt_needs_command -a bundle      -d 'Install or export a Brewfile/Maltfile.json'
    \\    complete -c $__malt_bin -n __malt_needs_command -a help        -d 'Show help'
    \\
    \\    # install
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l cask    -d 'Force cask'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l formula -d 'Force formula'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l local   -d 'Install from a local .rb path'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l dry-run -d 'Preview'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l force   -d 'Overwrite existing'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l download-only -d 'Warm the bottle, cask, or tap-archive cache; skip install'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l only-deps         -d 'Install transitive deps; skip the requested package'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l only-dependencies -d 'Brew-parity alias of --only-deps'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l isolate-deps         -d 'Keep transitive deps out of <prefix>/bin and <prefix>/sbin'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l isolate-dependencies -d 'Alias of --isolate-deps'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l use-system-ruby -d 'Run post_install via system Ruby for the named kegs'
    \\    complete -c $__malt_bin -n '__malt_using_command install' -l json    -d 'JSON output'
    \\
    \\    # reinstall
    \\    complete -c $__malt_bin -n '__malt_using_command reinstall' -l cask    -d 'Force cask path (auto-detected from the DB)'
    \\    complete -c $__malt_bin -n '__malt_using_command reinstall' -l dry-run -d 'Preview'
    \\    complete -c $__malt_bin -n '__malt_using_command reinstall' -l isolate-deps         -d 'Apply isolation to deps newly fetched by this reinstall'
    \\    complete -c $__malt_bin -n '__malt_using_command reinstall' -l isolate-dependencies -d 'Alias of --isolate-deps'
    \\    complete -c $__malt_bin -n '__malt_using_command reinstall' -l json    -d 'JSON output'
    \\
    \\    # uninstall / remove
    \\    complete -c $__malt_bin -n '__malt_using_command uninstall' -l cask    -d 'Treat the name as a cask'
    \\    complete -c $__malt_bin -n '__malt_using_command uninstall' -l force   -d 'Remove even if depended on'
    \\    complete -c $__malt_bin -n '__malt_using_command uninstall' -l dry-run -d 'Preview'
    \\    complete -c $__malt_bin -n '__malt_using_command remove'    -l cask    -d 'Treat the name as a cask'
    \\    complete -c $__malt_bin -n '__malt_using_command remove'    -l force   -d 'Remove even if depended on'
    \\    complete -c $__malt_bin -n '__malt_using_command remove'    -l dry-run -d 'Preview'
    \\
    \\    # upgrade
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l cask    -d 'Casks only'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l formula -d 'Formulas only'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l dry-run -d 'Preview'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l pinned  -d 'Audit pinned formulas + casks (needs --dry-run or --force)'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -s f -l force -d 'Bypass pin protection'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l isolate-deps         -d 'Apply isolation to deps newly pulled in by this upgrade'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l isolate-dependencies -d 'Alias of --isolate-deps'
    \\    complete -c $__malt_bin -n '__malt_using_command upgrade' -l use-system-ruby -d 'Run post_install via system Ruby for the named kegs'
    \\
    \\    # outdated
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l json        -d 'JSON output'
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l formula     -d 'Formulas only'
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l formulae    -d 'Alias of --formula'
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l cask        -d 'Casks only'
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l casks       -d 'Alias of --cask'
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l pinned-only -d 'Pinned formulas + casks only'
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l tap         -x -d 'Only packages from <label>'
    \\    complete -c $__malt_bin -n '__malt_using_command outdated' -l refresh     -d 'Force live recompute, bypass the cached snapshot'
    \\
    \\    # update
    \\    complete -c $__malt_bin -n '__malt_using_command update' -l check -d 'Refresh only the outdated snapshot, skip API cache wipe'
    \\
    \\    # list / ls
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l versions -d 'Show version numbers'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l formula  -d 'Formulas only'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l formulae -d 'Alias of --formula'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l cask     -d 'Casks only'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l casks    -d 'Alias of --cask'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l pinned   -d 'Pinned only'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l tap      -x -d 'Only packages from <label>'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l json     -d 'JSON output'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l size     -d 'With --json: add on-disk size_bytes'
    \\    complete -c $__malt_bin -n '__malt_using_command list' -l linked   -d 'With --json: add link status'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l versions -d 'Show version numbers'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l formula  -d 'Formulas only'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l formulae -d 'Alias of --formula'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l cask     -d 'Casks only'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l casks    -d 'Alias of --cask'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l pinned   -d 'Pinned only'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l tap      -x -d 'Only packages from <label>'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l json     -d 'JSON output'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l size     -d 'With --json: add on-disk size_bytes'
    \\    complete -c $__malt_bin -n '__malt_using_command ls'   -l linked   -d 'With --json: add link status'
    \\
    \\    # info
    \\    complete -c $__malt_bin -n '__malt_using_command info' -l formula -d 'Formula only'
    \\    complete -c $__malt_bin -n '__malt_using_command info' -l cask    -d 'Cask only'
    \\    complete -c $__malt_bin -n '__malt_using_command info' -l json    -d 'JSON output'
    \\
    \\    # search
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l formula   -d 'Formulas only'
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l formulae  -d 'Alias of --formula'
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l cask      -d 'Casks only'
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l casks     -d 'Alias of --cask'
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l installed -d 'Local DB only, no network'
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l api       -d 'Force Homebrew API path'
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l all       -d 'Run local + API and merge'
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l offline   -d 'Alias of --installed'
    \\    complete -c $__malt_bin -n '__malt_using_command search' -l json      -d 'JSON output'
    \\
    \\    # uses
    \\    complete -c $__malt_bin -n '__malt_using_command uses' -l recursive -s r -d 'Include transitive dependents'
    \\    complete -c $__malt_bin -n '__malt_using_command uses' -l json               -d 'JSON output'
    \\    complete -c $__malt_bin -n '__malt_using_command uses' -l quiet     -s q    -d 'Suppress status messages'
    \\
    \\    # deps
    \\    complete -c $__malt_bin -n '__malt_using_command deps' -l recursive -s r -d 'Walk transitive deps'
    \\    complete -c $__malt_bin -n '__malt_using_command deps' -l installed         -d 'Restrict to locally-resolved kegs'
    \\    complete -c $__malt_bin -n '__malt_using_command deps' -l json              -d 'JSON output'
    \\    complete -c $__malt_bin -n '__malt_using_command deps' -l quiet     -s q   -d 'Suppress status messages'
    \\
    \\    # which
    \\    complete -c $__malt_bin -n '__malt_using_command which' -l json -d 'JSON output'
    \\
    \\    # doctor — --fix takes an optional safe-fix class id
    \\    complete -c $__malt_bin -n '__malt_using_command doctor' -l fix -r -a 'stale_lock orphaned_store broken_symlinks' -d 'Apply safe-class fixers; with <id>, only that class'
    \\    complete -c $__malt_bin -n '__malt_using_command doctor' -l dry-run -d 'Preview the fix plan without applying'
    \\    complete -c $__malt_bin -n '__malt_using_command doctor' -l post-install-status -d 'Report post_install state per keg'
    \\
    \\    # migrate / rollback
    \\    complete -c $__malt_bin -n '__malt_using_command migrate'    -l dry-run -d 'Preview'
    \\    complete -c $__malt_bin -n '__malt_using_command migrate'    -l parallel -d 'Migrate kegs concurrently with a bounded worker pool'
    \\    complete -c $__malt_bin -n '__malt_using_command migrate'    -l use-system-ruby -d 'Run post_install via system Ruby for the named kegs'
    \\    complete -c $__malt_bin -n '__malt_using_command rollback'   -l dry-run -d 'Preview'
    \\    complete -c $__malt_bin -n '__malt_using_command rollback'   -l list    -d 'List every reachable store entry'
    \\    complete -c $__malt_bin -n '__malt_using_command rollback'   -l to    -x -d 'Roll back to a specific store entry (pass <version>)'
    \\    complete -c $__malt_bin -n '__malt_using_command rollback'   -l json    -d 'Emit --list output as JSON'
    \\
    \\    # link
    \\    complete -c $__malt_bin -n '__malt_using_command link' -l overwrite -d 'Replace existing symlinks'
    \\    complete -c $__malt_bin -n '__malt_using_command link' -s f -l force -d 'Same as --overwrite'
    \\    complete -c $__malt_bin -n '__malt_using_command link' -l isolate    -d 'Remove bin/sbin links and mark a dep isolated'
    \\    complete -c $__malt_bin -n '__malt_using_command link' -l all        -d 'With --isolate: every dep keg'
    \\
    \\    # run
    \\    complete -c $__malt_bin -n '__malt_using_command run' -l keep -d 'Cache extracted bottle under {cache}/run/<sha256>/'
    \\
    \\    # tap
    \\    complete -c $__malt_bin -n '__malt_using_command tap' -l refresh -d 'Advance the pin to current HEAD'
    \\    complete -c $__malt_bin -n '__malt_using_command tap' -l all     -d 'With --refresh: walk every registered tap'
    \\    complete -c $__malt_bin -n '__malt_using_command tap' -l pin     -d 'Explicitly pin <slug> to <sha>'
    \\    complete -c $__malt_bin -n '__malt_using_command tap' -l repo    -x -d 'Point the tap at owner/exact-repo (no homebrew- prefix)'
    \\    complete -c $__malt_bin -n '__malt_using_command tap' -l host    -x -d 'Register the tap on a non-GitHub forge (e.g. gitlab.com)'
    \\    complete -c $__malt_bin -n '__malt_using_command tap' -l forge   -x -a 'github gitlab gitea gogs' -d 'Pin the provider for a custom-domain host'
    \\    complete -c $__malt_bin -n '__malt_using_command tap' -l url     -x -d 'Derive (host, owner, repo) from a full repo URL'
    \\    complete -c $__malt_bin -n '__malt_using_command tap' -l force   -d 'Rebind an existing tap to a new --repo target'
    \\    complete -c $__malt_bin -n '__malt_using_command tap' -s y -l yes -d 'Confirm --refresh --all apply'
    \\    complete -c $__malt_bin -n '__malt_using_command tap' -l json    -d 'Emit refresh-all diff as JSON'
    \\
    \\    # completions — shell name as positional
    \\    complete -c $__malt_bin -n '__malt_using_command completions' -f -a 'bash zsh fish'
    \\
    \\    # shellenv — shell name as positional
    \\    complete -c $__malt_bin -n '__malt_using_command shellenv' -f -a 'bash zsh fish'
    \\
    \\    # backup
    \\    complete -c $__malt_bin -n '__malt_using_command backup' -s o -l output   -r -d 'Output file (use - for stdout)'
    \\    complete -c $__malt_bin -n '__malt_using_command backup'      -l versions    -d 'Pin each entry to its current version'
    \\    complete -c $__malt_bin -n '__malt_using_command backup'      -l services    -d 'Include auto-start services for restore'
    \\
    \\    # restore — positional backup file
    \\    complete -c $__malt_bin -n '__malt_using_command restore' -l dry-run -d 'Preview without installing'
    \\    complete -c $__malt_bin -n '__malt_using_command restore' -l force   -d 'Pass --force to install'
    \\    complete -c $__malt_bin -n '__malt_using_command restore' -F
    \\
    \\    # purge — scope flags
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l store-orphans    -d 'Refcount-0 store blobs'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l unused-deps      -d 'Orphaned dependency kegs'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l cache            -d 'Prune cache files older than 30 days (or N via --cache=N)'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l downloads        -d 'Wipe the downloads cache (typed confirm)'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l stale-casks      -d 'Cask cache + Caskroom for uninstalled casks'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l old-versions     -d 'Non-latest Cellar versions + retained cask history (typed confirm)'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l housekeeping     -d 'All safe scopes at once'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l wipe             -d 'Nuclear: every malt artefact (typed confirm)'
    \\    # purge — shared / wipe-only flags
    \\    complete -c $__malt_bin -n '__malt_using_command purge' -s b -l backup        -r -d 'Write a restorable manifest before deleting'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l keep-cache       -d '--wipe only: leave the cache directory intact'
    \\    complete -c $__malt_bin -n '__malt_using_command purge'      -l remove-binary    -d '--wipe only: also unlink /usr/local/bin/{mt,malt}'
    \\    complete -c $__malt_bin -n '__malt_using_command purge' -s y -l yes             -d 'Skip every typed confirmation'
    \\    complete -c $__malt_bin -n '__malt_using_command purge' -s n -l dry-run          -d 'Preview without removing'
    \\
    \\    # version — sub-subcommand + update flags
    \\    complete -c $__malt_bin -n '__malt_using_command version' -f -a 'update' -d 'Self-update'
    \\    complete -c $__malt_bin -n '__malt_using_command version' -l check     -d 'Only report whether a newer release exists'
    \\    complete -c $__malt_bin -n '__malt_using_command version' -l yes -s y  -d 'Skip the confirmation prompt'
    \\    complete -c $__malt_bin -n '__malt_using_command version' -l no-verify -d 'Skip signature/checksum verification'
    \\    complete -c $__malt_bin -n '__malt_using_command version' -l cleanup   -d 'Remove .old backups and staging files'
    \\
    \\    # services — sub-subcommands
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'list'    -d 'Show registered services'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'start'   -d 'Bootstrap a service under launchd'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'stop'    -d 'Boot a service out of launchd'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'restart' -d 'Stop then start'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'status'  -d 'Show runtime + DB state'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -f -a 'logs'    -d 'Tail a service log'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -l tail   -d 'Number of trailing log lines'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -l stderr -d 'Read stderr instead of stdout'
    \\    complete -c $__malt_bin -n '__malt_using_command services' -l follow -s f -d 'Tail appended bytes until SIGINT'
    \\
    \\    # help — command topic
    \\    complete -c $__malt_bin -n '__malt_using_command help' -f -a 'install reinstall uninstall remove upgrade update outdated list ls info search uses deps which doctor tap untap migrate rollback link unlink pin unpin run version completions shellenv backup restore purge cleanup services tui bundle' -d 'Help topic'
    \\
    \\    # bundle — sub-subcommands
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'install' -d 'Install Brewfile/Maltfile.json members'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'cleanup' -d 'Uninstall packages absent from the Brewfile'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'create'  -d 'Write installed set to a bundle file'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'list'    -d 'List registered bundles'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'remove'  -d 'Unregister a bundle'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'export'  -d 'Print bundle to stdout'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -f -a 'import'  -d 'Register a bundle without installing'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l dry-run -s n  -d 'Preview without installing/uninstalling'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l yes     -s y  -d 'Skip the cleanup confirmation prompt'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l format -r -a 'brewfile json' -d 'Output format'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l services       -d 'Include auto-start services (JSON only)'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l purge          -d 'With remove: also uninstall the members'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l isolate-deps         -d 'Apply isolation to transitive deps of every member'
    \\    complete -c $__malt_bin -n '__malt_using_command bundle' -l isolate-dependencies -d 'Alias of --isolate-deps'
    \\end
    \\
    \\set -e __malt_bin
    \\
;
