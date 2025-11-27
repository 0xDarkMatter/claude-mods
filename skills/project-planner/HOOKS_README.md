# Sprint Skill Hooks - MVP

Automated sprint plan management using Claude Code hooks.

## What This Does

**Automatically reminds you to sync your sprint plan** at the right moments:

1. **On Session Start**: Warns if PLAN.md is >3 days old
2. **After Git Commits**: Suggests running `/sprint sync`
3. **After Completing 2+ Tasks**: Reminds you to update PLAN.md

## Installation

### Option 1: User-Level (All Projects)

Run this in Claude Code:
```
/hooks
```

Then select **"User settings"** and paste the contents of `hooks.json`.

### Option 2: Project-Specific (HarvestMCP only)

1. Create `.claude/hooks.json` in your project root
2. Copy contents from this `hooks.json` file
3. Commit to version control so it applies to all team members

### Option 3: Manual Configuration

Add to your `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "if [ -f docs/PLAN.md ] && [ -d .git ]; then days_old=$(( ($(date +%s) - $(git log -1 --format=%ct docs/PLAN.md 2>/dev/null || echo 0)) / 86400 )); if [ $days_old -gt 3 ]; then echo \"⚠️  Sprint plan is $days_old days old. Run /sprint sync to update.\"; fi; fi"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "cmd=$(echo \"$TOOL_INPUT\" | jq -r '.command // empty' 2>/dev/null); if echo \"$cmd\" | grep -q 'git commit' 2>/dev/null; then echo \"💡 Committed changes. Run /sprint sync to update your plan.\"; fi"
          }
        ]
      },
      {
        "matcher": "TodoWrite",
        "hooks": [
          {
            "type": "command",
            "command": "completions=$(echo \"$TOOL_INPUT\" | jq '[.todos[] | select(.status == \"completed\")] | length' 2>/dev/null); if [ \"$completions\" -ge 2 ] 2>/dev/null; then echo \"✓ $completions tasks completed! Run /sprint sync to update PLAN.md\"; fi"
          }
        ]
      }
    ]
  }
}
```

## Requirements

- `jq` (JSON processor) - Usually pre-installed on macOS/Linux
  - Windows: Install via `choco install jq` or download from https://jqlang.github.io/jq/
- Git repository
- `docs/PLAN.md` file (created by `/sprint` skill)

## Testing

After installation, test each hook:

1. **SessionStart**: Restart Claude Code session
2. **Git commit hook**: Run `git commit -m "test"`
3. **TodoWrite hook**: Mark 2+ tasks as completed

You should see reminder messages in the Claude Code output.

## Customization

Edit the hooks to change behavior:

### Change Staleness Threshold

Change `$days_old -gt 3` to different number of days:
```bash
if [ $days_old -gt 7 ]; then  # Warn after 7 days instead of 3
```

### Change Completion Threshold

Change `$completions -ge 2` to require more completions:
```bash
if [ \"$completions\" -ge 5 ]; then  # Remind after 5 tasks instead of 2
```

### Disable Specific Hooks

Remove entire hook objects from the JSON:
- Remove `SessionStart` block to disable staleness check
- Remove `Bash` matcher to disable git commit reminders
- Remove `TodoWrite` matcher to disable completion reminders

## Future Enhancements

Possible additions for v2.0:
- Auto-run `/sprint sync` (not just suggest)
- Track sprint velocity in log file
- Block edits to archived plans
- End-of-day sprint review reminder
- Integration with git hooks (pre-commit)

## Troubleshooting

**Hook not firing?**
- Check hook syntax with `/hooks` command
- Verify `jq` is installed: `jq --version`
- Check hook output doesn't have syntax errors

**False positives?**
- Hooks trigger on every matching tool use
- Adjust matchers to be more specific
- Add additional grep filters to command

**Need to disable temporarily?**
- Comment out hook in settings JSON
- Or remove hooks section entirely

---

**Version**: 1.0.0 (MVP)
**Last Updated**: 2025-11-01
