# `evals/`

Trigger evals for claude-mods skills, one folder per case, in the format `claude plugin
eval` reads: `prompt.md` (frontmatter + the request) and `graders/<name>.md`. Adds to the
root AGENTS.md. Only skills with a case are covered.

## Run

```sh
claude plugin eval . --ablation none --trust-plugin -j 4 --case 'sandbox-ops*'
```

- It spends the caller's plan usage (3 runs a case), so CI does not run it. Run it
  before a pull request that adds a skill or changes its description, and say the result
  in the pull request.
- Each run starts in an empty directory with only the plugin loaded, so a prompt carries
  its own context. `evals/results/` is written on every run and is gitignored.

## Cases

- `<skill>-triggers[-<variant>]`: a request that must load `<skill>`; grader
  `skill-fired.md`.
- `<skill>-not-<sibling>`: a request that belongs elsewhere and must not load `<skill>`;
  grader `skill-not-fired.md` with `min: 0` and `max: 0`.
- Graders are `tool_used` on the `Skill` tool (free). No `llm` or `baseline` graders:
  they cost judge calls. `input_match` accepts a plugin prefix: `(?:[\w-]+:)?<skill>`.
- Write the request in a developer's words, never naming the skill. Keep personal
  names, client names and real hosts out: this repo is public.
