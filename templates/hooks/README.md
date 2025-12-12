# Hook Templates

Claude Code hooks are configured in `settings.json` or `settings.local.json` files.
This directory contains example hook scripts that can be referenced in your configuration.

## Hook Configuration

Add hooks to your settings file:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "path/to/hook-script.sh"
          }
        ]
      }
    ]
  }
}
```

## Available Hook Events

| Event | Description | Has Matcher |
|-------|-------------|-------------|
| `PreToolUse` | Before tool execution | Yes |
| `PostToolUse` | After tool completes | Yes |
| `PermissionRequest` | When permission dialog shown | Yes |
| `Notification` | When notifications sent | Yes |
| `UserPromptSubmit` | When user submits prompt | No |
| `Stop` | When agent finishes | No |
| `SubagentStop` | When subagent finishes | No |
| `PreCompact` | Before context compaction | No |
| `SessionStart` | Session begins/resumes | No |
| `SessionEnd` | Session ends | No |

## Hook Script Requirements

1. Receives JSON input via stdin
2. Exit codes:
   - `0`: Success
   - `2`: Blocking error (stderr shown to Claude)
   - Other: Non-blocking error

## Example Scripts

See the example scripts in this directory for common patterns.
