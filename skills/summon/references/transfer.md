# Transfer Mode: Framings, Edge Cases, Sidebar Refresh

Transfer-mode detail behind SKILL.md: the push and pull framings, the edge cases summon handles, and why new sessions need a Logout/Login to appear.

## Push vs pull

Two natural framings of the same operation:

- **Push** (proactive): you're approaching usage limit on your current account. Run `summon --to <next-account>` while still on the current one. Pick which sessions to push. Then Logout/Login is the account switch you were going to do anyway.
- **Pull** (rescue): you've already switched accounts and want to bring earlier sessions over. Run `summon` (no `--to`); destination defaults to your now-current account.

Mechanically identical — the file moves are the same regardless of which framing you have in mind. Push is the recommended workflow because the Logout/Login becomes invisible.

## Edge cases handled

| Case | Behaviour |
|------|-----------|
| Session cwd is `/sessions/<vm>/mnt` (remote) | Skipped — no local transcript to bridge |
| Transcript JSONL missing on disk | Skipped with warning (orphan metadata) |
| Same `sessionId` already in destination | Skipped (idempotent) |
| Destination has no workspace dirs | New workspace UUID created |
| Stdout is not UTF-8 (Windows cp1252) | ASCII fallback for all panel glyphs |
| Stdout is not a TTY or `NO_COLOR` set | Plain text, no ANSI escapes |

## Sidebar refresh

Desktop loads sessions into its left-hand session picker on login and doesn't watch the filesystem afterwards (verified via bundle inspection — no `chokidar`, no relevant `fs.watch` on the session dir, only direct `fs.readdir` calls). Summon throws a best-effort nudge at fs.watch (sentinel pings, mtime touches, rename ping-pong) but **don't rely on it** — assume Logout/Login is required to populate the sidebar with new sessions.

This is why summon is best run **before switching accounts**: the Logout/Login is what you'd do anyway. Running summon as a "rescue" after the fact still works mechanically, but the Logout/Login still has to happen.

If sessions still don't appear:

1. Try View → Reload (rarely helps; Ctrl+R only re-renders)
2. **Logout → Login** triggers a full filesystem rescan and always works
