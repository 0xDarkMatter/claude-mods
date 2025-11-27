# Sprint - Project Planning Management Skill

Automatically manage ROADMAP.md and PLAN.md across all your projects, keeping sprint plans in sync with git commits and TodoWrite tasks.

## Quick Start

```bash
/sprint          # Full analysis and sync
/sprint check    # Check if plan is stale
/sprint sync     # Quick sync without full analysis
```

Or just say:
- "sync my sprint plan"
- "update my plan"
- "check if my plan is stale"

## What It Does

### 1. Manages Two Planning Documents

**docs/ROADMAP.md** - Long-term vision
- Product roadmap across versions (v0.1, v0.2, etc.)
- Feature categories and enhancements
- Technical architecture
- Success metrics

**docs/PLAN.md** - Current sprint tasks
- Weekly todo list with checkboxes
- Organized by status (In Progress / Pending / Completed)
- Synced with TodoWrite tool
- Updated based on git commits

### 2. Keeps Everything in Sync

- ✅ **Git commits** → Marks tasks as completed
- ✅ **TodoWrite** → Syncs checkbox states
- ✅ **ROADMAP.md** → Populates next sprint tasks
- ✅ **Timestamps** → Tracks last update

### 3. Smart Analysis

- **Adaptive lookback**: 30 days default, expands to 60/90/180/365 days if no commits
- **Uncommitted changes**: Detects work in progress, matches files to tasks
- **Fuzzy matching**: Matches commit messages to tasks (70%+ similarity)
- **File-to-task linking**: Links modified files to related tasks (e.g., `src/cli.py` → "Implement CLI")
- Suggests new tasks from ROADMAP phases

## Usage Examples

### First Time Setup

```
You: I need planning docs for my project
Claude: [Invokes /sprint skill]
  → Analyzes project structure
  → Creates ROADMAP.md with AI-generated vision
  → Creates PLAN.md from current phase
  → Initializes with tasks
```

### Daily Sync

```
You: /sprint sync
Claude:
  ✓ Sprint plan synced!
  • Completed: 2 tasks (from git commits)
  • Synced: 3 tasks with TodoWrite
  • Updated: 1 minute ago
```

### Weekly Review

```
You: /sprint
Claude:
  📊 Full analysis complete!

  Git activity (7 days):
  • 15 commits analyzed
  • 5 features completed

  Updates:
  • Moved 5 tasks to Completed
  • Added 3 new tasks from ROADMAP Phase 2
  • Synced all with TodoWrite

  Sprint Status:
  • In Progress: 2 tasks
  • Pending: 8 tasks
  • Completed: 15 tasks
```

### Staleness Check

```
You: /sprint check
Claude:
  ⚠ Plan is 4 days old

  Recent activity:
  • 7 git commits since last sync
  • 3 TodoWrite items completed

  Run /sprint sync to update
```

## File Structure

The skill expects (and creates if missing):

```
your-project/
├── docs/
│   ├── ROADMAP.md    # Long-term product roadmap
│   └── PLAN.md       # Current sprint checklist
└── .git/             # Git repository (required)
```

## How It Works

### Adaptive Commit Analysis

Intelligently finds commits with adaptive lookback:

```bash
# Start: 30 days
git log --since="30 days ago" --oneline --no-merges

# If no commits, expand: 60, 90, 180, 365 days
# Stops when commits found or max reached
```

**Handles inactive projects**:
- Slow-moving projects: Automatically expands search
- Reports: "No commits in last 30 days, expanded to 90 days"
- Finds the most recent work automatically

**Matches patterns**:
- `feat(cli): Add analyze command` → "Add analyze command"
- `fix: Resolve bug in parser` → "Resolve bug in parser"
- `docs: Update README` → "Update README"

### Uncommitted Changes Detection

Detects work in progress and matches to tasks:

```bash
git status --porcelain
```

**File-to-Task Matching**:
- `src/cli.py` modified → 🔨 "Implement CLI"
- `tests/test_cli.py` added → 🔨 "Write CLI tests"
- `src/analyzer.py` changed → 🔨 "Create analyzer framework"

**Smart reporting**:
```
📝 Uncommitted Changes (5 files):
  • src/cli.py          → 🔨 "Implement CLI"
  • src/analyzer.py     → 🔨 "Create analyzer framework"
  • README.md           → (no task match)

💡 Tip: Commit your work to track progress
```

**Suggestions**:
- >5 files changed: Suggests committing
- >100 lines changed: "Substantial work detected"
- >24 hours since last commit: Reminds you to commit

### TodoWrite Sync

Reads TodoWrite state from conversation context and syncs with PLAN.md checkboxes:

- TodoWrite "completed" → `[x]` in PLAN.md
- TodoWrite "in_progress" → `[ ]` in "In Progress" section
- TodoWrite "pending" → `[ ]` in "Pending" section

### Task Matching

Uses fuzzy matching to link commits to tasks:
- 70%+ similarity = likely match
- Keyword detection: "add", "create", "implement", "fix"
- Suggests matches for user confirmation

## Automation Triggers

The skill can be triggered:

1. **Explicitly**: `/sprint`, `/sprint sync`, `/sprint check`
2. **After commits**: When you make significant git commits
3. **Daily check**: First Claude Code session of the day
4. **TodoWrite changes**: When marking items complete

## Safety Features

- ✅ Non-destructive - preserves manual edits
- ✅ Additive - adds tasks, doesn't remove arbitrarily
- ✅ Timestamped - tracks all updates
- ✅ Confirmation - asks before major changes (>5 tasks)
- ✅ Git-aware - knows what's committed

## Error Handling

**No git repo**: Suggests initializing git first
**Missing ROADMAP**: Offers to create from template
**Parse errors**: Offers to reformat PLAN.md
**Can't analyze**: Creates basic template

## Commands Reference

| Command | Description | When to Use |
|---------|-------------|-------------|
| `/sprint` | Full analysis + sync | Weekly review, major updates |
| `/sprint sync` | Quick sync only | Daily updates, after commits |
| `/sprint check` | Staleness check | Check if update needed |
| "sync my plan" | Natural language | Anytime you want to sync |

## Tips

1. **Run daily**: Quick `/sprint sync` keeps things fresh
2. **After features**: Run `/sprint` after completing major work
3. **Weekly reviews**: Full `/sprint` for comprehensive updates
4. **Check staleness**: `/sprint check` to see if update needed

## Configuration

Currently uses sensible defaults:
- 7-day commit lookback
- 3-day staleness threshold
- Auto-sync with TodoWrite
- Markdown checkbox format

Future: Could support `.sprintrc` for customization

## Works With

- ✅ Python projects
- ✅ JavaScript/TypeScript projects
- ✅ Any git repository
- ✅ All your projects (global skill)

## Troubleshooting

**"Plan is stale" but I just updated it**:
- Git might not have the file committed
- Try: `git add docs/PLAN.md && git commit -m "Update plan"`

**Tasks not syncing with TodoWrite**:
- TodoWrite state is ephemeral (per session)
- Run `/sprint sync` to manually sync

**Commit analysis missing tasks**:
- Use conventional commit messages (feat:, fix:, docs:)
- Or manually update PLAN.md checkboxes

## Examples in the Wild

### HarvestMCP Project
```
docs/ROADMAP.md - 5-phase roadmap for v0.1-v0.5
docs/PLAN.md - Current sprint: PM tools development
Sprint status: 3 in progress, 8 pending, 12 completed
```

### project-organizer-pro
```
docs/ROADMAP.md - Full product vision with 15 categories
docs/PLAN.md - Phase 1: Foundation sprint
Sprint status: 1 in progress, 15 pending, 6 completed
```

---

**Skill Version**: 1.0
**Created**: 2025-11-01
**Requires**: Claude Code with git repository
