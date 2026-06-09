# malt full demo - CLI + interactive dashboard -> generates docs/demo.gif
#
# Render via the wrapper (handles temp prefix + PATH):
#   ./scripts/record-demo.sh
#
# All setup (throwaway prefix, dev build on PATH, env vars) happens in the
# wrapper *before* vhs starts, so this tape contains only the commands the
# viewer should actually see - no setup, no cleanup, no Hide blocks.

Output docs/demo.gif

Set Shell "bash"
Set FontSize 14
Set Width 1100
Set Height 650
Set Padding 20
Set Theme "Dracula"
Set TypingSpeed 55ms
Set PlaybackSpeed 1.0

# Let bash settle before the first keystroke.
Sleep 500ms

# ── CLI: install a few formulae in parallel - one ships a background service ──
Type "# Install a few formulae in parallel - redis ships a background service"
Sleep 400ms
Enter
Sleep 800ms

Type "malt install jq tree ripgrep redis"
Sleep 400ms
Enter
Sleep 9s

# ── CLI: a package with post_install - configured natively, no Ruby needed ──
Type "# A package with post_install - configured natively, no Ruby needed"
Sleep 400ms
Enter
Sleep 800ms

Type "malt install node"
Sleep 400ms
Enter
Sleep 12s

Type "# Install from a third-party tap — no separate 'tap' step needed"
Sleep 400ms
Enter
Sleep 800ms

Type "malt install goreleaser/tap/goreleaser"
Sleep 400ms
Enter
Sleep 8s

# ── CLI: list installed kegs with their versions ──
Type "# What's installed, with versions"
Sleep 400ms
Enter
Sleep 800ms

Type "malt list --versions"
Sleep 400ms
Enter
Sleep 3s

# ── Launch the built-in dashboard over the same data ──
Type "# Now drive it all from the built-in dashboard"
Sleep 400ms
Enter
Sleep 800ms

Type "mt tui"
Sleep 400ms
Enter
Sleep 4s

# ── Search: query, inspect a hit, multi-select two, install both ──
# Dashboard opens on Search; '/' focuses the query box.
Type "/"
Sleep 1s
Type "bat"
Sleep 1500ms
Enter
Sleep 5s

# Enter opens the info pane for the active hit; Esc closes it again.
Enter
Sleep 4s
Escape
Sleep 1500ms

# 'space' toggles a row's checkbox. Check 'bat', step past a row to
# 'bat-extras' and check it too — the selection persists across the skipped row.
Space
Sleep 1500ms
Down
Sleep 1s
Down
Sleep 1500ms
Space
Sleep 2s

# 'i' installs every checked hit inline - the real `mt install` runs in
# scrollback (bat pulls a few deps, so the full output stays on screen a beat)
# before the dashboard re-enters and both markers flip to installed.
Type "i"
Sleep 11s
# Dwell on the re-entered list so both flipped "installed" markers are visible.
Sleep 2s

# ── Installed tab -> detail pane ──
Type "2"
Sleep 3s
Down
Sleep 1500ms
Enter
Sleep 5s

# ── Services tab -> redis listed (registered by its install, view only) ──
Type "4"
Sleep 5s

# ── Quit back to the shell ──
Type "q"
Sleep 1500ms
