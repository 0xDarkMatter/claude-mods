# Extended Thinking

Claude Code supports extended thinking mode for deeper analysis. Trigger with these phrases:

## Thinking Triggers

| Phrase | Budget | Use When |
|--------|--------|----------|
| `think` | Low | Quick analysis, simple decisions |
| `think hard` | Medium | Multiple options to evaluate |
| `think harder` | High | Complex problems, architectural decisions |
| `ultrathink` | Maximum | Critical decisions, security review |

## Usage Examples

```
"think about how to structure this feature"
"think hard about the trade-offs here"
"think harder about potential edge cases"
"ultrathink about the security implications"
```

## When to Use Each Level

### `think` - Quick Analysis
- Choosing between 2-3 simple options
- Reviewing straightforward code
- Making minor decisions

### `think hard` - Deeper Analysis
- Planning a new feature
- Evaluating multiple approaches
- Debugging non-obvious issues

### `think harder` - Comprehensive Evaluation
- Architectural decisions
- Complex refactoring plans
- Performance optimization strategies
- Trade-off analysis with many variables

### `ultrathink` - Maximum Depth
- Security-critical code review
- Production incident investigation
- Major architectural changes
- Risk assessment for breaking changes

## Best Practices

1. **Use during planning** - Think before implementing
2. **Match complexity** - Don't ultrathink simple tasks
3. **Combine with subagents** - "think harder, then use subagents to verify"
4. **Be specific** - "think hard about the authentication flow" > "think hard"

## Example Workflow

```
1. "Read the authentication module"
2. "think harder about how to add OAuth support"
3. [Claude provides detailed analysis]
4. "Now implement it following the plan"
```

## Anti-Patterns

```
BAD:  "ultrathink about this typo fix"
GOOD: "fix the typo in line 42"

BAD:  "think" (with no context)
GOOD: "think about the best data structure for this use case"

BAD:  Jumping straight to implementation
GOOD: "think hard about the approach, then implement"
```
