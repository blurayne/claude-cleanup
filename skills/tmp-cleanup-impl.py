#!/usr/bin/env python3
"""
tmp-cleanup — reclaim space on /tmp (usually a small tmpfs) safely.

Two modes:

  * manual   `tmp-cleanup-impl.py [--dry-run] [--min-age MIN] [--trash] [--json]`
             Report what is eligible and delete it.

  * hook     `tmp-cleanup-impl.py --hook`
             Near-zero cost. Reads the hook payload on stdin (and ignores it),
             checks free space with one statvfs(), and only does real work when
             /tmp is running low. Prints a JSON hook result on stdout.

Safety rules — an entry is only ever deleted when ALL of these hold:

  * it lives directly under /tmp (never recursing outside it, never a symlink
    target outside it)
  * it is owned by the current uid
  * its name does not match a protected pattern (X11/ICE/pulse/dbus/ssh/gpg
    sockets, systemd-private-*, snap private tmp, the running session's TMPDIR)
  * it is not a socket or fifo
  * no process of ours has it open (scanned via /proc/*/fd and /proc/*/cwd)
  * it has not been touched within --min-age minutes

The desktop trash (/tmp/.Trash-*) is never touched unless --trash is passed,
and the hook never passes it.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import shutil
import stat
import sys
import time
from pathlib import Path

TMP = Path(os.environ.get("TMP_CLEANUP_DIR", "/tmp"))
LOG = Path.home() / ".cache" / "claude" / "tmp-cleanup.log"

# Trigger a hook-mode cleanup when free space drops below either of these.
LOW_FREE_PCT = float(os.environ.get("TMP_CLEANUP_LOW_PCT", "15"))
LOW_FREE_MB = float(os.environ.get("TMP_CLEANUP_LOW_MB", "512"))
# Hook mode deletes oldest-first until this much is free again.
TARGET_FREE_PCT = float(os.environ.get("TMP_CLEANUP_TARGET_PCT", "35"))
# Hook mode never touches anything younger than this (minutes).
HOOK_MIN_AGE_MIN = float(os.environ.get("TMP_CLEANUP_HOOK_MIN_AGE", "30"))

PROTECTED = [
    ".X*-unix",
    ".ICE-unix",
    ".font-unix",
    ".Test-unix",
    ".XIM-unix",
    ".x*-lock",
    "systemd-private-*",
    "snap-private-tmp",
    "snap.*",
    "ssh-*",
    "gpg-*",
    "dbus-*",
    "pulse-*",
    ".esd-*",
    "tmux-*",
    ".wayland-*",
    ".mutter-*",
    "runtime-*",
    "krb5cc_*",
    ".XauthorityXXXXXX",
    "*.sock",
    "*.socket",
    "*.pid",
    ".Trash-*",  # only removable with --trash, handled separately
]


def human(n: float) -> str:
    for unit in ("B", "K", "M", "G", "T"):
        if abs(n) < 1024 or unit == "T":
            return f"{n:.0f}{unit}" if unit == "B" else f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}T"


def free_space() -> tuple[int, int]:
    """(free bytes, total bytes) of the filesystem holding TMP."""
    st = os.statvfs(TMP)
    return st.f_bavail * st.f_frsize, st.f_blocks * st.f_frsize


def open_paths(budget_s: float = 3.0) -> tuple[set[str], bool]:
    """Top-level TMP entries held open (fd or cwd) by a visible process.

    Returns (names, complete). A single runaway process can hold six figures of
    fds, so the walk is time-boxed; `complete=False` means the caller must not
    trust the set and should fall back to an age floor instead.
    """
    live: set[str] = set()
    root = str(TMP) + os.sep
    deadline = time.monotonic() + budget_s
    complete = True

    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        if time.monotonic() > deadline:
            complete = False
            break
        targets = [proc / "cwd"]
        try:
            targets += list((proc / "fd").iterdir())
        except (PermissionError, FileNotFoundError, NotADirectoryError):
            pass
        for link in targets:
            try:
                dest = os.readlink(link)
            except OSError:
                continue
            if dest.startswith(root):
                # Protect the whole top-level entry, not just the open file.
                live.add(dest[len(root):].split(os.sep, 1)[0])
    return live, complete


def protected(name: str, allow_trash: bool) -> bool:
    for pattern in PROTECTED:
        if pattern == ".Trash-*" and allow_trash:
            continue
        if fnmatch.fnmatch(name, pattern):
            return True
    return False


def newest_mtime(path: Path, st: os.stat_result, budget: int = 20000) -> float:
    """Most recent mtime/atime in `path`; for dirs this walks (bounded)."""
    newest = max(st.st_mtime, st.st_atime, st.st_ctime)
    if not stat.S_ISDIR(st.st_mode):
        return newest
    seen = 0
    for dirpath, dirnames, filenames in os.walk(path, onerror=lambda _: None):
        for entry in dirnames + filenames:
            seen += 1
            if seen > budget:
                return newest
            try:
                sub = os.lstat(os.path.join(dirpath, entry))
            except OSError:
                continue
            newest = max(newest, sub.st_mtime, sub.st_atime)
    return newest


def dir_size(path: Path, st: os.stat_result) -> int:
    if not stat.S_ISDIR(st.st_mode):
        return st.st_blocks * 512
    total = 0
    for dirpath, dirnames, filenames in os.walk(path, onerror=lambda _: None):
        for entry in dirnames + filenames:
            try:
                total += os.lstat(os.path.join(dirpath, entry)).st_blocks * 512
            except OSError:
                pass
    return total


def scan(min_age_min: float, allow_trash: bool) -> tuple[list[dict], list[dict]]:
    """(eligible oldest-first, kept largest-first) entries directly under TMP.

    Kept entries carry a `reason` so a caller that is still short on space can
    explain what is hogging /tmp and why it was left alone.
    """
    uid = os.getuid()
    now = time.time()
    live, complete = open_paths()
    if not complete:
        # Couldn't enumerate every open fd in time, so "not open" is no longer a
        # fact. Only touch things old enough that nothing could still want them.
        min_age_min = max(min_age_min, 24 * 60)
    cutoff = now - min_age_min * 60
    session_tmp = os.environ.get("TMPDIR", "").rstrip("/")
    eligible: list[dict] = []
    kept: list[dict] = []

    for entry in sorted(TMP.iterdir()):
        name = entry.name
        try:
            st = entry.lstat()
        except OSError:
            continue

        reason = None
        if name in live:
            reason = "in use by a running process"
        elif session_tmp and (str(entry) == session_tmp or session_tmp.startswith(str(entry) + "/")):
            reason = "this session's TMPDIR"
        elif protected(name, allow_trash):
            reason = "desktop trash (needs --trash)" if name.startswith(".Trash-") else "protected name"
        elif st.st_uid != uid:
            reason = "owned by another user"
        elif stat.S_ISSOCK(st.st_mode) or stat.S_ISFIFO(st.st_mode):
            reason = "socket/fifo"

        touched = newest_mtime(entry, st)
        if reason is None and touched > cutoff:
            reason = f"touched {round((now - touched) / 60)}m ago"

        rec = {
            "path": str(entry),
            "name": name,
            "size": dir_size(entry, st),
            "age_min": round((now - touched) / 60),
            "kind": "dir" if stat.S_ISDIR(st.st_mode) else "file",
        }
        if reason is None:
            eligible.append(rec)
        else:
            kept.append({**rec, "reason": reason})

    eligible.sort(key=lambda c: -c["age_min"])
    kept.sort(key=lambda c: -c["size"])
    return eligible, kept


def remove(path: str) -> bool:
    try:
        p = Path(path)
        if p.is_dir() and not p.is_symlink():
            shutil.rmtree(p, ignore_errors=False)
        else:
            p.unlink()
        return True
    except OSError:
        return False


def log(lines: list[str]) -> None:
    try:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        stamp = time.strftime("%Y-%m-%d %H:%M:%S")
        with LOG.open("a") as fh:
            for line in lines:
                fh.write(f"{stamp} {line}\n")
    except OSError:
        pass


def sweep(cands: list[dict], need: int | None, dry_run: bool) -> tuple[list[dict], int]:
    """Delete candidates (oldest first) until `need` bytes are reclaimed.

    need=None means delete all of them.
    """
    removed: list[dict] = []
    freed = 0
    for c in cands:
        if need is not None and freed >= need:
            break
        if dry_run or remove(c["path"]):
            removed.append(c)
            freed += c["size"]
    if removed and not dry_run:
        log([f"removed {human(c['size']):>7}  {c['path']}" for c in removed])
    return removed, freed


def run_manual(args: argparse.Namespace) -> int:
    free, total = free_space()
    cands, kept = scan(args.min_age, args.trash)
    reclaimable = sum(c["size"] for c in cands)

    removed, freed = sweep(cands, None, args.dry_run)
    free_after, _ = free_space()

    if args.json:
        print(json.dumps(
            {
                "dir": str(TMP),
                "free_before": free,
                "free_after": free_after,
                "total": total,
                "reclaimable": reclaimable,
                "dry_run": args.dry_run,
                "removed": removed,
                "kept": kept,
            },
            indent=2,
        ))
        return 0

    verb = "would remove" if args.dry_run else "removed"
    print(f"{TMP}: {human(free)} free of {human(total)} "
          f"({free / total * 100:.0f}%), min age {args.min_age:g}m"
          f"{', including trash' if args.trash else ''}")

    if removed:
        for c in removed[:40]:
            print(f"  {verb:>12}  {human(c['size']):>7}  {c['age_min']:>6}m  {c['path']}")
        if len(removed) > 40:
            print(f"  … and {len(removed) - 40} more")
        print(f"{verb} {len(removed)} entries, {human(freed)}")
        if not args.dry_run:
            print(f"{TMP}: now {human(free_after)} free ({free_after / total * 100:.0f}%)")
            print(f"log: {LOG}")
    else:
        print("nothing eligible — everything under /tmp is young, in use, or not mine")

    big = [k for k in kept if k["size"] >= 50 * 1024 * 1024][:10]
    if big:
        print(f"\nlargest entries left alone ({human(sum(k['size'] for k in kept))} kept in total):")
        for k in big:
            print(f"  {human(k['size']):>7}  {k['path']}  — {k['reason']}")
    return 0


def run_hook() -> int:
    try:
        sys.stdin.read()
    except Exception:
        pass

    free, total = free_space()
    if free >= total * LOW_FREE_PCT / 100 and free >= LOW_FREE_MB * 1024 * 1024:
        return 0  # plenty of room, stay out of the way

    need = max(0, int(total * TARGET_FREE_PCT / 100) - free)
    cands, kept = scan(HOOK_MIN_AGE_MIN, allow_trash=False)
    removed, freed = sweep(cands, need, dry_run=False)
    free_after, _ = free_space()

    msg = (f"/tmp was low ({human(free)} of {human(total)} free). ")
    if removed:
        msg += (f"Auto-cleaned {len(removed)} stale entries, {human(freed)} reclaimed, "
                f"now {human(free_after)} free. Log: {LOG}. ")
    else:
        msg += "Nothing was safe to auto-remove. "

    if free_after < total * TARGET_FREE_PCT / 100:
        top = [k for k in kept if k["size"] >= 50 * 1024 * 1024][:5]
        if top:
            listing = "; ".join(f"{k['path']} {human(k['size'])} ({k['reason']})" for k in top)
            msg += f"Still tight — biggest untouchable entries: {listing}. "
        msg += "Run /tmp-cleanup to go through it interactively (--trash empties the desktop trash)."

    print(json.dumps({
        "systemMessage": msg,
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "additionalContext": msg,
        },
    }))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Reclaim space on /tmp safely.")
    ap.add_argument("--hook", action="store_true", help="hook mode: only act when /tmp is low")
    ap.add_argument("--dry-run", action="store_true", help="show what would go, delete nothing")
    ap.add_argument("--min-age", type=float, default=60,
                    help="only touch entries untouched for this many minutes (default 60)")
    ap.add_argument("--trash", action="store_true",
                    help="also empty /tmp/.Trash-* (your desktop trash — destructive)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    if not TMP.is_dir():
        print(f"no such directory: {TMP}", file=sys.stderr)
        return 1

    return run_hook() if args.hook else run_manual(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:  # a broken hook must never block a tool call
        if "--hook" in sys.argv:
            sys.exit(0)
        print(f"tmp-cleanup: {exc}", file=sys.stderr)
        sys.exit(1)
