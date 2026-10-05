# Landing Detail

The already-landed case of the merge step, and `fleet revert` semantics in full. The pipeline itself is in SKILL.md.

## Step 3, merge, in full

3. **Merge** — `--no-ff` with message `merge: <branch>` (this message is what `fleet revert` finds later). If the branch is *already* contained in `main` — another session landed it while this one sat in the queue — `git merge` exits 0 with "Already up to date." and nothing happens. fleet detects that by comparing the tip before and after (never by parsing git's prose) and reports it as `ALREADY LANDED: <branch> — already in main, no merge performed by this run`: the lane goes `LANDED`, the gate does **not** run (there is no merge of ours to gate), the lane branch is left for whoever did land it, and `land --all` counts it as `already in <base>`, apart from real lands

## `fleet revert` in full

`fleet revert <branch>` finds the merge commit on `main` whose subject is **exactly** `merge: <branch>` and runs `git revert -m 1` — one command to back out a bad landing. The match is exact, never `git log --grep`: `--grep` is a regex applied as a *substring*, so `merge: lane/auth` also matched `merge: lane/auth-refactor` and reverting one lane destroyed the other's work while reporting the branch you asked for (fixed 2026-09-08). If the branch landed more than once, the most recent merge is reverted and the others are logged rather than silently passed over. A revert that conflicts is **aborted**, leaving `main` and the working tree exactly as they were — no stranded sequencer for the next `fleet land` to misreport as "uncommitted tracked changes". A reverted lane goes back to `RUNNING` with a note: it is no longer in `main`, so leaving it `LANDED` would be a status panel that lies about where the work lives.
