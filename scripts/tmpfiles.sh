#!/usr/bin/env bash
#
# Tighten the OS's own periodic /tmp cleaner, which handles routine aging so the
# PreToolUse hook rarely has to fire.
#
#   scripts/tmpfiles.sh install [AGE]   # AGE defaults to 1d (Linux) / 1 day (macOS)
#   scripts/tmpfiles.sh remove
#   scripts/tmpfiles.sh status
#
# Linux: writes /etc/tmpfiles.d/tmp.conf, which masks the distro's
#        /usr/lib/tmpfiles.d/tmp.conf by filename. systemd-tmpfiles-clean.timer
#        (already running on any systemd box) then enforces the shorter age.
#
# macOS: appends a managed block to /etc/periodic.conf enabling the stock
#        /etc/periodic/daily/110.clean-tmps script, which is shipped disabled.
#        UNTESTED — see the platform caveat in README.md.
#
# Both paths need root and both are idempotent and reversible.

set -eEuo pipefail

ACTION="${1:-status}"
AGE="${2:-${TMP_CLEANUP_TMPFILES_AGE:-1}}"
AGE="${AGE%d}" # accept "1d" or "1"

BEGIN="# >>> claude-cleanup >>>"
END="# <<< claude-cleanup <<<"

sudo=()
needs_root() { # the overridden targets used by the tests are ours already
	case "${TMPFILES_TARGET:-}${PERIODIC_CONF:-}" in "") return 0 ;; *) return 1 ;; esac
}
if [[ $EUID -ne 0 ]] && needs_root; then
	command -v sudo >/dev/null || {
		echo "tmpfiles: needs root and sudo is not installed" >&2
		exit 1
	}
	sudo=(sudo)
fi

# Write stdin to a root-owned path without needing a root-owned temp file.
write_root() { "${sudo[@]}" tee -- "$1" >/dev/null; }

backup() {
	[[ -f "$1" ]] || return 0
	"${sudo[@]}" cp -- "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)"
	echo "  backed up  $1.bak-*"
}

# ---------------------------------------------------------------- Linux

# Overridable so the install path can be exercised without root.
LINUX_TARGET="${TMPFILES_TARGET:-/etc/tmpfiles.d/tmp.conf}"
LINUX_VENDOR="${TMPFILES_VENDOR:-/usr/lib/tmpfiles.d/tmp.conf}"

linux_install() {
	if [[ -f "$LINUX_TARGET" ]] && ! grep -qF "$BEGIN" "$LINUX_TARGET"; then
		echo "tmpfiles: $LINUX_TARGET exists and isn't ours — refusing to clobber it." >&2
		echo "          Edit it by hand, or move it aside and re-run." >&2
		exit 1
	fi
	backup "$LINUX_TARGET"
	{
		echo "$BEGIN"
		echo "# Masks $LINUX_VENDOR by filename (see tmpfiles.d(5))."
		echo "# The vendor policy is 30d, which never fires on a tmpfs — nothing"
		echo "# survives a reboot long enough to reach that age."
		echo "# Remove with: mise run uninstall:tmpfiles"
		echo "D /tmp 1777 root root ${AGE}d"
		echo "$END"
	} | write_root "$LINUX_TARGET"
	echo "  written    $LINUX_TARGET (D /tmp 1777 root root ${AGE}d)"
	echo "  active     on the next systemd-tmpfiles-clean.timer run:"
	systemctl list-timers --all systemd-tmpfiles-clean.timer --no-pager 2>/dev/null |
		sed -n '2p' | sed 's/^/             /'
}

linux_remove() {
	if [[ ! -f "$LINUX_TARGET" ]]; then
		echo "  absent     $LINUX_TARGET"
		return 0
	fi
	if ! grep -qF "$BEGIN" "$LINUX_TARGET"; then
		echo "  kept       $LINUX_TARGET is not ours — leaving it alone"
		return 0
	fi
	"${sudo[@]}" rm -- "$LINUX_TARGET"
	echo "  removed    $LINUX_TARGET (vendor policy in $LINUX_VENDOR applies again)"
}

linux_status() {
	echo "vendor policy ($LINUX_VENDOR):"
	grep -E '^[a-zA-Z] +/tmp' "$LINUX_VENDOR" 2>/dev/null | sed 's/^/  /' || echo "  (none)"
	if [[ -f "$LINUX_TARGET" ]]; then
		echo "override ($LINUX_TARGET)$(grep -qF "$BEGIN" "$LINUX_TARGET" && echo ", ours:" || echo ", NOT ours:")"
		grep -E '^[a-zA-Z] +/tmp' "$LINUX_TARGET" | sed 's/^/  /'
	else
		echo "override ($LINUX_TARGET): none — the vendor policy is in effect"
	fi
	echo "cleaner timer:"
	systemctl list-timers --all systemd-tmpfiles-clean.timer --no-pager 2>/dev/null |
		sed -n '1,2p' | sed 's/^/  /'
	echo "exclusions other packages registered for /tmp:"
	grep -rhE '^[xX] +/tmp' /usr/lib/tmpfiles.d/ /etc/tmpfiles.d/ /run/tmpfiles.d/ 2>/dev/null |
		sed 's/^/  /' || echo "  (none)"
}

# ---------------------------------------------------------------- macOS

MAC_TARGET="${PERIODIC_CONF:-/etc/periodic.conf}"

mac_install() {
	backup "$MAC_TARGET"
	# Strip any previous block, then append a fresh one.
	local body=""
	[[ -f "$MAC_TARGET" ]] && body="$(mac_strip)"
	{
		[[ -n "$body" ]] && printf '%s\n' "$body"
		echo "$BEGIN"
		echo "# Enables the stock /etc/periodic/daily/110.clean-tmps, which macOS"
		echo "# ships disabled. Defaults live in /etc/defaults/periodic.conf."
		echo "# Remove with: mise run uninstall:tmpfiles"
		echo 'daily_clean_tmps_enable="YES"'
		echo 'daily_clean_tmps_dirs="/tmp"'
		echo "daily_clean_tmps_days=\"${AGE}\""
		echo 'daily_clean_tmps_ignore=".X11-unix .ICE-unix .font-unix .XIM-unix .Trash .Trash-* quota.user quota.group"'
		echo 'daily_clean_tmps_verbose="NO"'
		echo "$END"
	} | write_root "$MAC_TARGET"
	echo "  written    $MAC_TARGET (daily_clean_tmps_days=$AGE)"
	echo "  active     on the next com.apple.periodic-daily run"
	echo "  NOTE       untested on macOS; verify with: sudo periodic daily"
}

mac_strip() { # print $MAC_TARGET with our block removed
	sed "/^${BEGIN}\$/,/^${END}\$/d" "$MAC_TARGET"
}

mac_remove() {
	if [[ ! -f "$MAC_TARGET" ]] || ! grep -qF "$BEGIN" "$MAC_TARGET"; then
		echo "  absent     no claude-cleanup block in $MAC_TARGET"
		return 0
	fi
	backup "$MAC_TARGET"
	# Read it all in BEFORE opening the target for writing: piping mac_strip
	# straight into tee lets tee truncate the file out from under sed, which
	# silently empties it.
	local body
	body="$(mac_strip)"
	printf '%s\n' "$body" | write_root "$MAC_TARGET"
	echo "  removed    claude-cleanup block from $MAC_TARGET"
}

mac_status() {
	echo "defaults (/etc/defaults/periodic.conf):"
	grep -E '^daily_clean_tmps' /etc/defaults/periodic.conf 2>/dev/null | sed 's/^/  /' ||
		echo "  (none found)"
	echo "overrides ($MAC_TARGET):"
	grep -E '^daily_clean_tmps' "$MAC_TARGET" 2>/dev/null | sed 's/^/  /' ||
		echo "  (none — the stock cleaner is disabled)"
	echo "periodic job:"
	launchctl list 2>/dev/null | grep periodic-daily | sed 's/^/  /' || echo "  (not listed)"
}

# ---------------------------------------------------------------- dispatch

# TMPFILES_PLATFORM lets the tests drive the macOS branch from a Linux box.
case "${TMPFILES_PLATFORM:-$(uname -s)}" in
Linux) install=linux_install remove=linux_remove status=linux_status ;;
Darwin) install=mac_install remove=mac_remove status=mac_status ;;
*)
	echo "tmpfiles: unsupported platform $(uname -s)" >&2
	exit 1
	;;
esac

case "$ACTION" in
install) "$install" ;;
remove) "$remove" ;;
status) "$status" ;;
*)
	echo "usage: ${0##*/} install [AGE]|remove|status" >&2
	exit 2
	;;
esac
