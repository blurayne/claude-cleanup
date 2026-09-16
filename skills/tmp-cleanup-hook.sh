#!/bin/sh
#
# PreToolUse fast path for tmp-cleanup.
#
# This runs before every Bash/Write/Edit call, so the common case has to be
# free. Starting Python costs ~120ms even to do nothing, so the debounce is
# checked here first with `find`, which costs about 2ms. Python is only spawned
# when the window has actually expired; it then re-checks the same window, so
# the debounce holds no matter how the script is invoked.
#
# `find -mmin` is POSIX-portable and works on both GNU and BSD/macOS find
# (unlike -newermt, which is GNU-only).

STAMP="$HOME/.cache/claude/last-run.timestamp"
IMPL="$(dirname "$0")/tmp-cleanup-impl.py"

# Seconds -> whole minutes, rounded down, floor of 1 so a sub-minute window
# still debounces back-to-back calls rather than spawning Python every time.
SECONDS_WINDOW="${TMP_CLEANUP_DEBOUNCE:-300}"
MINUTES_WINDOW=$((SECONDS_WINDOW / 60))
[ "$MINUTES_WINDOW" -lt 1 ] && MINUTES_WINDOW=1

if [ "$SECONDS_WINDOW" -gt 0 ] &&
	[ -n "$(find "$STAMP" -mmin "-$MINUTES_WINDOW" 2>/dev/null)" ]; then
	exit 0 # ran recently, nothing to do
fi

command -v python3 >/dev/null || exit 0
exec python3 "$IMPL" --hook
