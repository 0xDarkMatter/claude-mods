---
description: "Deep explanation of complex code, files, or concepts. Breaks down architecture, data flow, and design decisions."
---

# Explain - Deep Code Explanation

Get a comprehensive explanation of complex code, files, or architectural concepts.

## Arguments

$ARGUMENTS

- File path: Explain specific file
- Function/class name: Explain specific component
- `--depth <shallow|normal|deep>`: Level of detail
- `--focus <arch|flow|deps|api>`: Specific focus area

## What This Command Does

1. **Identify Target**
   - Parse file/function/concept
   - Gather related files if needed
   - Understand scope of explanation

2. **Analyze Code**
   - Parse structure and dependencies
   - Trace data flow
   - Identify patterns and design decisions

3. **Generate Explanation**
   - Architecture overview
   - Step-by-step breakdown
   - Visual diagrams (ASCII)
   - Related concepts

## Execution Steps

### Step 1: Parse Target

```bash
# If file path
cat <file>

# If function name, search for it
grep -rn "function <name>\|def <name>\|class <name>" .

# If directory
ls -la <dir>
tree <dir> -L 2
```

### Step 2: Gather Context

For the target, collect:
- Imports/dependencies
- Exports/public API
- Related files (tests, types)
- Usage examples in codebase

### Step 3: Analyze Structure

**For Functions:**
- Input parameters and types
- Return value and type
- Side effects
- Error handling
- Algorithm complexity

**For Classes:**
- Properties and methods
- Inheritance/composition
- Lifecycle
- Public vs private API

**For Files/Modules:**
- Purpose and responsibility
- Exports and imports
- Dependencies
- Integration points

**For Directories:**
- Module organization
- File relationships
- Naming conventions
- Architecture pattern

### Step 4: Generate Explanation

```markdown
# Explanation: <target>

## Overview
<1-2 sentence summary of what this does and why>

## Architecture
<ASCII diagram if helpful>

```
┌─────────────┐    ┌─────────────┐
│   Input     │───▶│  Processor  │
└─────────────┘    └──────┬──────┘
                          │
                          ▼
                   ┌─────────────┐
                   │   Output    │
                   └─────────────┘
```

## How It Works

### Step 1: <phase name>
<explanation>

### Step 2: <phase name>
<explanation>

## Key Concepts

### <Concept 1>
<explanation>

### <Concept 2>
<explanation>

## Dependencies
- `<dep1>` - <purpose>
- `<dep2>` - <purpose>

## Usage Examples

```<language>
// Example usage
```

## Design Decisions

### Why <decision>?
<rationale>

## Related Code
- `<file1>` - <relationship>
- `<file2>` - <relationship>

## Common Pitfalls
- <pitfall 1>
- <pitfall 2>
```

## Usage Examples

```bash
# Explain a file
/explain src/auth/oauth.ts

# Explain a function
/explain validateToken

# Explain a class
/explain UserService

# Explain a directory
/explain src/services/

# Explain with deep detail
/explain src/core/engine.ts --depth deep

# Focus on data flow
/explain src/api/routes.ts --focus flow

# Architecture overview
/explain src/services/ --focus arch
```

## Depth Levels

| Level | Output |
|-------|--------|
| `shallow` | Quick overview, main purpose, key exports |
| `normal` | Full explanation with examples (default) |
| `deep` | Exhaustive breakdown, edge cases, internals |

## Focus Areas

| Focus | Explains |
|-------|----------|
| `arch` | Architecture, structure, patterns |
| `flow` | Data flow, control flow, sequence |
| `deps` | Dependencies, imports, integrations |
| `api` | Public API, inputs, outputs, contracts |

## Explanation Styles by Target

### Functions
- **Input/Output**: What goes in, what comes out
- **Algorithm**: Step-by-step logic
- **Edge Cases**: Boundary conditions
- **Performance**: Time/space complexity

### Classes
- **Purpose**: Why this class exists
- **State**: What data it manages
- **Behavior**: What it can do
- **Relationships**: How it connects to others

### Files
- **Role**: Where it fits in the system
- **Exports**: What it provides
- **Imports**: What it needs
- **Patterns**: Design patterns used

### Directories
- **Organization**: How files are structured
- **Conventions**: Naming and patterns
- **Boundaries**: Module responsibilities
- **Dependencies**: Inter-module relationships

## ASCII Diagrams

For complex systems, include ASCII diagrams:

### Sequence Diagram
```
User          Service         Database
  │              │               │
  │──request───▶│               │
  │              │───query─────▶│
  │              │◀──result─────│
  │◀─response───│               │
```

### Data Flow
```
[Input] → [Validate] → [Transform] → [Store] → [Output]
              │
              └──[Error]──▶ [Log]
```

### Component Diagram
```
┌────────────────────────────────────┐
│            Application             │
├──────────┬──────────┬─────────────┤
│  Routes  │ Services │   Models    │
├──────────┴──────────┴─────────────┤
│            Database               │
└────────────────────────────────────┘
```

## Flags

| Flag | Effect |
|------|--------|
| `--depth <level>` | Set detail level (shallow/normal/deep) |
| `--focus <area>` | Focus on specific aspect |
| `--no-examples` | Skip usage examples |
| `--no-diagrams` | Skip ASCII diagrams |
| `--json` | Output as structured JSON |

## Integration

Works well with:
- `/review` - Review after understanding
- `/test` - Generate tests for explained code
- `/checkpoint` - Save progress after learning

## Notes

- Explanations are based on code analysis, not documentation
- Complex systems may need multiple explanations
- Use `--depth deep` for unfamiliar codebases
- Diagrams help visualize relationships
