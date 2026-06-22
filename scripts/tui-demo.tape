# malt TUI feature demo - search, install, services, doctor -> docs/tui-demo.gif
#
# Render via the wrapper (handles temp prefix + PATH + a pre-installed redis):
#   ./scripts/record-tui-demo.sh
#
# All setup (throwaway prefix, dev build on PATH, the redis the Services tab
# drives) happens in the wrapper *before* vhs starts, so this tape contains
# only what the viewer should see - no setup, no cleanup, no Hide blocks.

Output docs/tui-demo.gif

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

# ── Launch the built-in dashboard (opens on the Search tab) ──
Type "mt tui"
Sleep 400ms
Enter
Sleep 3s

# ── Search cycle 1: query 'bat', inspect, add two to the cross-query basket ──
# '/' focuses the query box.
Type "/"
Sleep 1s
Type "bat"
Sleep 1500ms
Enter
Sleep 4s

# Enter opens the info pane for the active hit; Esc closes it again.
Enter
Sleep 3s
Escape
Sleep 1s

# 'space' adds a hit to the cross-query basket (footer shows "N selected").
# Add 'bat', step past a row to 'bat-extras' and add it too.
Space
Sleep 1s
Down
Sleep 800ms
Down
Sleep 1s
Space
Sleep 1500ms

# ── Search cycle 2: a brand-new query, but the basket persists ──
# Re-focus the box, clear 'bat', search 'redis', add it to the same basket.
# (Backspace on empty is a no-op.)
Type "/"
Sleep 800ms
Backspace 6
Sleep 800ms
Type "redis"
Sleep 1500ms
Enter
Sleep 4s
Space
Sleep 1500ms

# 'l' opens the basket view - all three picks, gathered across both queries.
Type "l"
Sleep 3s

# 'i' installs the whole basket in one shot; the real `mt install` runs in
# scrollback, then the dashboard re-enters. The wrapper pre-warms the cache,
# so the install is warm and fast.
Type "i"
Sleep 8s
# Dwell on the re-entered list so the flipped "installed" markers are visible.
Sleep 1500ms

# ── Installed tab (2) -> detail pane ──
Type "2"
Sleep 3s
Down
Sleep 1s
Enter
Sleep 4s
Escape
Sleep 1s

# ── Services tab (4): redis (just installed) is registered but stopped ──
# 's' starts the selected service — its status marker flips to running.
Type "4"
Sleep 3s
Type "s"
Sleep 6s
# 'x' stops it again — the marker flips back to stopped.
Type "x"
Sleep 6s

# ── Doctor tab (5): findings load automatically ──
Type "5"
Sleep 5s

# ── Quit back to the shell ──
Type "q"
Sleep 1500ms
