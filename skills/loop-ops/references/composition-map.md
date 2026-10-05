# Composition Map

Where loop-ops sits, and the execution layers a loop composes instead of rebuilding. loop-ops is the design layer; these are the execution layers.

## Where loop-ops sits: the outer loop

> "You shouldn't be prompting coding agents anymore. You should be designing the loops
> that prompt your agents." — Peter Steinberger

This skill is the **outer loop**: the orchestration layer *above* a single agent run. It
is the twin of [`iterate`](../../iterate/SKILL.md) — `iterate` is the *inner* loop (one
metric, one session, git-as-memory); `loop-ops` is the design discipline for the loop
that *schedules and gates* inner runs. It does not reimplement spawning or landing; it
**composes** what this repo already ships.

## Composition map — don't rebuild what exists

| You need to… | Use | Not |
|---|---|---|
| improve one metric in one session | [`iterate`](../../iterate/SKILL.md) | a hand-rolled inner loop |
| spawn cheap parallel makers | [`fleet-worker`](../../fleet-worker/SKILL.md) | bespoke `claude -p` plumbing |
| route models across a fan-out (cheap finders, Opus judges) | [`fleet-worker` model-routing](../../fleet-worker/references/model-routing.md) | every agent on the orchestrator's model |
| test-gate + land winning branches | [`fleet-ops`](../../fleet-ops/SKILL.md) | a manual merge step |
| fire on a cadence or an event | a native `host:` — `/loop`, Desktop scheduled task, cloud routine (schedule/API/GitHub triggers); `/goal` for completion | a custom cron in this skill |
| trust the `verify` gate's judgement | the **`evals-ops`** skill — a gate is an eval (golden set, judge bias, `pass^k`, blocking vs advisory) | eyeballing a few runs and calling it proven |
| reason about per-tick prompt-cache cost | [`claude-api-ops` caching-and-cost](../../claude-api-ops/references/caching-and-cost.md) | a TTL number memorised from a blog post |
| commit / PR / release | [`git-ops`](../../git-ops/SKILL.md), [`github-ops`](../../github-ops/SKILL.md) | raw `git push` |
| signal between loops | [`pigeon`](../../pigeon/SKILL.md) | a shared scratch file |

`loop-ops` is the **design layer**; these are the **execution layers**.
