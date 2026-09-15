# claude-cleanup

A Claude Code skill, slash command and hook that keep `/tmp` from filling up mid-session.

On most desktop Linux installs `/tmp` is a tmpfs sized well under the root filesystem. A long Claude Code session — browser profiles, screenshots, Playwright runs, trashed files — can fill it, and once it is full, writes anywhere under `/tmp` fail with `ENOSPC` and tools start breaking in ways that look like anything but a disk problem. This package notices that before you do, and clears out what is safe to clear.

## What's in here

| Path | Installs to | What it is |
| --- | --- | --- |
| `skills/tmp-cleanup.md` | `~/.claude/skills/` | The skill: when to clean, how to read the output, what the safety rules are |
| `skills/tmp-cleanup-impl.py` | `~/.claude/skills/` | The cleaner itself — no dependencies beyond Python 3 |
| `commands/tmp-cleanup.md` | `~/.claude/commands/` | The `/tmp-cleanup` slash command |
| `hooks/pretooluse.json` | merged into `~/.claude/settings.json` | The `PreToolUse` hook entry that makes it automatic |

## Install

```bash
mise run install:copy      # independent copies in ~/.claude
mise run install:symlink   # symlinks back to this repo, so edits here go live
```

Both place the three files and register the hook. Both are idempotent — re-running reports `unchanged` rather than churning your config. Anything already sitting at a destination is moved to `<name>.bak-<timestamp>` rather than clobbered, and `settings.json` is backed up the same way before the hook is merged in.

Pick `copy` if you want the install to survive this repo moving or disappearing. Pick `symlink` if you intend to keep editing the skill.

Then open `/hooks` in Claude Code once, or restart it — hooks are read at session start, so a freshly registered one won't fire until then.

```bash
mise run check       # what's installed, does it match the repo, does the hook still fire
mise run test        # functional test against a throwaway /tmp built from fixtures
mise run uninstall   # take it all back out
```

`mise run install:hook` and `mise run hook:status` manage just the `settings.json` entry, if you want the files without the automation or vice versa.

## How the automatic mode behaves

The hook runs before every `Bash`, `Write` and `Edit` call, so it is built to cost nothing in the common case: one `statvfs()`, then return. It only does real work when `/tmp` has less than **15% or 512 MiB** free. Then it deletes stale entries oldest-first until **35%** is free again and reports what it did as a system message. Errors exit 0 — a cleanup problem must never block a tool call.

It is deliberately timid. It never empties the desktop trash, and never touches anything under 30 minutes old.

## What it will never delete

An entry directly under `/tmp` is removed only when *every* one of these holds:

- owned by the current uid
- the name doesn't match a protected pattern (`.X11-unix`, `.ICE-unix`, `systemd-private-*`, `snap-private-tmp`, `ssh-*`, `gpg-*`, `dbus-*`, `pulse-*`, `tmux-*`, `*.sock`, `*.pid`, `.Trash-*`, …)
- it isn't a socket or fifo
- no visible process holds it open — checked against `/proc/*/fd` and `/proc/*/cwd`, so a live Chrome profile or a running build's scratch directory is safe
- it isn't the current session's `$TMPDIR`
- nothing has touched it (mtime/atime/ctime, recursively for directories) within the age floor

One runaway process can hold tens of thousands of fds, so the `/proc` walk is time-boxed at 3 seconds. If it doesn't finish, "not open" is no longer a fact the cleaner can rely on — so the age floor jumps to 24 hours automatically rather than guessing.

Every deletion is appended to `~/.cache/claude/tmp-cleanup.log`.

## Manual use

```bash
~/.claude/skills/tmp-cleanup-impl.py --dry-run     # show what would go
~/.claude/skills/tmp-cleanup-impl.py               # delete entries idle >60m
~/.claude/skills/tmp-cleanup-impl.py --min-age 10  # be more aggressive
~/.claude/skills/tmp-cleanup-impl.py --trash       # also empty /tmp/.Trash-*
~/.claude/skills/tmp-cleanup-impl.py --json        # machine-readable
```

Or `/tmp-cleanup` inside Claude Code, which dry-runs first and asks before deleting.

Both modes finish by listing the **largest entries they left alone, with the reason** — which is usually the actual answer when `/tmp` is full. A multi-gigabyte directory marked *in use by a running process* means no amount of cleaning will help; something is sitting on it. A big `.Trash-*` means the desktop trash landed on the tmpfs and needs `--trash`.

## Tuning

All optional, all environment variables: `TMP_CLEANUP_LOW_PCT` (15), `TMP_CLEANUP_LOW_MB` (512), `TMP_CLEANUP_TARGET_PCT` (35), `TMP_CLEANUP_HOOK_MIN_AGE` (30 minutes), `TMP_CLEANUP_DIR` (`/tmp`).

`CLAUDE_DIR` (default `~/.claude`) is honoured by every script here, which is how the test suite installs into a throwaway directory.

## Requirements

Python 3, `jq` (for the `settings.json` merge), and Linux — the open-file check reads `/proc`.
