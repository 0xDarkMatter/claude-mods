# Working in Linear as an agent

How an agent cooperates in a shared workspace so that people and other agents can act on what it leaves. This is **practice from teams running agents
in Linear, not Linear's rules**. Where a team has its own agreement, labels or views, those win. Some parts assume conventions a team would need to adopt, and
creating labels or views is itself a decision for the team.

Facts about Linear here are from its docs and schema. Everything else is a habit that has paid for itself.

## Contents

- [The idea](#the-idea)
- [Plan, then act](#plan-then-act)
- [Attribution](#attribution)
- [What belongs in Linear](#what-belongs-in-linear)
- [Asking for something](#asking-for-something)
- [Picking up and putting down](#picking-up-and-putting-down)
- [Asking a question that gets answered](#asking-a-question-that-gets-answered)
- [Deciding](#deciding)
- [Reporting without a meeting](#reporting-without-a-meeting)
- [Finishing](#finishing)
- [Alongside other agents](#alongside-other-agents)
- [Starting a project](#starting-a-project)
- [A new agent's first hour](#a-new-agents-first-hour)
- [What an agent proposes and does not do](#what-an-agent-proposes-and-does-not-do)

## The idea

People and agents often can't see each other's repositories, consoles or chat. So the tracker is where a request gets an owner, an answer and a trail. If it's
not written there, whoever picks the work up next has to reconstruct it from breadcrumbs. Each section below has a failure it exists to prevent.

## Plan, then act

Show the exact object before creating it. An agent that writes first and reports afterwards can't be corrected, and every write lands in someone's inbox and in
history.

## Attribution

A personal API key or user OAuth token attributes every write to that human, and nothing distinguishes a comment they typed from one their agent posted. Readers
then treat a first-pass draft like a considered position.

| Identity | How to mark it |
|---|---|
| User token or key | Say so in the text, e.g. end comments with a line `-- agent`. A team may add an `agent` label at creation. If the team has none, ask before creating one |
| App with `actor=app` | Writes as itself, can be delegated to, not a billable seat. Linear's agent platform has been marked Developer Preview, so check its status |

`createAsUser` and `displayIconUrl` exist on `issueCreate`, `commentCreate` and `attachmentCreate`, and Linear documents them for OAuth apps. Their behaviour with a personal key is unverified, so test
on a throwaway issue.

An agent acts for one person, the one whose account it writes with. It doesn't answer for anyone else.

A coordinator that writes for many lanes should not use a person's account at all: it gets an agent user and its own key. That setup, the single-writer pattern and
the claim line format are in [agent-operations.md](agent-operations.md).

## What belongs in Linear

The tracker owns coordination: goals, progress, the next step, who owns what, what blocks what, what needs deciding. The code host owns substance: code, reproduction
steps, logs, CI, review.

- **Link, don't copy.** An item made from a GitHub issue links it and doesn't paste the body. Use first-class attachments over a URL in prose.
- **Not everything earns an item.** A useful test: does the next required action name someone else, a milestone, or another project? If it's "the repo owner writes the fix",
  leave it on the code host.
- **Never bulk-mirror** a repository into Linear.
- **Capture before the session ends.** A need found now and "filed tomorrow" usually isn't.

Failure prevented: the request that was "mentioned", which exists in one memory and has no owner.

## Asking for something

1. Search first, and comment on an open item with the same outcome. A second item splits the conversation for good.
2. Put it in the project that owns the outcome.
3. Write it so someone can act without asking you anything:

| Part | Content |
|---|---|
| **Outcome** | What will be true when done, from the actor's point of view |
| **Why now** | What's blocked, what date bites, what changed |
| **Next step** | The single next action, naming the act you want: decide, review, deploy, confirm, hand back |
| **Links** | Markdown links with meaningful text, never a bare URL or a copied body |
| **Done when** | At most about three `- [ ]` boxes, each checkable by someone not involved. More means split it |

4. Title it as an imperative outcome: "Resolve stale reads in the error state", not "bug??".
5. Set the fields. A fact that belongs in a field (assignee, project, relation) goes in the field, not in a label.
6. Comment naming the action you want. The description says what it is; the comment says what you need from them.

The receipt is acknowledgement **in the item**: a claim, a handoff or a stated blocker. Chat isn't one.

## Picking up and putting down

Every open item has an accountable owner, or says plainly that it has none (a team might use a `needs-owner` label). Neither is a defect, and whoever notices fixes it.

- **Claim:** set the assignee, move to the state that's now true, and comment what happens first and what you'll link.
- **Assign only with authority.** Assign your own human only if they've delegated that for this item. Never assign someone else's human; propose them in a comment.
- **Hand off:** reassign **and** say in one line what the receiver needs to know, with links. A bare reassignment is a surprise.
- **Put down:** normal and respectable. Say what you learned, what's left and what the next person needs first. A silent un-assign leaves an item that looks alive.

Failure prevented: the permanently assigned item nobody is working on.

## Asking a question that gets answered

Ask on the item it concerns. A question with no item gets its own, linking the relevant project or document. Make it answerable with one word: what's blocked, what you tried, the
options, and which you'd pick.

| Situation | Mark it |
|---|---|
| Another item blocks you | A `blocks` relation, owned by the **blocking** item |
| Something outside blocks you | Name the dependency and its next owner in the comment |
| A human must choose | A decision marker the team uses |
| Nobody is accountable | An unowned marker, naming who you propose |

No answer after a working day: comment again on the same item saying what it now costs. Still nothing: carry it as an ask with an owner into the next project update. Don't open a second
item or move to chat. State what you'll do by default, which is legitimate only where it's reversible and on your own side.

The responder owes something too. When you're mentioned, answer in your next working session the same day, or say when you will. A question
about the rules, rather than the work, isn't answered in passing: it becomes a decision item (see [Deciding](#deciding)).

## Deciding

Choices binding several people need a record. Open an item with the proposed rule written **exactly as it would read after the change**, so agreeing costs one word. Name the situation that
exposed the gap. Each party states a position in a comment, and **silence isn't agreement**. On agreement, change the authoritative document, then close with a link to it. An unresolved
disagreement stays marked open, with what would change someone's mind.

An agent proposes these. It doesn't decide them.

- **What one party may decide alone:** its own implementation and priorities, claiming or releasing an item, its own project update, and raising a
  proposal. Deciding alone isn't the same as deciding silently, so say it in the item.
- **Moving before agreement:** when waiting would block real work, a party may make an exception to a rule alone and in the open. Record it in a project
  update with the decision marker: which rule, why, and what would make it permanent. It lapses after a fixed term (some teams use 14 days) unless everyone
  ratifies it, and the rule is unchanged meanwhile. An exception that expires loudly can't harden into an unwritten rule.
- **Check an agreement's status** before treating it as binding: it may be proposed, not active. Summaries defer to the authoritative document, and where
  they disagree the summary is the bug. Change the document first and any guide after it.
- **Keep rules and practice apart.** Cite the clause for a rule and label a habit as practice. Promoting a habit to a rule is a decision, not an edit.

## Reporting without a meeting

**A project update is a written stand-up.** Post on any milestone or health change and on completion:

| Section | Must contain |
|---|---|
| Health | `onTrack`, `atRisk` or `offTrack`, with one sentence why |
| What moved | Links to merged PRs, green runs or live URLs. No logs |
| Current milestone | Stated even when unchanged |
| Next step | The single next action |
| Risks | What could stop it |
| Asks | Each with a named owner |
| Next update | Who is accountable for it |

Milestones have no settable status, so **the latest update is the authority for where a project sits**, not a deployment, a tag or a commit count. If a week passes with none on an active project,
anyone may post a catch-up or flag it at risk.

For a status read-out: read shared views over ad-hoc searches, and **name the view you read**, which keeps your report and a human's screen in agreement. Cross-check labels against real `blocks`
relations. Report a table of item, project, owner, state and next step, then list anything unowned and anything blocked over a week. Writes nothing.

A read order that surfaces problems first:

1. Unowned items, which is where things rot.
2. Cross-project items, checked against real `blocks` relations.
3. What each member is waiting on.
4. Items agents filed, where an unreviewed misunderstanding shows up first.
5. Each active project's milestones, then its latest update. Flag any active project whose latest update is more than seven days old.

## Finishing

Done needs evidence someone else can open: a merged PR, a green run, a live URL. "Fixed" isn't evidence.

1. Check each **Done when** box against something you can point at.
2. If a box has no evidence, stop and say which, and what would settle it. Don't tick it.
3. Post the links, tick the boxes, move it to Done.
4. **Say what's now unblocked** and comment on whatever was waiting. It's the highest-value habit here, because people watch their own items, not yours.

Canceled or Duplicate needs a one-line reason and the target linked. Prefer cancelling with a reason over deleting. Cancelling can close linked PRs, so check first.

## Alongside other agents

Nothing in Linear locks, and the later write silently wins.

1. **The assignee owns the item.** If that isn't you, comment instead of changing fields.
2. Say what you're about to do before changing state on an item you don't own.
3. **Re-read immediately before writing.**
4. **Never bulk-edit items you didn't just create.**
5. Search before creating. Two agents filing the same outcome is the commonest noise, and the pair is expensive to merge.

Failure prevented: an item whose history is coherent and whose current state nobody chose.

## Starting a project

Creating one is a proposal (see below), but a well-shaped draft makes the yes cheap.

- **Description:** goal, what's in and out of scope, the repositories, audience-facing URLs only, the current lead, and what "ready" means.
- **Leave the lead unset** until a human accepts it. A lead is a coordination contact that can change, and never follows from who owns a repository or
  wrote the code.
- **Milestones are gates.** Each has an exit criterion someone can check from evidence, names who declares it passed, and has a name a non-engineer
  understands. Cut any you can't justify in one line. Projects needn't share one ladder: fit it to how each reaches its audience.

## A new agent's first hour

1. Prove the connection with a read.
2. Confirm who the connection says you are (`whoami` or `viewer`).
3. Make one small, marked write on an item the team agreed for this, saying which harness and connection you used. That record is the useful part: the
   next agent copies a setup that's known to work.

Teams that write their own prompts tend to settle on a short standing block that stays loaded (`assets/agent-standing-rules.md` is a template), plus one
self-contained prompt per task with its inputs in brackets. Every prompt that writes shows the object first and restates the attribution marker, because
a prompt gets pasted without the rest.

## What an agent proposes and does not do

Unless a human has said otherwise for this case, propose these in an item or message:

- Deleting anything, and any bulk or batch mutation.
- Creating, renaming or deleting a label, shared view or milestone. Shared structure is everyone's.
- Changing a shared view's filter.
- Creating a project, or changing how the team works.
- Assigning someone else's human.
- Turning on automatic sync with a code host.
