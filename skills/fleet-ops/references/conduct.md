# Conduct - the coordinator ritual

`/conduct` runs the coordinator's whole pass over a wave of child sessions: take their
READY reports, review each diff, improve or send back, land them one at a time, write the
wave's changelog entry, say what would be pushed, then clean up. It runs in **MAIN**, the
session whose cwd is the main checkout's root ([session-awareness.md](session-awareness.md)).
It never pushes, deploys, or deletes work that has not landed.

The mechanical half is `fleet queue` (`scripts/queue.sh`): it waits for `main` to settle,
checks the tip is the reviewed one, trial-merges, audits the would-be merge, waits for
memory headroom, and lands through `fleet land`. The judgement half (review, improve,
the changelog, the push question, archiving) is the agent's, and this file is its procedure.

## Contents

- [Arguments](#arguments)
- [The ledger](#the-ledger)
- [Phase 0: pin the coordinator](#phase-0-pin-the-coordinator)
- [Phase 1: inventory](#phase-1-inventory)
- [Phase 2: intake](#phase-2-intake)
- [Phase 3: review](#phase-3-review)
- [Phase 4: improve or send back](#phase-4-improve-or-send-back)
- [Phase 5: land, one at a time](#phase-5-land-one-at-a-time)
- [Phase 6: one changelog entry per wave](#phase-6-one-changelog-entry-per-wave)
- [Phase 7: report what would be pushed](#phase-7-report-what-would-be-pushed)
- [Phase 8: sweep, prune, archive](#phase-8-sweep-prune-archive)
- [Phase 9: final report](#phase-9-final-report)
- [Rules, and why](#rules-and-why)

Commands below use `FLEET="$HOME/.claude/skills/fleet-ops/scripts"`; in the repo itself,
use `skills/fleet-ops/scripts`.

## Arguments

| Argument | Effect |
|---|---|
| (none) | Phases 0-9 |
| `--dry-run` | Phases 0-3 only, with `fleet queue --dry-run` as the review verdict. Lands, writes, sweeps and archives nothing |
| `--no-archive` | Phase 8 lists the sessions it would archive instead of archiving them |

## The ledger

One file per repo, `.claude/fleet/QUEUE.md` in the main checkout. Fleet already ignores
`.claude/fleet/`, so the ledger is never committed, and it outlives the coordinator
session, so a handoff passes the wave on intact. **One row per lane, keyed by lane +
head SHA.**

```markdown
# Landing ledger - wave <name> - <date>
Coordinator: <session id> (fleet main claim)
Changelog: lanes skip CHANGELOG.md; the coordinator writes one entry for the wave

| # | Lane | Head | Brief | State | Notes |
|---|---|---|---|---|---|
| 1 | lane/foo | 3b34773 | <one line> | LANDED 43f1793 | |
| 2 | lane/bar | 4ccf7bf | <one line> | REVIEWED | queue after #1 |
| 3 | lane/baz | 9079903 | <one line> | SENT-BACK | scope: touched hooks/, brief said skills/ only |
```

States, in order: `REPORTED` (READY received) -> `REVIEWED` (diff read, head frozen) ->
`QUEUED` -> `LANDED <merge sha>`; or `SENT-BACK <why>`, `FAILED <why>`, `HELD <what the
maintainer must decide>`, then `ARCHIVED` once its session is archived.

- A READY naming a lane + head already in the ledger is a **duplicate**: note it, do nothing.
- A READY naming a new head for a `LANDED` lane: run `fleet queue --dry-run` on it.
  `already` means it is the same content, rebased (a duplicate). Anything else is new
  work and goes back to `REPORTED`.

## Phase 0: pin the coordinator

```bash
bash "$FLEET/fleet.sh" landing                 # where main stands; exit 10 = wait
id=$(bash "$FLEET/sessions.sh" self)           # this session's id, local_<uuid>
bash "$FLEET/fleet.sh" main claim "$id"        # lanes resolve MAIN through this pin
```

Write the id into the ledger header and into every lane brief this session writes
("report READY by SendMessage to `<id>`"). If `sessions.sh self` exits 3 (no session
store on this host), `fleet main claim` with no id pins the session whose cwd is the root.

## Phase 1: inventory

```bash
bash "$FLEET/fleet.sh" status
bash "$FLEET/fleet.sh" sweep                   # report only: landed, competing, leftovers, sessions
git for-each-ref --format='%(refname:short)' refs/heads/lane/
```

Then the session list (`list_sessions` with linked sessions, on Desktop): which child
sessions are working, idle, or waiting for an answer. Every branch ahead of `main` gets a
ledger row, reported or not. A session waiting for the user is the user's to answer.

## Phase 2: intake

Record each READY as `REPORTED` with the head it names. Check it against the ledger
(duplicates above). Do not land from the report: a READY is a claim, and phase 3 tests it.

## Phase 3: review

Per lane, against its brief, with the head frozen first:

```bash
git rev-parse lane/foo                                   # the head the READY named?
git rev-list --left-right --count main...lane/foo        # behind / ahead
git -C <lane worktree> status --porcelain                # clean?
git diff --stat main...lane/foo                          # scope: only what the brief allowed
git diff main...lane/foo                                 # read it
bash "$FLEET/fleet.sh" queue --dry-run lane/foo <head>   # trial merge + audits
```

Then the gates the brief named, on that head, wherever the report's evidence is thin
(no exit codes, "should pass", a gate it skipped). Check the claims the report makes
against the diff, file by file. A clean `--dry-run` row and a diff that matches the brief
make it `REVIEWED`.

## Phase 4: improve or send back

- **Small and mechanical** (a count, a link, a typo, a missing doc line): fix it yourself,
  as a commit in the lane's worktree, while its owner is idle. Re-freeze the new head.
- **Anything else** (a behaviour, a test, the brief's own judgement calls): send it back
  with the evidence (file:line, the failing output). The ledger row goes `SENT-BACK`.
- **A conflict with `main`**: the owner rebases, or you do while it is idle; review again.

## Phase 5: land, one at a time

```bash
bash "$FLEET/fleet.sh" queue lane/foo <reviewed head>    # run_in_background: true
```

One lane per call, and the next call starts from the previous one's completion
notification. Several pairs in one call are allowed, but the deadline (default 90m) stops
any new land from starting once it passes, so only chain what fits.

| Exit | Means | Do |
|---|---|---|
| 0 | landed, or its content was already in `main` | ledger `LANDED <sha>`; queue the next |
| 3 | lane or head does not resolve | check the ledger row |
| 4 | an audit failed (`dropped`, `glued`, `dups`) | read stderr; fix in the lane (phase 4). `--skip-audit <name>` only for a verified false positive, reason in the ledger |
| 5 | precondition (git 2.38+, repo) | fix the host |
| 6 | deadline passed while waiting (owner live, `main` unsettled, memory high) | queue it again later, from a notification |
| 10 | conflicts with `main` | phase 4 |
| 11 | head moved to different content, or a tree is dirty | review the new head (phase 3) |
| 12 | `fleet land` ran and did not land (gate red, scrub, merge conflict) | read `.claude/fleet/queue/<lane>.log`; fleet already reset `main` |

While a land waits on a live owner, send that owner nothing.

## Phase 6: one changelog entry per wave

When the wave's briefs said "skip CHANGELOG.md, put the entry text in your READY report",
write the combined entry once the wave has landed: in a short lane of its own
(`lane/<wave>-changelog`), reviewed and landed through phase 5 like any other, so `main`
stays landing-only and the gate runs over it. Then update the plan's status if the wave
had one.

## Phase 7: report what would be pushed

```bash
git rev-list --count origin/main..main
git log --oneline --first-parent origin/main..main
```

Report the count, the merges, and which gates ran green on the final `main`. Then ask
(`AskUserQuestion`: push now / hold). Pushing, and any deploy, is the maintainer's
decision every time: `/conduct` never runs `git push`.

## Phase 8: sweep, prune, archive

```bash
bash "$FLEET/fleet.sh" sweep --apply           # zero-loss only: ghosts, merged unheld branches
bash "$FLEET/fleet.sh" prune                   # dry run; read it, then prune --remove for SAFE rows
bash "$FLEET/fleet.sh" sweep                   # again, for the session rows
```

`/conduct` archives finished child sessions itself, with no prompt per session: archiving
is reversible, and this standing OK is what the command is for (`--no-archive` withdraws
it). It replaces the sweep's "Archive `<n>` finished sessions?" question for this run.
But `archive_session` also removes the session's worktree, so a session is archived
only when **all** of these hold:

- it is idle, and its lane is `LANDED` or closed in the ledger;
- its worktree is clean: `git -C <wt> status --porcelain` prints nothing, untracked
  files included;
- it is not pinned, not waiting for the user's answer, and not this session.

`ARCHIVE-DIRECT` rows: `archive_session`, never a message (a message resumes it into a
missing tree). `ARCHIVE-REQUEST` rows: archive directly when the session already
reported done and nothing of it is open in the ledger; otherwise send the sweep's
request text so it can finish first. Report one line per archived session:
`archived <title> (<id>): <lane> landed as <sha>`.

## Phase 9: final report

One block: landed (lane, merge sha), sent back (lane, why), held (lane, what the
maintainer must decide), archived (one line each), what would be pushed, and every gate
that was not run or not green. Label each claim measured, inferred or guess.

## Rules, and why

Each rule is a failure that happened before the rule existed.

1. **One land at a time, each started from the previous one's notification.** A
   background command has a time limit (about 2 hours) and can be killed mid-gate,
   leaving `main` holding an untested merge. A sleep loop chaining many lands walks
   straight into that limit; `fleet queue --deadline` stops a new land from starting late.
2. **Retry a live-owner refusal quietly; never message an owner whose land is waiting.**
   `fleet land` refuses while the owner was active in the last 10 minutes, and a message
   is activity: it resets the clock the gate is waiting on.
3. **Accept a moved head only when it merges to the same tree.** Fleet rebases every
   tracked lane after each land, so a frozen head moves legitimately. Same outcome is
   the test (`fleet queue` applies it); any other change was not reviewed.
4. **Audit every merge as ours + theirs - base.** "Keep both sides" resolutions drop the
   blank lines both sides shared and glue entries together. The `dropped` and `glued`
   audits read the would-be merge, not the lane's summary of it.
5. **Gate only with memory headroom.** Windows commit exhaustion makes forks fail
   (error 299), and the gate reports that as test failures in code the lane never
   touched. The guard waits while the commit charge is high; elsewhere it does nothing.
6. **Lanes in a wave skip the changelog; the coordinator writes one entry.** N lanes all
   adding to `[Unreleased]` conflict on every land after the first.
7. **Review the diff, not the summary.** A READY is a claim: check the head,
   ahead/behind, a clean tree, the scope against the brief, and the gates, before
   queueing.
8. **Key the ledger by lane + head.** A READY can arrive twice, and a rebased head looks
   new. The ledger recognises both, so nothing lands twice.
9. **Archive only idle, landed and clean sessions.** Archiving removes the worktree:
   uncommitted or untracked work in it is gone for good.
10. **Pushing is the maintainer's call.** `/conduct` reports what would go and asks.
11. **Pin the coordinator's id and put it in every brief.** Lanes find MAIN by session
    id; an id hard-coded into an old brief points at a coordinator that has handed off.
