# Dispatching to git-agent

The `Agent(...)` call shapes behind the tier flow in SKILL.md (background by default for T2/T3, foreground when the user is waiting, worktree isolation only on request) and the fallback when `git-agent` is not registered.

## Dispatch Mechanics

### Background Agent (Default for T2/T3)

```python
# Dispatch to git-agent, runs in background, Sonnet model
Agent(
    subagent_type="git-agent",
    model="sonnet",
    run_in_background=True,  # Frees main session
    prompt="..."             # From dispatch templates above
)
```

The main session continues working while the agent handles git operations. Results arrive asynchronously.

### Foreground Agent (When Result Needed Immediately)

For operations where the user is waiting on the result (e.g., "commit this then let's move on"):

```python
Agent(
    subagent_type="git-agent",
    model="sonnet",
    run_in_background=False,  # Wait for result
    prompt="..."
)
```

### Worktree Isolation (Only When Requested)

When the user explicitly asks for worktree isolation (e.g., "do this in a separate worktree", "prepare a branch without touching my working tree"):

```python
Agent(
    subagent_type="git-agent",
    model="sonnet",
    isolation="worktree",     # Isolated repo copy
    run_in_background=True,
    prompt="..."
)
```

## Fallback: When git-agent Is Unavailable

If `git-agent` is not registered as a subagent type (e.g., plugin not installed, agent files missing), fall back to `general-purpose` with the git-agent identity inlined in the prompt.

**Detection:** If dispatching to `git-agent` fails or the subagent type is not listed in available agents, switch to fallback mode automatically.

**Fallback dispatch template:**

```python
Agent(
    subagent_type="general-purpose",  # Fallback
    model="sonnet",
    run_in_background=True,
    prompt="""You are acting as a git operations agent. You are precise, safety-conscious,
and follow the three-tier safety system:
- T1 (read-only): execute freely
- T2 (safe writes): execute on instruction, verify before and after
- T3 (destructive): preflight report only unless explicitly told to execute

{original dispatch prompt here}
"""
)
```

**Key differences from primary dispatch:**
- Uses `general-purpose` instead of `git-agent` subagent type
- Inlines the safety tier protocol directly in the prompt (the agent won't have git-agent's system prompt)
- Everything else stays the same - context gathering, templates, foreground/background choice

**When to use each:**

| Condition | Dispatch Method |
|-----------|----------------|
| `git-agent` available | Primary: `subagent_type="git-agent"` |
| `git-agent` unavailable | Fallback: `subagent_type="general-purpose"` with inlined protocol |
| No agent dispatch possible | Last resort: execute T2 operations inline (main context) |

The last-resort inline path should only be used for simple T2 operations (single commit, simple push). Complex workflows (PR creation, release, changelog) should always use an agent.
