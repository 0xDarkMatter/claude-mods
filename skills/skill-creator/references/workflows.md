# Workflow Patterns for Skills

Effective patterns for designing multi-step processes and conditional logic in skills.

## Sequential Workflows

For tasks that follow a clear sequence, use numbered steps with verification checkpoints:

```markdown
## Workflow

1. **Validate inputs**
   - Check required parameters exist
   - Verify file formats are correct
   - Exit early if validation fails

2. **Prepare environment**
   - Create working directory
   - Load required dependencies
   - Set configuration values

3. **Execute main task**
   - [Primary operation here]
   - Log progress at key milestones

4. **Verify results**
   - Check output exists and is valid
   - Compare against expected format
   - Run validation tests

5. **Clean up**
   - Remove temporary files
   - Close connections
   - Report completion status
```

**When to use:** Tasks with clear dependencies where each step must complete before the next can begin.

## Conditional Logic

For workflows that branch based on context, use decision trees:

```markdown
## Decision Flow

1. Analyze the request
2. Choose approach based on criteria:

   **If [condition A]:**
   - Follow path A
   - Use tool X
   - Apply settings Y

   **If [condition B]:**
   - Follow path B
   - Use tool Z
   - Apply settings W

   **Otherwise:**
   - Use default approach
```

**When to use:** When different scenarios require different handling strategies.

## Iterative Refinement

For tasks that improve through iteration:

```markdown
## Iterative Process

1. Generate initial draft
2. Review against criteria
3. While quality threshold not met:
   - Identify specific weaknesses
   - Apply targeted improvements
   - Re-evaluate
4. Finalize when acceptable
```

**When to use:** Creative tasks, optimization problems, or quality-sensitive outputs.

## Parallel Execution

For independent tasks that can run concurrently:

```markdown
## Parallel Tasks

Execute these steps simultaneously:

- **Task A:** [Description]
- **Task B:** [Description]
- **Task C:** [Description]

Then combine results:
- [Integration logic]
```

**When to use:** When tasks have no dependencies and can benefit from concurrent execution.

## Error Handling

Build resilience into workflows:

```markdown
## Error Recovery

For each critical step:

1. Attempt operation
2. If failure occurs:
   - Log specific error
   - Try fallback approach if available
   - Otherwise, exit gracefully with clear error message
3. Continue to next step only on success
```

**Best practice:** Always provide actionable error messages that explain what went wrong and how to fix it.

## Subagent Delegation Patterns

**Use subagents for:**

1. **Heavy computation** - Append "use subagents" to requests needing more compute
2. **Context isolation** - Offload individual tasks to keep main agent's context clean
3. **Parallel exploration** - Split research across multiple agents
4. **Specialized expertise** - Route domain-specific subtasks to expert agents

```markdown
## Subagent Workflow

1. Identify subtasks that can be delegated
2. For each subtask:
   - Spawn subagent with clear objective
   - Provide minimal necessary context
   - Collect results
3. Synthesize findings in main context
```

**Benefits:**
- Keeps main agent focused on coordination
- Allows throwing more compute at complex problems
- Prevents context pollution from exploratory work

## ASCII Diagrams for Understanding

When working with new protocols or codebases, request ASCII diagrams:

```markdown
## Request Format

"Draw an ASCII diagram showing:
- [System component relationships]
- [Data flow between modules]
- [Protocol message sequence]"
```

**Example output:**
```
┌─────────────┐      ┌──────────────┐
│   Client    │─────>│   API Server │
└─────────────┘      └──────────────┘
       │                     │
       │  HTTP Request       │
       │                     │
       │  JSON Response      │
       │<────────────────────│
```

**When to use:** Onboarding to new systems, documenting architecture, clarifying complex interactions.

## Checklist Pattern

For comprehensive coverage:

```markdown
## Pre-flight Checklist

Before proceeding, verify:
- [ ] Dependencies installed
- [ ] Configuration valid
- [ ] Test data available
- [ ] Permissions granted
- [ ] Output directory writable
```

**When to use:** Setup procedures, validation steps, quality gates.

## State Machine Pattern

For workflows with multiple modes:

```markdown
## State Transitions

Current state determines available actions:

**State: INITIALIZED**
→ Can transition to: PROCESSING, ERROR
→ Actions: validate, start

**State: PROCESSING**
→ Can transition to: COMPLETED, ERROR
→ Actions: process_batch, check_progress

**State: COMPLETED**
→ Can transition to: INITIALIZED (reset)
→ Actions: export_results, cleanup
```

**When to use:** Complex workflows with distinct phases and clear transition conditions.
