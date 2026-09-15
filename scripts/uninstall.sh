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
echo "The audit log at ~/.cache/claude/tmp-cleanup.log was left in place."
