# Terminal Display

What summon's terminal panel looks like, and what each part shows.

## Display

Output follows the [Terminal Panel Design System](../../../docs/TERMINAL-DESIGN.md) (panel header, body with `│` rail, footer, ASCII fallback when stdout isn't UTF-8). The candidate hierarchy is **Account → Project → Session**, with sessions globally numbered for picker selection (`3, 5, 7`).

```
╭── 🪄 summon ──────────────────────────────────────────────── → other-account ───●
│
├── 4 sessions · from 1 account · last 3d
│
├── dev@example.com (4)
│   ├── D:\code\project-one (2)
│   │   ├──  1. train-fasttext                    30t            16h
│   │   └──  2. make-doom-for-mips                64t            16h
│   └── D:\work\client-site (2)
│       ├──  3. timekeeper                        35t            16h
│       └──  4. agency-os                         17t            16h
│
│   💡  best run BEFORE switching accounts: copy sessions to the next
│       account first, then Logout/Login (the switch you were doing anyway)
│
╰── # select · a all · blank cancel ───────────────────────────────────●
```

Header shows `→ destination`. Summary line shows count, source breadth, and active filter window. Body shows Account → Project → Session hierarchy with global numbering for picker selection (`3,5,7`). A rotating hint tile sits above the footer; the footer shows the active hotkeys.
