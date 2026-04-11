# malt install demo — generates docs/demo.gif
#
# Render via the wrapper (handles temp prefix + PATH):
#   ./scripts/record-demo.sh
#
# The wrapper exports MALT_PREFIX, MALT_CACHE and prepends zig-out/bin to
# PATH *before* invoking vhs, so this tape contains only the commands the
# viewer should actually see — no setup, no cleanup, no Hide blocks.

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

Type "malt install jq tree ripgrep"
Sleep 400ms
Enter
Sleep 15s

Type "malt list --versions"
Sleep 400ms
Enter
Sleep 3s
