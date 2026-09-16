# claude-cleanup

A Claude Code skill, slash command and hook that keep `/tmp` from filling up mid-session.

On most desktop Linux installs `/tmp` is a tmpfs sized well under the root filesystem. A long Claude Code session — browser profiles, screenshots, Playwright runs, trashed files — can fill it, and once it is full, writes anywhere under `/tmp` fail with `ENOSPC` and tools start breaking in ways that look like anything but a disk problem. This package notices that before you do, and clears out what is safe to clear.

> **Platform support:** developed and tested on Linux only. The macOS code paths (`lsof` instead of `/proc`, BSD-flavoured `find`/`readlink`, `/tmp` as a symlink to `/private/tmp`) are written and reviewed but **have never been run on a Mac**. Treat macOS as untested — start with `mise run test`, then `--dry-run`, before letting the hook near a real `/tmp`.

## What's in here

| Path | Installs to | What it is |
| --- | --- | --- |
| `skills/tmp-cleanup.md` | `~/.claude/skills/` | The skill: when to clean, how to read the output, what the safety rules are |
| `skills/tmp-cleanup-impl.py` | `~/.claude/skills/` | The cleaner itself — no dependencies beyond Python 3 |
| `skills/tmp-cleanup-hook.sh` | `~/.claude/skills/` | Debounce fast path, so the hook rarely pays for a Python start |
| `commands/tmp-cleanup.md` | `~/.claude/commands/` | The `/tmp-cleanup` slash command |
| `hooks/pretooluse.json` | merged into `~/.claude/settings.json` | The `PreToolUse` hook entry that makes it automatic |

## Install

```bash
mise run install:copy      # independent copies in ~/.claude
mise run install:symlink   # symlinks back to this repo, so edits here go live
```

Both place the four files and register the hook. Both are idempotent — re-running reports `unchanged` rather than churning your config, and an already-registered hook that has drifted from `hooks/pretooluse.json` is *replaced* rather than duplicated. Anything already sitting at a destination is moved to `<name>.bak-<timestamp>` rather than clobbered, and `settings.json` is backed up the same way before the hook is merged in.

Pick `copy` if you want the install to survive this repo moving or disappearing. Pick `symlink` if you intend to keep editing the skill.

Then open `/hooks` in Claude Code once, or restart it — hooks are read at session start, so a freshly registered one won't fire until then.

```bash
mise run check       # what's installed, does it match the repo, does the hook still fire
mise run test        # functional test against a throwaway /tmp built from fixtures
mise run uninstall   # take it all back out
```

`mise run install:hook` and `mise run hook:status` manage just the `settings.json` entry, if you want the files without the automation or vice versa.

---

## How it works, exactly

### 1. The hook fires, and almost always does nothing

The `PreToolUse` entry runs before every `Bash`, `Write` and `Edit` call. That is a *lot* of invocations, so the common path is built to cost as close to nothing as possible.

`settings.json` calls `tmp-cleanup-hook.sh`, not Python. The wrapper's only job is to check a timestamp:

```
~/.cache/claude/last-run.timestamp
```

If that file was touched within the debounce window (**5 minutes** by default), the wrapper exits immediately. Python is never started. This matters more than it sounds: a bare `python3` start costs ~120 ms on this machine even to do nothing at all, and the wrapper's `find -mmin` check costs ~2 ms. Measured end to end, a debounced call is **9.8 ms** against **122 ms** for the unguarded version.

If the window *has* expired, the wrapper `exec`s the Python script, which re-checks the same window itself and re-stamps the file. The debounce therefore holds no matter how the cleaner is invoked — the wrapper is an optimisation, not the mechanism.

A manual run (`/tmp-cleanup`, or running the script yourself) is never debounced. You asked explicitly; it acts.

### 2. Python checks whether there is a problem

One `statvfs()` on `/tmp`. If free space is above **both** thresholds — 15% *and* 512 MiB — it returns immediately and the tool call proceeds untouched. Nothing is scanned, nothing is logged.

### 3. Only if space is low: work out what is safe to remove

This is the part that costs real time, and it only ever runs when `/tmp` is actually tight.

**Build the set of open paths.** On Linux, walk `/proc/*/fd` and `/proc/*/cwd` and record every top-level `/tmp` entry anything currently has open. On macOS there is no `/proc`, so it shells out to `lsof -F n -w -n -P` and parses the same information out of that. Either way the walk is time-boxed to **3 seconds** — a single runaway process can hold tens of thousands of fds, and on this machine a leaked `trash-put` with 79,664 open descriptors was doing exactly that. If the walk doesn't finish, "not open" is no longer a fact the cleaner can rely on, so instead of guessing it raises the age floor to **24 hours** and carries on conservatively.

**Classify every entry directly under `/tmp`.** Not recursively — only the top level. Each entry is either *eligible* or *kept with a reason*.

**Sweep oldest first** until free space is back above **35%**, then stop. It does not delete everything it could; it deletes as little as gets you out of trouble.

**Log it.** Every removal is appended to `~/.cache/claude/tmp-cleanup.log` with a timestamp and size.

**Report.** The hook returns a `systemMessage` telling you what went, how much came back, and — if space is *still* tight — the largest entries it deliberately left alone, with the reason for each.

## What it actually cleans up

An entry directly under `/tmp` is removed only when **every one** of these holds:

| Rule | Why |
| --- | --- |
| Owned by the current uid | Never touches another user's or root's files |
| Name doesn't match a protected pattern | See the list below |
| Not a socket or fifo | These are endpoints, not garbage — deleting one breaks a live connection |
| Not held open by any visible process | A running Chrome profile, a build's scratch dir, an open database |
| Not the current session's `$TMPDIR` | Don't saw off the branch |
| Untouched for at least the age floor | mtime, atime *and* ctime, recursively for directories |

The age floor is **30 minutes** for the automatic hook and **60 minutes** for a manual run, overridable with `--min-age`. Directories are judged by the newest timestamp anywhere inside them (bounded at 20,000 entries), so a directory holding one recently-written file is young even if the directory itself is old.

**Protected name patterns**, never removed regardless of age:

```
.X*-unix  .ICE-unix  .font-unix  .Test-unix  .XIM-unix  .x*-lock
systemd-private-*  snap-private-tmp  snap.*
ssh-*  gpg-*  dbus-*  pulse-*  .esd-*  tmux-*
.wayland-*  .mutter-*  runtime-*  krb5cc_*
*.sock  *.socket  *.pid  *.lock
com.apple.*  .keystone_install_lock*  powerlog        (macOS)
.Trash-*  .Trash                                       (needs --trash)
```

So in practice, what *does* get removed is the ordinary debris: stale screenshot and scratch files, finished Playwright and browser profile directories nothing has open any more, dead log files, abandoned build scratch space, `*.png` and `*.json` a previous session dropped and forgot.

**The desktop trash is never touched automatically.** On a machine where `/tmp` is a tmpfs, deleting a file in a file manager can move it to `/tmp/.Trash-$UID` — which means "deleting" a large file *doesn't free any RAM*, it just relabels it. That is frequently the real reason `/tmp` is full, and the cleaner will tell you so, but emptying it is a decision with user-visible consequences, so it requires an explicit `--trash`.

## Manual use

```bash
~/.claude/skills/tmp-cleanup-impl.py --dry-run     # show what would go
~/.claude/skills/tmp-cleanup-impl.py               # delete entries idle >60m
~/.claude/skills/tmp-cleanup-impl.py --min-age 10  # be more aggressive
~/.claude/skills/tmp-cleanup-impl.py --trash       # also empty /tmp/.Trash-*
~/.claude/skills/tmp-cleanup-impl.py --json        # machine-readable
```

Or `/tmp-cleanup` inside Claude Code, which dry-runs first and asks before deleting.

Both modes finish by listing the **largest entries they left alone, with the reason** — which is usually the actual answer when `/tmp` is full:

```
largest entries left alone (1.7G kept in total):
     1.1G  /tmp/.Trash-1000  — in use by a running process
   537.8M  /tmp/icon         — in use by a running process
```

A multi-gigabyte directory marked *in use by a running process* means no amount of cleaning will help; something is sitting on it. `ls /proc/<pid>/fd | wc -l` will usually find the culprit.

## Tuning

All optional, all environment variables:

| Variable | Default | Effect |
| --- | --- | --- |
| `TMP_CLEANUP_DEBOUNCE` | `300` | Seconds between hook runs. Read by both the wrapper and the script. `0` disables. |
| `TMP_CLEANUP_LOW_PCT` | `15` | Free-space percentage below which the hook acts |
| `TMP_CLEANUP_LOW_MB` | `512` | Absolute free-space floor, in MiB |
| `TMP_CLEANUP_TARGET_PCT` | `35` | Sweep stops once this much is free again |
| `TMP_CLEANUP_HOOK_MIN_AGE` | `30` | Age floor in minutes for automatic runs |
| `TMP_CLEANUP_DIR` | `/tmp` | What to clean — the test suite points this at a fixture directory |
| `CLAUDE_DIR` | `~/.claude` | Honoured by every script here, so the whole install can be exercised against a throwaway directory |

## Requirements

Python 3 and `jq` (for the `settings.json` merge). Linux, or macOS with `lsof` — see the platform caveat at the top.
