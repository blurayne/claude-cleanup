#!/usr/bin/env bash
#
# Install the tmp-cleanup skill, command and hook into a Claude Code config dir.
#
#   scripts/install.sh copy       # place independent copies
#   scripts/install.sh symlink    # symlink back to this repo (edits stay live)
#
# Honours CLAUDE_DIR (default ~/.claude) so the whole thing can be exercised
# against a throwaway directory.

set -eEuo pipefail

MODE="${1:-}"
case "$MODE" in
copy | symlink) ;;
*)
	echo "usage: ${0##*/} copy|symlink" >&2
	exit 2
	;;
esac

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
STAMP="$(date +%Y%m%d-%H%M%S)"

# repo-relative source : destination under $CLAUDE_DIR
FILES=(
	"skills/tmp-cleanup.md:skills/tmp-cleanup.md"
	"skills/tmp-cleanup-impl.py:skills/tmp-cleanup-impl.py"
	"skills/tmp-cleanup-hook.sh:skills/tmp-cleanup-hook.sh"
	"commands/tmp-cleanup.md:commands/tmp-cleanup.md"
)

place() {
	local src="$REPO/$1" dst="$CLAUDE_DIR/$2"
	mkdir -p "$(dirname "$dst")"

	# Already exactly what we want? Say so and move on — installing twice is a
	# no-op, which is what makes this safe to wire into other tasks.
	if [[ "$MODE" == symlink && "$(readlink "$dst" 2>/dev/null)" == "$src" ]]; then
		echo "  unchanged  $dst -> $src"
		return
	fi
	if [[ "$MODE" == copy && -f "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"; then
		echo "  unchanged  $dst"
		return
	fi

	# Anything else already sitting there is somebody's work. Keep it.
	if [[ -e "$dst" || -L "$dst" ]]; then
		mv -- "$dst" "$dst.bak-$STAMP"
		echo "  backed up  $dst.bak-$STAMP"
	fi

	if [[ "$MODE" == symlink ]]; then
		ln -s -- "$src" "$dst"
		echo "  linked     $dst -> $src"
	else
		cp -- "$src" "$dst"
		echo "  copied     $dst"
	fi
	case "$dst" in *.py | *.sh) chmod +x "$dst" ;; esac
	return 0
}

echo "installing tmp-cleanup ($MODE) into $CLAUDE_DIR"
for entry in "${FILES[@]}"; do
	place "${entry%%:*}" "${entry#*:}"
done

"$REPO/scripts/hook.sh" install

echo
echo "Done. Open /hooks in Claude Code (or restart it) to load the new hook."
echo "Verify with: mise run check"
