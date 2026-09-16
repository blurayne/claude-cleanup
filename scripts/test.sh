#!/usr/bin/env bash
#
# Functional test. Builds a fake /tmp full of fixtures, points the cleaner at it
# via TMP_CLEANUP_DIR, and asserts exactly which ones survive.
#
# The age rule is neutralised (TMP_CLEANUP_HOOK_MIN_AGE=-1) on purpose: `touch`
# cannot backdate ctime, so freshly built fixtures always look young and nothing
# would ever be swept. Age is covered separately by the last case.

set -eEuo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IMPL="$REPO/skills/tmp-cleanup-impl.py"
failures=0

ok() { printf '  ok      %s\n' "$1"; }
bad() {
	printf '  FAIL    %s\n' "$1"
	failures=$((failures + 1))
}
gone() { [[ ! -e "$1" ]] && ok "removed  ${1##*/}" || bad "should have been removed: ${1##*/}"; }
kept() { [[ -e "$1" ]] && ok "kept     ${1##*/}" || bad "should have survived: ${1##*/}"; }

T="$(mktemp -d /tmp/tmp-cleanup-test.XXXXXX)"
FAKE_HOME="$(mktemp -d /tmp/tmp-cleanup-home.XXXXXX)"
mkdir -p "$FAKE_HOME/.cache/claude"
cleanup() {
	[[ -n "${SLEEP_PID:-}" ]] && kill "$SLEEP_PID" 2>/dev/null
	rm -rf -- "$T" "$FAKE_HOME"
}
trap cleanup EXIT

mkdir -p "$T/stale-dir" "$T/.X11-unix" "$T/.Trash-1000"
head -c 200000 /dev/urandom >"$T/stale-dir/blob"
head -c 100000 /dev/urandom >"$T/stale-file"
head -c 1000 /dev/urandom >"$T/open-file"
python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$T/live.sock"

# Hold a real fd on open-file for the duration of the sweep.
sleep 30 3<"$T/open-file" &
SLEEP_PID=$!
sleep 0.3

echo "sweep with the age rule neutralised:"
echo '{"tool_name":"Bash"}' |
	TMP_CLEANUP_DIR="$T" \
		TMP_CLEANUP_LOW_PCT=100 \
		TMP_CLEANUP_TARGET_PCT=100 \
		TMP_CLEANUP_HOOK_MIN_AGE=-1 \
		python3 "$IMPL" --hook --debounce 0 >/dev/null

gone "$T/stale-dir"
gone "$T/stale-file"
kept "$T/.X11-unix"    # protected name
kept "$T/.Trash-1000"  # desktop trash, needs --trash
kept "$T/live.sock"    # socket
kept "$T/open-file"    # held open by a live process

echo "age rule on its own:"
head -c 1000 /dev/urandom >"$T/young-file"
TMP_CLEANUP_DIR="$T" python3 "$IMPL" --min-age 60 >/dev/null
kept "$T/young-file"

echo "hook stays silent when there is room:"
out="$(echo '{}' | TMP_CLEANUP_DIR="$T" TMP_CLEANUP_LOW_PCT=0 TMP_CLEANUP_LOW_MB=0 \
	python3 "$IMPL" --hook --debounce 0)"
[[ -z "$out" ]] && ok "no output" || bad "expected silence, got: $out"

# The debounce clock is a real file under $HOME, so borrow one rather than
# stamping the user's own. It must live OUTSIDE $T — anything inside is fair
# game for the very sweep we're testing, stamp included.
echo "debounce:"
HOME_BAK="$HOME"
export HOME="$FAKE_HOME"
STAMP="$HOME/.cache/claude/last-run.timestamp"

mkdir "$T/sweepable"
hook() { # hook <extra args...>
	echo '{}' | TMP_CLEANUP_DIR="$T" TMP_CLEANUP_LOW_PCT=100 TMP_CLEANUP_TARGET_PCT=100 \
		TMP_CLEANUP_HOOK_MIN_AGE=-1 python3 "$IMPL" --hook "$@"
}

first="$(hook --debounce 300)"
[[ -n "$first" ]] && ok "first call acts" || bad "first call should have acted"
[[ -f "$STAMP" ]] && ok "writes the stamp" || bad "no stamp at $STAMP"

mkdir "$T/sweepable2"
second="$(hook --debounce 300)"
[[ -z "$second" ]] && ok "second call within the window is silent" ||
	bad "second call should have been debounced, got: $second"
[[ -e "$T/sweepable2" ]] && ok "debounced call deletes nothing" ||
	bad "debounced call still swept"

third="$(hook --debounce 0)"
[[ -n "$third" ]] && ok "--debounce 0 bypasses the window" ||
	bad "--debounce 0 should have acted"

# The wrapper's whole point is not spawning Python, which produces no output
# either way — so assert on the stamp instead. A short-circuit leaves its mtime
# untouched; a pass-through makes Python rewrite it.
echo "shell fast path:"
touch -t 200001010000 "$STAMP"
before="$(ls -l "$STAMP")"
TMP_CLEANUP_DEBOUNCE=300 TMP_CLEANUP_DIR="$T" sh "$REPO/skills/tmp-cleanup-hook.sh" >/dev/null 2>&1
[[ "$(ls -l "$STAMP")" != "$before" ]] && ok "stale stamp: wrapper runs the cleaner" ||
	bad "wrapper should have passed through on a stale stamp"

before="$(ls -l "$STAMP")"
TMP_CLEANUP_DEBOUNCE=300 TMP_CLEANUP_DIR="$T" sh "$REPO/skills/tmp-cleanup-hook.sh" >/dev/null 2>&1
[[ "$(ls -l "$STAMP")" == "$before" ]] && ok "fresh stamp: wrapper short-circuits" ||
	bad "wrapper should have short-circuited on a fresh stamp"

export HOME="$HOME_BAK"

echo
if [[ "$failures" -eq 0 ]]; then
	echo "all checks passed"
else
	echo "$failures check(s) failed"
	exit 1
fi
