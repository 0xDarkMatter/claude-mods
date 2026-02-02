# Output Patterns for Skills

Effective patterns for achieving specific output formats and quality standards.

## Template-Based Generation

Provide templates with clear placeholders:

```markdown
## Output Template

Use this structure for all responses:

\`\`\`
# {TITLE}

## Summary
{BRIEF_OVERVIEW}

## Details
{COMPREHENSIVE_EXPLANATION}

## Examples
{CODE_OR_USAGE_EXAMPLES}

## References
- {LINK_1}
- {LINK_2}
\`\`\`

**Placeholder guidelines:**
- {TITLE}: 5-8 words, action-oriented
- {BRIEF_OVERVIEW}: 1-2 sentences maximum
- {COMPREHENSIVE_EXPLANATION}: Structured with headers
- {CODE_OR_USAGE_EXAMPLES}: 2-3 concrete examples
```

**When to use:** Consistent formatting across outputs, standardized reports, documented APIs.

## Example-Driven Specification

Show, don't tell:

```markdown
## Expected Output Format

**Good examples:**

\`\`\`json
{
  "status": "success",
  "data": {
    "items": [...],
    "count": 42
  }
}
\`\`\`

**Bad examples to avoid:**

\`\`\`json
{
  "result": true  // Too vague, missing data
}
\`\`\`

**Key principles:**
- Always include status field
- Nest data under "data" key
- Include count for arrays
```

**When to use:** API responses, structured data, format specifications.

## Quality Criteria

Define measurable standards:

```markdown
## Output Requirements

Generated code must:
1. **Type Safety** - Pass TypeScript strict mode without any errors
2. **Test Coverage** - Include unit tests for all public functions (>80% coverage)
3. **Documentation** - JSDoc comments on all exported items
4. **Error Handling** - Try-catch blocks for all async operations
5. **Linting** - Pass ESLint with zero warnings

Verify each requirement before finalizing output.
```

**When to use:** Code generation, document creation, quality-sensitive deliverables.

## Iterative Refinement with Feedback

Build in review cycles:

```markdown
## Generation Process

1. **Generate initial version**
   - Focus on structure and completeness
   - Don't over-optimize yet

2. **Self-review against criteria**
   - Check each requirement explicitly
   - Note specific gaps

3. **Revise targeted weaknesses**
   - Fix identified issues
   - Don't change working sections

4. **Final verification**
   - Confirm all criteria met
   - Present completed output
```

**When to use:** Complex outputs, high standards, multi-faceted requirements.

## Layered Verbosity

Offer multiple detail levels:

```markdown
## Output Structure

### Executive Summary (2-3 sentences)
[High-level overview]

### Key Points (bullets)
- Point 1
- Point 2
- Point 3

### Detailed Analysis (optional, expand on request)
[Comprehensive explanation with examples]

### Technical Appendix (optional, expand on request)
[Implementation details, edge cases, references]
```

**When to use:** Reports, explanations, documentation where audience needs vary.

## Before/After Comparison

Show transformation clearly:

```markdown
## Changes Made

**Before:**
\`\`\`python
def process(data):
    result = data * 2
    return result
\`\`\`

**After:**
\`\`\`python
def process(data: list[int]) -> list[int]:
    """Double all values in the input list.

    Args:
        data: List of integers to process

    Returns:
        New list with all values doubled
    """
    return [x * 2 for x in data]
\`\`\`

**Improvements:**
- Added type hints
- Added comprehensive docstring
- Used list comprehension for efficiency
```

**When to use:** Code refactoring, document editing, migration guides.

## Structured Alternatives

Present options systematically:

```markdown
## Approach Options

### Option A: [Name]
**Pros:**
- Benefit 1
- Benefit 2

**Cons:**
- Drawback 1
- Drawback 2

**Best for:** [Use case]

### Option B: [Name]
**Pros:**
- Benefit 1
- Benefit 2

**Cons:**
- Drawback 1
- Drawback 2

**Best for:** [Use case]

**Recommendation:** [Choice with rationale]
```

**When to use:** Design decisions, technology selection, strategy proposals.

## Incremental Disclosure

Start simple, expand on request:

```markdown
## Basic Usage

\`\`\`python
result = process_data(input_file)
\`\`\`

---

<details>
<summary>Advanced Options</summary>

\`\`\`python
result = process_data(
    input_file,
    format="json",
    validate=True,
    timeout=30
)
\`\`\`

**Parameters:**
- `format`: Output format (json/csv/xml)
- `validate`: Run validation checks
- `timeout`: Max processing time in seconds
</details>

---

<details>
<summary>Complete API Reference</summary>

[Exhaustive documentation]
</details>
```

**When to use:** API documentation, tutorials, learning materials.

## Visual Representations

Use ASCII diagrams for clarity:

```markdown
## System Architecture

\`\`\`
┌──────────────┐
│   Frontend   │
└──────┬───────┘
       │
       │ REST API
       │
┌──────▼───────┐      ┌─────────────┐
│   Backend    │─────>│  Database   │
└──────────────┘      └─────────────┘
       │
       │ Events
       │
┌──────▼───────┐
│ Message Queue│
└──────────────┘
\`\`\`

**Flow:**
1. Frontend sends HTTP requests
2. Backend processes and queries database
3. Backend publishes events to queue
4. Workers consume queue messages
```

**When to use:** Architecture documentation, data flow explanation, protocol visualization.

## Annotated Examples

Explain while showing:

```markdown
## Implementation

\`\`\`python
# Initialize connection with retry logic
connection = connect_db(
    host="localhost",     # Database server address
    retry_count=3,        # Attempt connection 3 times
    timeout=5             # 5 second timeout per attempt
)

# Execute query with parameter binding (prevents SQL injection)
results = connection.query(
    "SELECT * FROM users WHERE status = ?",
    params=["active"]     # Safe parameterized query
)

# Process results lazily to conserve memory
for row in results:     # Iterator pattern - doesn't load all at once
    process_user(row)
\`\`\`
```

**When to use:** Code examples, tutorials, onboarding materials.

## Constraint-Driven Format

Specify hard limits:

```markdown
## Output Constraints

**Length:**
- Title: Max 60 characters
- Summary: 100-150 words
- Body: 500-1000 words

**Structure:**
- Exactly 3 main sections
- 2-4 bullet points per section
- 1 code example per section

**Tone:**
- Professional but conversational
- Active voice preferred
- Technical accuracy paramount
```

**When to use:** Content creation, marketing copy, technical writing with space constraints.
