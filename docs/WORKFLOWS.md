# Claude Code Workflows

Recommended patterns for common development tasks.

## Core Workflow: Explore → Plan → Code → Commit

The fundamental Claude Code workflow from [Anthropic's best practices](https://www.anthropic.com/engineering/claude-code-best-practices):

```
1. EXPLORE - Read files, understand context
2. PLAN    - Think hard, design approach
3. CODE    - Implement solution
4. COMMIT  - Save with descriptive message
```

### Example

```
User: "Add user authentication to the app"

1. "Read the existing auth files and user model"
   → Claude reads relevant files

2. "think harder about the authentication approach"
   → Claude analyzes options (JWT vs sessions, OAuth integration, etc.)

3. "Implement the authentication following your plan"
   → Claude writes code

4. "Commit with a descriptive message"
   → Claude commits changes
```

---

## Test-Driven Development (TDD)

Write tests first, then implement:

```
1. Write failing tests for expected behavior
2. Confirm tests fail (no implementation yet)
3. Commit tests
4. Implement code to pass tests
5. Verify tests pass
6. Commit implementation
```

### Example

```
User: "Add a validateEmail function using TDD"

1. "Write tests for validateEmail - should accept valid emails, reject invalid ones"
2. "Run the tests to confirm they fail"
3. "Commit the tests"
4. "Implement validateEmail to pass the tests"
5. "Run tests again to verify"
6. "Commit the implementation"
```

---

## Code Review Workflow

Multi-step review with subagents:

```
1. Check staged changes
2. Review for bugs, security, performance
3. Generate improvement suggestions
4. Apply fixes if approved
```

### Example

```
User: "Review my staged changes"

1. /review                           # Run code review
2. "think hard about the security findings"
3. "Fix the critical issues found"
4. "Commit the fixes"
```

---

## Feature Development Workflow

From idea to merged PR:

```
1. Understand requirements
2. Explore existing code
3. Plan implementation
4. Write tests
5. Implement feature
6. Review and refine
7. Create PR
```

### Example

```
User: "Add dark mode to the settings page"

1. "What are the requirements for dark mode?"
2. "Read the current settings page and theme system"
3. "think harder about implementing dark mode"
4. "Write tests for the dark mode toggle"
5. "Implement the dark mode feature"
6. /review
7. "Create a PR for this feature"
```

---

## Debugging Workflow

Systematic problem investigation:

```
1. Reproduce the issue
2. Read relevant code and logs
3. Think about root cause
4. Use subagents to verify hypotheses
5. Implement fix
6. Add regression test
```

### Example

```
User: "Users report login fails intermittently"

1. "Read the authentication logs"
2. "Read the login handler code"
3. "think harder about what could cause intermittent failures"
4. "Use a subagent to check the session storage implementation"
5. "Fix the identified race condition"
6. "Add a test to prevent regression"
```

---

## Refactoring Workflow

Safe, incremental improvements:

```
1. Ensure tests exist
2. Plan refactoring approach
3. Make small, atomic changes
4. Run tests after each change
5. Commit incrementally
```

### Example

```
User: "Refactor the user service to use dependency injection"

1. "Check test coverage for the user service"
2. "think hard about the DI refactoring approach"
3. "Extract the database dependency first"
   → Run tests
   → Commit
4. "Extract the cache dependency"
   → Run tests
   → Commit
5. "Update the service constructor"
   → Run tests
   → Commit
```

---

## Multi-Agent Parallel Workflow

Run multiple Claude instances for faster development:

```
1. Break work into independent tasks
2. Assign each task to a separate instance
3. One instance writes, another verifies
4. Merge results
```

### Example

```
Terminal 1: "Implement the API endpoints"
Terminal 2: "Write the frontend components"
Terminal 3: "Write integration tests"

# Later
"Merge the work from all terminals"
```

---

## Session Continuity Workflow

Using claude-mods commands for persistent state:

```
Session 1:
  /sync                              # Bootstrap context
  [work on tasks]
  /plan --save "Stopped at auth"     # Save state

Session 2:
  /sync                              # Bootstrap context
  /plan --load                       # Restore tasks
  /plan --status                     # Check progress
  [continue work]
  /plan --save "Completed auth"      # Save progress
```

---

## Visual Iteration Workflow

For UI development with screenshots:

```
1. Provide design mock (Figma screenshot, etc.)
2. Ask Claude to implement
3. Take screenshot of result
4. Iterate until match
5. Commit when satisfied
```

### Example

```
User: [pastes Figma screenshot]
      "Implement this design"

1. Claude implements initial version
2. User: [pastes screenshot of result]
         "The spacing is off, fix it"
3. Claude adjusts spacing
4. User: "Looks good, commit it"
```

---

## Subagent Verification Pattern

Use subagents to verify your work:

```
1. Complete main task
2. "Use a subagent to verify this is correct"
3. Address any issues found
4. Proceed with confidence
```

### Example

```
User: "Implement rate limiting"

1. Claude implements rate limiting
2. "Use a subagent to review this implementation for edge cases"
3. Subagent finds issue with concurrent requests
4. Claude fixes the edge case
5. "Commit the rate limiting feature"
```

---

## Quick Reference

| Workflow | Key Steps | When to Use |
|----------|-----------|-------------|
| **Explore → Plan → Code → Commit** | Read, think, implement, commit | All development |
| **TDD** | Test first, then implement | New features, bug fixes |
| **Code Review** | /review, think, fix | Before PRs |
| **Feature Dev** | Requirements → PR | New features |
| **Debugging** | Reproduce, investigate, fix, test | Bug investigation |
| **Refactoring** | Test, small changes, verify | Code improvement |
| **Multi-Agent** | Parallel instances | Large tasks |
| **Session Continuity** | /sync, /plan --save/--load | Multi-session work |
| **Visual Iteration** | Mock → implement → screenshot → iterate | UI development |
| **Subagent Verification** | Complete → verify → fix | Critical code |
