# Owner interview: resolving a draft's questions

A scaffolded AGENTS.md (or nested doc, or ARCHITECTURE.md) is full of `TODO(owner)`
questions. This is the agent procedure that resolves them with the owner: ask only what
the evidence can't answer, one question at a time, and put each answer where it will
last. It drives the harness's question tool (`AskUserQuestion` in Claude Code). Protocol:
`agents-md-protocol.md` sections 1 and 8.

## 1. Split the questions

`agents-md.py scaffold --repo <path> --json` lists every question in `data.questions[]`:

```json
{ "id": "check-command", "question": "There is no single check command. Which command must pass before a commit?",
  "answerable": "guided", "evidence": [".github/workflows/ci.yml:6"],
  "recommended": { "answer": "npm test (what CI runs)", "source": ".github/workflows/ci.yml:6" } }
```

- **Guided** (`answerable: guided`): the facts answer it, with a citation. Confirm it
  rather than ask it: show the recommended answer and its source, and take a one-word
  yes. Examples: the manifest description for the overview, what CI runs when there is
  no check command, the branch that deploys, the nesting advice.
- **Assisted** (`answerable: assisted`): only the owner knows. These are the questions
  that reach the owner. Most landmine candidates are assisted: history shows that two
  files change together, but only the owner knows whether that is a rule.

`data.guided` and `data.assisted` count them. When the assisted count is high, start
with the landmine candidates that have the most evidence.

## 2. Ask one at a time

For each question, in order:

1. Show the question, its evidence (the cited sources), and for a guided one the
   recommended answer.
2. Offer answers the owner can give in a word: accept the recommendation, "not a rule",
   "skip for now", or their own text.
3. Record the answer before moving to the next question. Never batch ten questions into
   one message: the owner answers the first two and skims the rest.

## 3. Put each answer where it will last

Take the first rung that applies, and offer only that one:

1. **A test or assertion that enforces it.** "x.js and y.js must change together"
   becomes a test that fails when they drift. This is the only rung that can't rot.
2. **A comment at the code site**: a guard comment or a contract block, where the next
   editor will see it (`rules/agentic-quality.md`, comment doctrine).
3. **A doc line**: a Landmines item in the owning AGENTS.md, last, because prose rots
   first. A landmine about one package goes in that package's nested AGENTS.md.

**"Not a rule" becomes a ruled-out line** in `docs/agents/ruled-out.md`, pinned to the
evidence count the audit printed, so the question returns only if the evidence grows:

```
- [coupling] `src/x.js` `src/y.js` @4: built together once, independent since
```

An agent writes such a line with `(proposed)` at the end; the owner removes the marker to
accept it. "Skip for now" leaves the `TODO(owner)` in the draft.

## 4. Preview before writing

Nothing is written without approval. Before applying the answers:

- Show a per-file diff (AGENTS.md, any test or comment, `ruled-out.md`) with a one-line
  "why" for each change.
- Apply only what the owner approves, then run `agents-md.py audit` again: answered
  candidates leave `uncovered_candidates`, and ruled-out ones count as "N ruled out".
