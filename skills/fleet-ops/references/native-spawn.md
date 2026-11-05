# Native Spawning Primitives

What each native Claude Code primitive for parallel work gives you, and what it leaves to fleet-ops.

| Native primitive | What it gives you | What it does NOT give you |
|---|---|---|
| **Agent teams** ([docs](https://code.claude.com/docs/en/agent-teams), experimental, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) | Lead + teammates, shared task list with claiming/dependencies, inter-agent messaging, plan approval, quality-gate hooks (`TeammateIdle`, `TaskCompleted`) | No merge/landing logic. No test-gated integration. Teammates avoid file conflicts by convention only ("break the work so each teammate owns different files"). |
| **Background agents / agent view** ([docs](https://code.claude.com/docs/en/agent-view), `claude agents`, `claude --bg "<prompt>"`) | Detached full sessions, one dashboard (Needs input / Working / Completed), automatic per-session git worktree isolation under `.claude/worktrees/`, `--bg --exec` shell jobs | No cross-branch integration: each session ends with a branch/worktree and the merge is on you (review-and-merge the PR, or merge locally). Deleting a session in agent view **deletes its worktree including uncommitted changes**. No ordering, no test gate, no revert. |
| **Subagents** ([docs](https://code.claude.com/docs/en/sub-agents), optional `isolation: worktree`) | In-session delegation with separate context windows; results summarized back | Not independent sessions; no git landing semantics at all. |
