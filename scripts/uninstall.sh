#!/usr/bin/env bash
#
# Remove everything install.sh put in place: the two skill files, the command,
# and the PreToolUse hook entry. Backups (*.bak-*) are left where they are.

set -eEuo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"

TARGETS=(
	"skills/tmp-cleanup.md"
	"skills/tmp-cleanup-impl.py"
	"skills/tmp-cleanup-hook.sh"
	"commands/tmp-cleanup.md"
)

echo "uninstalling tmp-cleanup from $CLAUDE_DIR"
for rel in "${TARGETS[@]}"; do
	dst="$CLAUDE_DIR/$rel"
	if [[ -e "$dst" || -L "$dst" ]]; then
		rm -- "$dst"
		echo "  removed    $dst"
	else
		echo "  absent     $dst"
	fi
done

"$REPO/scripts/hook.sh" remove

echo
echo "Left in place on purpose:"
echo "  ~/.cache/claude/tmp-cleanup.log      audit log"
echo "  ~/.cache/claude/last-run.timestamp   debounce clock"
if "$REPO/scripts/tmpfiles.sh" status 2>/dev/null | grep -q ', ours:\|claude-cleanup'; then
	echo "  the OS-level /tmp aging policy — it needs root:"
	echo "      mise run uninstall:tmpfiles"
fi
