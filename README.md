# claude-mods

Custom commands, skills, and agents for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

## Structure

```
claude-mods/
├── commands/           # Slash commands
│   └── g-slave/        # Make Gemini do Claude's dirty work
├── skills/             # Custom skills
├── agents/             # Custom subagents
├── install.sh          # Linux/macOS installer
└── install.ps1         # Windows installer
```

## Installation

### Quick Install

**Linux/macOS:**
```bash
git clone --recursive https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods
./install.sh
```

**Windows (PowerShell):**
```powershell
git clone --recursive https://github.com/0xDarkMatter/claude-mods.git
cd claude-mods
.\install.ps1
```

### Manual Install

Clone with submodules:
```bash
git clone --recursive https://github.com/0xDarkMatter/claude-mods.git
```

Then symlink or copy to your Claude directories:
- Commands → `~/.claude/commands/`
- Skills → `~/.claude/skills/`
- Agents → `~/.claude/agents/`

## What's Included

### Commands

| Command | Description |
|---------|-------------|
| [g-slave](commands/g-slave/) | Dispatch Gemini CLI to analyze large codebases. Gemini does the grunt work, Claude gets the summary. |

### Skills

*Coming soon*

### Agents

*Coming soon*

## Updating

Pull updates including submodules:
```bash
git pull --recurse-submodules
git submodule update --remote
```

Then re-run the install script.

## Adding Your Own

### Commands
Create a `.md` file in `commands/` following Claude Code's [slash command format](https://docs.anthropic.com/en/docs/claude-code).

### Skills
Create a directory in `skills/` with a `SKILL.md` file.

### Agents
Create a `.md` file in `agents/` with frontmatter defining the agent.

## License

MIT

---

*Extend Claude Code. Your way.*
