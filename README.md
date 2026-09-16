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
| `scripts/tmpfiles.sh` | writes `/etc/tmpfiles.d/tmp.conf` or `/etc/periodic.conf` | Tightens the OS's own periodic /tmp cleaner (the only root-level piece) |

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

### Every task

| Task | Root? | What it does |
| --- | --- | --- |
| `install:copy` | no | Files as independent copies in `~/.claude`, plus the hook |
| `install:symlink` | no | Same, but symlinked back to this repo so edits go live |
| `install:hook` | no | Just the `settings.json` entry |
| `hook:status` | no | Show the registered hook entry, if any |
| `uninstall` | no | Remove the files and the hook |
| `install:tmpfiles [days]` | **yes** | Tighten the OS periodic cleaner to 1 day (or the given number) |
| `uninstall:tmpfiles` | **yes** | Restore the stock OS policy |
| `tmpfiles:status` | no | Effective OS-level policy, and when its cleaner next runs |
| `check` | no | What's installed, whether it matches the repo, dry-fire the hook |
| `test` | no | 25 assertions against throwaway fixtures — deletes nothing real |
| `clean:dry-run` | no | What a cleanup would remove right now |

`uninstall` deliberately leaves the root-level policy alone; it tells you to run `uninstall:tmpfiles` if one is installed.

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

### The age floor, concretely

The age floor is the single rule people misread, so spelled out:

> **Never delete anything that anything touched in the last N minutes.**

`N` is **30 minutes** for the automatic hook (`TMP_CLEANUP_HOOK_MIN_AGE`, in minutes) and **60 minutes** for a manual run (`--min-age`). The check is one subtraction:

```
cutoff  = now - N minutes
touched = the most recent of the entry's mtime, atime and ctime
          (for a directory: the newest such timestamp of anything inside it)

touched > cutoff  →  KEEP, reason "touched 4m ago"
touched ≤ cutoff  →  eligible, subject to every other rule
```

With the hook's default of 30, on a `/tmp` that is running low:

| Entry | `touched` | Outcome |
| --- | --- | --- |
| `screenshot.png`, written 4 minutes ago | 4m | **kept** — inside the window |
| `pw-profile-xyz/`, last written 45 minutes ago | 45m | eligible |
| `build-scratch/` created 3 days ago, but one file inside written 2 minutes ago | 2m | **kept** — directories inherit the newest timestamp inside them |
| `old.log`, untouched for a week, but a process has it open | 7d | **kept** — a different rule (open fd) catches it |

So the open-fd check and the age floor cover two different dangers. The fd check stops you deleting something *in use right now*; the age floor stops you deleting something a process finished writing a moment ago and is about to reopen, or that a command which already exited will come back for.

Directory walks are bounded at 20,000 entries — past that the directory keeps whatever newest timestamp was found so far, which errs toward *keeping*.

Setting it:

```bash
TMP_CLEANUP_HOOK_MIN_AGE=120   # hook only touches things idle for 2 hours
TMP_CLEANUP_HOOK_MIN_AGE=5     # aggressive; 5 minutes of grace
TMP_CLEANUP_HOOK_MIN_AGE=0     # no age protection at all — anything not
                               # currently open is fair game. Not advised.
```

One automatic override: if the open-file scan could not finish inside its 3-second budget, "not open" is no longer trustworthy, so the floor is raised to **24 hours** regardless of what you set — age becomes the only defence left, so it gets much stronger.

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

---

## Why a hook and not a systemd timer

The obvious objection to this design is that periodic cleanup is what cron and systemd timers are *for*, and that paying ~10ms on every tool call to re-implement a scheduler is silly. Mostly that objection is right. Two things keep the hook, and it is worth being precise about which are real constraints and which are merely convenient, because the distinction decides whether a hybrid makes sense.

### Genuinely structural: happens-before

A `PreToolUse` hook is an interposer. Claude Code runs it, waits for it to exit, and only then executes the tool call. Whatever space it frees is guaranteed to be available to *that* write.

A timer has no such relationship to the event. It fires on a clock it chose, against a workload it cannot see. You can narrow the gap — poll every second, watch PSI, subscribe to filesystem events — but you cannot close it, because a process that is not in the call path cannot make its work *happen-before* a write it never observed. The best a service can do is finish cleaning shortly before or shortly after the `ENOSPC`, and which one you get is a race.

This is the same reason a lock is not a sleep.

### Structural only for a service *by itself*: the feedback channel

Here is where my first answer was too strong, so stated plainly: **a service can absolutely deliver feedback into a session — it just cannot do it alone.**

A session's context is writable only by code the session invokes. That is the actual constraint. A hook satisfies it by construction: its stdout is parsed by Claude Code, and `hookSpecificOutput.additionalContext` is injected into the model's context, while `systemMessage` surfaces to you in the terminal. That is how the agent learns

> /tmp was low (884M of 6.0G free). Auto-cleaned 118 stale entries, 135M reclaimed. Still tight — biggest untouchable entries: /tmp/.Trash-1000 1.1G (in use by a running process)…

rather than watching a tool fail with a bare `ENOSPC` and guessing.

A daemon has no such channel. Nothing it writes to disk reaches a running turn unless something *in* that turn reads it. So a service that wants to explain itself needs a hook to carry the message — at which point you have a timer, a unit file, a state file, and a hook, to do what one hook already does. The architecture argument against the service is not "impossible", it is "strictly more moving parts for the same result".

### Not structural at all

Two things I'd previously have filed under this heading don't belong there:

- **Reacting to disk pressure.** A service can poll `statvfs` every second for near-nothing. The hook isn't better at noticing, only at acting in time (see above).
- **Running with the session's environment.** The `$TMPDIR` protection rule wants the session's `TMPDIR`, which a hook inherits and a user service doesn't. Real, but it's a plumbing detail, not a law — the value could be passed in.

### What follows from this

Split the job by what each mechanism is actually good at:

| Job | Right mechanism | Why |
| --- | --- | --- |
| React to pressure *before* a write, and explain it to the agent | this hook | happens-before, plus the only channel into session context |
| Routine background aging of `/tmp` | `systemd-tmpfiles` | already installed, already scheduled, zero new units |

A custom timer unit would be about eighty lines of unit files to re-solve a solved problem, and on macOS it would need a launchd twin besides. Both platforms already ship the periodic cleaner — see below.

---

## The OS-level cleaner: `mise run install:tmpfiles`

```bash
mise run tmpfiles:status       # what policy is in effect, and when it next runs
mise run install:tmpfiles      # tighten it to 1 day (needs root)
mise run install:tmpfiles 2    # ...or any other number of days
mise run uninstall:tmpfiles    # put the stock policy back
```

This is the only part of the repo that needs root, which is why it is a separate task rather than part of `install:copy`. Both directions are idempotent, both back up what they touch, and both refuse to damage configuration that isn't theirs.

### Exactly what it writes

Nothing is generated at run time or hidden behind a template — this is the literal content, and you can produce it yourself without root by pointing the task at a scratch file:

```bash
TMPFILES_TARGET=/tmp/preview.conf ./scripts/tmpfiles.sh install
```

**Linux — `/etc/tmpfiles.d/tmp.conf`**, created if absent, six lines, pure ASCII:

```
# >>> claude-cleanup >>>
# Masks /usr/lib/tmpfiles.d/tmp.conf by filename (see tmpfiles.d(5)).
# The vendor policy is 30d, which never fires on a tmpfs: nothing
# survives a reboot long enough to reach that age.
# Remove with: mise run uninstall:tmpfiles
D /tmp 1777 root root 1d
# <<< claude-cleanup <<<
```

The single functional line is the last one; everything else is comment. `mise run install:tmpfiles 3` changes exactly one character — `1d` becomes `3d`. The `>>>`/`<<<` markers are what `uninstall:tmpfiles` looks for: a `tmp.conf` without them is somebody else's file, and both install and remove will leave it strictly alone rather than guess.

The effect, via `mise run tmpfiles:status`:

```
                                     before                        after
vendor  /usr/lib/tmpfiles.d/tmp.conf  D /tmp 1777 root root 30d    D /tmp 1777 root root 30d
override /etc/tmpfiles.d/tmp.conf     none, vendor policy applies  D /tmp 1777 root root 1d
```

The vendor file is never edited — it stays exactly as the distro shipped it. Removing the override restores the old behaviour by deletion alone, which is why `uninstall:tmpfiles` can simply `rm` the file.

**macOS — `/etc/periodic.conf`**, a block *appended* to whatever is already there:

```sh
# ...your existing file, untouched...
daily_output="/var/log/daily.out"

# >>> claude-cleanup >>>
# Enables the stock /etc/periodic/daily/110.clean-tmps, which macOS
# ships disabled. Defaults live in /etc/defaults/periodic.conf.
# Remove with: mise run uninstall:tmpfiles
daily_clean_tmps_enable="YES"
daily_clean_tmps_dirs="/tmp"
daily_clean_tmps_days="1"
daily_clean_tmps_ignore=".X11-unix .ICE-unix .font-unix .XIM-unix .Trash .Trash-* quota.user quota.group"
daily_clean_tmps_verbose="NO"
# <<< claude-cleanup <<<
```

Unlike Linux, this file usually already exists and belongs to you, so the block is fenced by markers and everything outside them is preserved byte for byte. Re-installing replaces the block in place rather than appending a second one; removing strips it and leaves the rest. Both are covered by `mise run test` — including a regression for a bug found writing this, where removal briefly ate the whole file.

Line by line:

| Line | Meaning |
| --- | --- |
| `daily_clean_tmps_enable="YES"` | Turns the cleaner on. macOS ships `NO`, so this is the entire change. |
| `daily_clean_tmps_dirs="/tmp"` | Which directories to sweep. Deliberately not `$TMPDIR` — see the macOS notes below. |
| `daily_clean_tmps_days="1"` | Age threshold in days. |
| `daily_clean_tmps_ignore="…"` | Flat list of names never removed. The BSD analogue of this cleaner's protected patterns. |
| `daily_clean_tmps_verbose="NO"` | Set `YES` to have it report what it deleted into the daily mail/log. |

### How it works on Linux: `systemd-tmpfiles`

`systemd-tmpfiles` is a declarative janitor for volatile directories. It reads line-oriented rules from three directories, in ascending priority: `/usr/lib/tmpfiles.d/` (vendor), `/run/tmpfiles.d/` (runtime), `/etc/tmpfiles.d/` (yours). Each line is a type letter, a path, mode, owner, group, and an age:

```
D /tmp 1777 root root 30d
│ │                   └── delete contents unused for 30 days
│ └── the path the rule governs
└── D = create the directory, wipe its contents at boot, and age-clean it
    (d = the same without the boot wipe; x/X = exclude a path from cleaning)
```

It runs in two distinct passes, and confusing them is the usual source of surprise:

| Pass | Trigger | What it does |
| --- | --- | --- |
| `--create --remove` | `systemd-tmpfiles-setup.service`, at boot | Creates the directories; `D` lines empty them |
| `--clean` | `systemd-tmpfiles-clean.timer`, **daily** | Deletes entries older than the age field |

"Older than" means the most recent of atime, mtime and ctime — the same rule this cleaner uses, and for the same reason. You can pin it to one timestamp with a prefix (`ctime` only, etc.); see `tmpfiles.d(5)`.

**Overriding is by filename, not by line.** A file in `/etc/tmpfiles.d/` masks the same-named file in `/usr/lib/tmpfiles.d/` entirely. That is why `install:tmpfiles` writes `/etc/tmpfiles.d/tmp.conf` specifically — the vendor file is literally commented *"Clear tmp directories separately, to make them easier to override"*. Dropping a differently-named file like `99-mine.conf` would **not** work: both files would be read, systemd would see two rules for `/tmp`, and it discards the duplicate rather than merging.

The stock policy is useless on a tmpfs:

```
$ cat /usr/lib/tmpfiles.d/tmp.conf
D /tmp 1777 root root 30d
```

Thirty days, on a directory whose entire contents vanish at every reboot. Nothing ever lives long enough for the rule to fire. One day is a far better fit:

```
# /etc/tmpfiles.d/tmp.conf   ← what install:tmpfiles writes
D /tmp 1777 root root 1d
```

Other packages register exclusions for paths that must survive cleaning, and those still apply — `mise run tmpfiles:status` prints them. On this machine:

```
X /tmp/snap-private-tmp        x /tmp/systemd-private-%b-*
x /tmp/podman-run-*            x /tmp/containers-user-*
```

That list is the `systemd-tmpfiles` equivalent of this cleaner's protected-name patterns — which is also the clearest way to see how much cruder it is. **`systemd-tmpfiles` has no open-fd check and no ownership filter.** It deletes on age alone. A directory a process still has open is fair game to it, where this cleaner would skip it. That is fine at a one-day horizon and is why the two mechanisms complement rather than replace each other — don't push the age much below a day.

### How it works on macOS: `periodic(8)`

macOS has no `systemd-tmpfiles`. The equivalent is the BSD `periodic` machinery it inherited from FreeBSD:

- launchd runs `com.apple.periodic-daily` (plus `-weekly`, `-monthly`) from `/System/Library/LaunchDaemons/`.
- That executes every script in `/etc/periodic/daily/`, of which **`110.clean-tmps`** is the one that cleans `/tmp`.
- Its behaviour is configured by shell variables, not rule files. Defaults live in `/etc/defaults/periodic.conf` (don't edit that — it's replaced by system updates); overrides go in `/etc/periodic.conf`.

The relevant knobs, which `install:tmpfiles` writes as a marked, removable block:

```sh
daily_clean_tmps_enable="YES"     # ships as NO — the cleaner is off by default
daily_clean_tmps_dirs="/tmp"      # which directories to sweep
daily_clean_tmps_days="1"         # age threshold, in days
daily_clean_tmps_ignore=".X11-unix .ICE-unix .font-unix .XIM-unix .Trash .Trash-* …"
daily_clean_tmps_verbose="NO"
```

Force a run with `sudo periodic daily`, and check `daily_clean_tmps_verbose="YES"` if you want to see what it touched.

Three differences from Linux worth knowing:

- **It is off out of the box.** Where Linux ships a too-lax policy, macOS ships none at all, so enabling it is the whole change.
- **`/tmp` matters less on a Mac.** It's a symlink to `/private/tmp` on the ordinary APFS root volume, not a tmpfs — so filling it costs disk, not RAM, and there is far more of it. Most Mac temp data goes to the per-user `$TMPDIR` under `/var/folders/…` instead, which `110.clean-tmps` does not touch and this cleaner deliberately protects as the session's own.
- **`daily_clean_tmps_ignore` is a flat name list**, not the glob-and-type system `tmpfiles.d` offers.

> Everything in this macOS section is written from the documented behaviour of `periodic(8)` and has **not been run on a Mac**. The config-file editing is covered by `mise run test`; whether `periodic` then does the right thing is unverified. Check `mise run tmpfiles:status` and `sudo periodic daily` before trusting it.

## The `/tmp-cleanup` slash command

Typing `/tmp-cleanup` in Claude Code runs the cleaner *with a human in the loop*, which is the difference between it and the hook. The hook acts unilaterally but conservatively; the command can be as aggressive as you like, because you see the list first.

```
/tmp-cleanup                 # dry-run, show the list, ask, then delete
/tmp-cleanup --min-age 10    # arguments pass straight through to the script
/tmp-cleanup --trash         # the one thing the hook will never do on its own
```

What it does, in order:

1. Loads the `tmp-cleanup` skill, so the model has the safety rules in front of it rather than improvising.
2. Runs `--dry-run` with whatever arguments you passed.
3. Shows you the total, the entry count, and — the part that usually matters — the **largest entries it would leave alone, with the reason for each**.
4. Asks before deleting anything. It skips this only if you explicitly said to just clean it up.
5. Re-runs for real, then reports free space before and after and points at the audit log.

Two rules it is told to follow: never pass `--trash` unless you asked for it by name, and if the biggest entries are pinned by a running process, say *which* process rather than trying to delete around it.

Unlike the hook, the command is **never debounced**. If a tool just died with `ENOSPC`, use this — don't wait out the five-minute window.

The command is a thin wrapper (`commands/tmp-cleanup.md`); the skill it loads holds the actual guidance, so the two stay in sync by construction.

## Manual use

Outside Claude Code entirely, the script stands alone:

```bash
~/.claude/skills/tmp-cleanup-impl.py --dry-run     # show what would go
~/.claude/skills/tmp-cleanup-impl.py               # delete entries idle >60m
~/.claude/skills/tmp-cleanup-impl.py --min-age 10  # be more aggressive
~/.claude/skills/tmp-cleanup-impl.py --trash       # also empty /tmp/.Trash-*
~/.claude/skills/tmp-cleanup-impl.py --json        # machine-readable
```

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
| `TMP_CLEANUP_TMPFILES_AGE` | `1` | Days, for `install:tmpfiles` when no argument is given |
| `TMPFILES_TARGET` / `PERIODIC_CONF` / `TMPFILES_PLATFORM` | — | Test seams: retarget or force the platform branch of `tmpfiles.sh` so it can be exercised without root |

Note the units differ by variable: `TMP_CLEANUP_DEBOUNCE` is **seconds**, `TMP_CLEANUP_HOOK_MIN_AGE` is **minutes**, `TMP_CLEANUP_TMPFILES_AGE` is **days**. Each matches the native unit of the mechanism it configures.

## Requirements

Python 3 and `jq` (for the `settings.json` merge). Linux, or macOS with `lsof` — see the platform caveat at the top.
