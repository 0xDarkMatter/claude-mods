# The shadcn MCP server: optional, not recommended for Claude Code

The CLI includes an MCP server (`shadcn mcp`) that lets an assistant list, search and view
registry items and get the `add` command for them. Facts from ui.shadcn.com/docs/mcp and
`shadcn mcp --help` (4.23.0), checked 2026-11-10.

## Why not, in Claude Code

1. **It is a bridge to the same CLI.** Its tools (list and search registries, view items,
   find examples, return an add command, an audit checklist) are `search`, `view` and
   `docs` with extra steps. Project facts (`info`) have no MCP equivalent, so the CLI is
   needed anyway, and Claude Code already runs the CLI well.
2. **It runs in every session.** A stdio server is one extra Node process per session of
   that project, started whether or not shadcn work happens, and its tool descriptions take
   context every turn.
3. **The documented config is unpinned.** The docs and `shadcn mcp init --client claude`
   write a server entry that runs `npx shadcn@latest mcp`: every session start executes
   whatever release is newest, with no prompt.

This skill plus the pinned CLI covers the same ground with nothing resident.

## If you use it anyway

Pin it, scope it to the project, and run the project's locked copy. `assets/mcp.json.example`
is the shape, for a project's `.mcp.json`:

```json
{
  "mcpServers": {
    "shadcn": { "command": "pnpm", "args": ["exec", "shadcn", "mcp"] }
  }
}
```

- Swap the runner for the project's package manager: `npx --no shadcn mcp` (npm),
  `yarn run shadcn mcp`, `bunx --no-install shadcn mcp`. Each fails rather than downloading
  when the devDependency is missing.
- No devDependency: use the exact pin (`"command": "npx", "args": ["shadcn@4.23.0", "mcp"]`),
  and bump it with the skill's pin.
- Keep it in the project's `.mcp.json` (committed, reviewed, approved per user in Claude
  Code), not in user scope where it would start in every project.
- Don't run `mcp init` for Claude Code: it writes the unpinned form. Write the file by hand.
- Private registries still read `${VAR}` tokens from the environment; never put a token in
  `.mcp.json`.

The audit flags MCP configs (`.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`) that run an
unpinned shadcn (`unpinned-mcp`).
