# Skill and Agent Updates

**BEFORE creating or updating any skill or agent**, check the official docs:

| Resource | URL |
|----------|-----|
| Skills | https://code.claude.com/docs/en/skills |
| Sub-agents | https://code.claude.com/docs/en/sub-agents |

These APIs change frequently. For detailed reference (frontmatter fields, decision frameworks), see `docs/SKILL-SUBAGENT-REFERENCE.md`.

## Terminal output

Skills that print to a TTY follow `docs/DESIGN.md` and source `skills/_lib/term.sh` for glyphs, colors, and layout helpers. Don't roll your own ANSI codes or state icons — `term_init` plus `term_state_icon` / `term_header` / `term_table_row` cover the common cases and keep the toolkit visually coherent.
