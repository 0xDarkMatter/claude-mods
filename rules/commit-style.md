# Commit Style Guide

Conventional Commits format for all commits in this project.

## Format

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

## Types

| Type | When to Use | Example |
|------|-------------|---------|
| `feat` | New feature or capability | `feat: Add docker-expert agent` |
| `fix` | Bug fix | `fix: Correct skill routing in python-expert` |
| `docs` | Documentation only | `docs: Update ARCHITECTURE.md` |
| `refactor` | Code change (neither fix nor feat) | `refactor: Streamline agent frontmatter` |
| `chore` | Maintenance, dependencies, config | `chore: Bump plugin version to 1.3.0` |
| `style` | Formatting, whitespace (no logic) | `style: Fix markdown table alignment` |
| `test` | Adding or updating tests | `test: Add skill functional tests` |
| `perf` | Performance improvement | `perf: Optimize skill loading` |

## Scopes (Optional)

| Scope | Applies To |
|-------|------------|
| `agents` | Files in `/agents` |
| `skills` | Files in `/skills` |
| `commands` | Files in `/commands` |
| `rules` | Files in `/rules` |
| `hooks` | Hook implementations |
| `docs` | Documentation files |
| `plugin` | Plugin configuration |

## Rules

1. **Subject line**: Max 72 characters, imperative mood ("Add" not "Added")
2. **No period** at end of subject line
3. **Scope is optional** but recommended for component-specific changes
4. **Body**: Wrap at 72 characters, explain "what" and "why"
5. **Breaking changes**: Add `BREAKING CHANGE:` in footer

## Examples

### Simple Feature

```
feat(agents): Add docker-expert agent
```

### Bug Fix with Context

```
fix(skills): Correct dependency resolution in python-async-patterns

The depends-on field was not being parsed correctly when multiple
dependencies were specified. Now handles arrays properly.
```

### Breaking Change

```
refactor(commands): Rename /delegate to /conclave

BREAKING CHANGE: /delegate command no longer exists. Use /conclave.
```

### Documentation Update

```
docs: Add authority levels to ARCHITECTURE.md
```

### Multi-component Change

```
feat: Add Go/Rust agents, enhance setperms with AI CLIs

- Add go-expert and rust-expert agents
- Add AI CLI tools (gemini, claude, codex) to setperms
- Add git safety rules to cli-tools
```

## Anti-patterns

```
BAD:  "Updated stuff"           - Vague, no type
BAD:  "feat: added new agent."  - Past tense, trailing period
BAD:  "FEAT: Add agent"         - Uppercase type
BAD:  "feat(agents): Add the new docker expert agent for containerization"
      - Too long (> 72 chars)

GOOD: "feat(agents): Add docker-expert agent"
```

