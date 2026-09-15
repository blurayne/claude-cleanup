Use the `tmp-cleanup` skill to reclaim space on the /tmp tmpfs: $ARGUMENTS

Steps:

1. Invoke the `tmp-cleanup` skill (Skill tool) to load its guidance and safety rules.
2. Run `~/.claude/skills/tmp-cleanup-impl.py --dry-run`, passing through any arguments given above (e.g. `--min-age 10`, `--trash`).
3. Show the user what would be removed — total reclaimable size, entry count, and the **largest entries left alone with their reason**. That last list is usually the actual explanation for a full /tmp.
4. Ask for confirmation, then re-run the same command without `--dry-run`.
5. Report free space before and after, and point at the audit log `~/.cache/claude/tmp-cleanup.log`.

Skip the confirmation in step 4 only if the user explicitly asked to just clean it up. Never pass `--trash` (which empties the desktop trash) unless the user asked for it by name.

If the biggest entries are pinned by a running process, say which process and suggest closing or killing it — don't try to delete around it.
