#!/usr/bin/env bash
#
# Add or remove the tmp-cleanup PreToolUse entry in Claude Code's settings.json.
#
#   scripts/hook.sh install
#   scripts/hook.sh remove
#   scripts/hook.sh status
#
# Idempotent in both directions, backs settings.json up before writing, and
# never leaves a half-written file behind — a malformed settings.json silently
# disables every setting in it.

set -eEuo pipefail

ACTION="${1:-status}"
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
ENTRY="$REPO/hooks/pretooluse.json"
MARKER="tmp-cleanup-impl"

command -v jq >/dev/null || {
	echo "hook.sh: jq is required" >&2
	exit 1
}

# Any PreToolUse group whose command mentions the impl script is ours.
IS_OURS='([.hooks[]?.command? // ""] | map(test("'"$MARKER"'")) | any)'

present() {
	[[ -f "$SETTINGS" ]] || return 1
	[[ "$(jq "[.hooks.PreToolUse[]? | select($IS_OURS)] | length" "$SETTINGS")" -gt 0 ]]
}

write() { # write() <jq-program> [jq-args...]
	local tmp
	tmp="$(mktemp "$SETTINGS.XXXXXX")"
	trap 'rm -f -- "$tmp"' RETURN
	jq "${@:2}" "$1" "$SETTINGS" >"$tmp"
	jq -e . "$tmp" >/dev/null # refuse to install a broken settings file
	cp -- "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
	mv -- "$tmp" "$SETTINGS"
	trap - RETURN
}

case "$ACTION" in
install)
	mkdir -p "$CLAUDE_DIR"
	[[ -f "$SETTINGS" ]] || echo '{}' >"$SETTINGS"
	if present; then
		echo "  hook       already registered in $SETTINGS"
		exit 0
	fi
	write '.hooks //= {} | .hooks.PreToolUse //= [] | .hooks.PreToolUse += [$entry]' \
		--argjson entry "$(cat "$ENTRY")"
	echo "  hook       registered in $SETTINGS (backup alongside it)"
	;;
remove)
	if ! present; then
		echo "  hook       not present in $SETTINGS"
		exit 0
	fi
	write ".hooks.PreToolUse |= [.[]? | select($IS_OURS | not)]"
	echo "  hook       removed from $SETTINGS (backup alongside it)"
	;;
status)
	if present; then
		echo "registered:"
		jq ".hooks.PreToolUse[]? | select($IS_OURS)" "$SETTINGS"
	else
		echo "not registered in $SETTINGS"
		exit 1
	fi
	;;
*)
	echo "usage: ${0##*/} install|remove|status" >&2
	exit 2
	;;
esac
