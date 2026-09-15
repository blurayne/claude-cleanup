#!/usr/bin/env bash
#
# Report what is installed where, and prove the hook command still runs.

set -eEuo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
rc=0

echo "claude dir: $CLAUDE_DIR"
for rel in skills/tmp-cleanup.md skills/tmp-cleanup-impl.py commands/tmp-cleanup.md; do
	dst="$CLAUDE_DIR/$rel"
	if [[ -L "$dst" ]]; then
		echo "  symlink    $rel -> $(readlink -- "$dst")"
	elif [[ -f "$dst" ]]; then
		if cmp -s "$REPO/$rel" "$dst"; then
			echo "  copy       $rel (matches repo)"
		else
			echo "  copy       $rel (DIFFERS from repo)"
			rc=1
		fi
	else
		echo "  missing    $rel"
		rc=1
	fi
done

"$REPO/scripts/hook.sh" status >/dev/null 2>&1 &&
	echo "  hook       registered" ||
	{
		echo "  hook       NOT registered"
		rc=1
	}

echo
echo "hook dry-fire (expect no output and exit 0 when /tmp has room):"
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' |
	python3 "$CLAUDE_DIR/skills/tmp-cleanup-impl.py" --hook
echo "  exit=$?"

echo
echo "current /tmp state:"
python3 "$CLAUDE_DIR/skills/tmp-cleanup-impl.py" --dry-run --min-age 60 | head -1

exit "$rc"
