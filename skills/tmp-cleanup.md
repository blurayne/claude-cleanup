---
name: tmp-cleanup
description: Reclaim space on /tmp when it fills up during a session. Use when a tool fails with "No space left on device", when /tmp or a tmpfs is reported full or nearly full, or when the user asks to clean up, free, or empty /tmp. Also the manual counterpart to the PreToolUse hook that auto-cleans /tmp when free space drops below the threshold.
---

# /tmp cleanup

On most desktop Linux installs `/tmp` is a **tmpfs** — it lives in RAM, nothing on it survives a reboot, and it is far smaller than the root filesystem. A single long session (browser profiles, screenshots, Playwright runs, trashed files) can fill it. When it fills, writes anywhere in `/tmp` start failing with `ENOSPC` and tools break in confusing ways.

Implementation: `~/.claude/skills/tmp-cleanup-impl.py`. Audit log: `~/.cache/claude/tmp-cleanup.log`.

## Automatic mode

A `PreToolUse` hook runs `tmp-cleanup-impl.py --hook` before `Bash`/`Write`/`Edit` calls. It does one `statvfs()` and returns immediately unless `/tmp` has less than **15% or 512 MiB** free. Only then does it do real work: it deletes stale entries oldest-first until **35%** is free again, and reports what it did as a system message.

The hook is deliberately timid — it never empties the desktop trash, never touches anything under 30 minutes old, and never blocks the tool call (any error exits 0).

## Manual mode

```bash
~/.claude/skills/tmp-cleanup-impl.py --dry-run     # show what would go
~/.claude/skills/tmp-cleanup-impl.py               # delete entries idle >60m
~/.claude/skills/tmp-cleanup-impl.py --min-age 10  # be more aggressive
~/.claude/skills/tmp-cleanup-impl.py --trash       # also empty /tmp/.Trash-*
~/.claude/skills/tmp-cleanup-impl.py --json        # machine-readable
```

**Always run `--dry-run` first and show the user the list before deleting**, unless they explicitly asked for an immediate cleanup. `--trash` empties the user's desktop trash — never pass it without asking.

## What it will never delete

An entry directly under `/tmp` is removed only when every one of these holds:

- owned by the current uid
- name doesn't match a protected pattern (`.X11-unix`, `.ICE-unix`, `systemd-private-*`, `snap-private-tmp`, `ssh-*`, `gpg-*`, `dbus-*`, `pulse-*`, `tmux-*`, `*.sock`, `*.pid`, `.Trash-*`, …)
- not a socket or fifo
- not held open by any visible process — checked against `/proc/*/fd` and `/proc/*/cwd`, so a live Chrome profile or a running build's scratch dir is safe
- not this session's `$TMPDIR`
- untouched (mtime/atime/ctime, recursively for directories) for at least `--min-age` minutes

If the `/proc` walk can't finish inside its 3 s budget — one runaway process can hold 80k fds — "not open" stops being a fact, so the age floor jumps to 24 h automatically.

## Reading the output

Both modes report the **largest entries that were left alone, with the reason**. That list is usually the real answer when `/tmp` is full:

- `— in use by a running process` on a big directory means a live process (often a Chrome/Playwright profile) is sitting on it. Nothing to clean; close the app or kill the process.
- `— desktop trash (needs --trash)` means `/tmp/.Trash-*` is the hog. Ask the user before emptying it.
- A leaked process holding thousands of fds under `/tmp` will pin everything it touched. `ls /proc/<pid>/fd | wc -l` confirms it; suggest killing it rather than deleting around it.

## Tuning

Environment variables, all optional: `TMP_CLEANUP_LOW_PCT` (15), `TMP_CLEANUP_LOW_MB` (512), `TMP_CLEANUP_TARGET_PCT` (35), `TMP_CLEANUP_HOOK_MIN_AGE` (30 minutes), `TMP_CLEANUP_DIR` (`/tmp`).

For disk usage outside `/tmp`, reach for a whole-filesystem analyzer instead — this skill deliberately only looks one level under `/tmp`.
