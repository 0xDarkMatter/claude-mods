# The Figma skill landscape — and what figma-ops leaves to it

Surveyed 2026-09-05. Three families exist; this skill is a router over them plus the
composition workflows none of them cover.

## Official plugin skills (Claude Code `figma` plugin)

Cached under `~/.claude/plugins/cache/claude-plugins-official/figma/<ver>/skills/`.
`figma-use` is the foundation every other one loads alongside.

| Skill | Owns | Load it for |
|---|---|---|
| `figma-use` | Plugin API rules, `use_figma` gotchas, text-edit recipe, page rules, efficient APIs, incremental workflow, error recovery | **every** `use_figma` call |
| `figma-generate-design` | Page/screen from app code; component discovery order (Code Connect → existing screens → `search_design_system`); parallel capture; "don't default to Inter" | composed views from a codebase |
| `figma-generate-library` | Design systems: phase contract, state ledger on disk, idempotency by name, decision forks, token architecture | tokens, variants, libraries |
| `figma-code-connect` | `.figma.ts` mappings | design ↔ code component binding |
| `figma-create-new-file` | `create_new_file` prerequisites | blank files |
| `figma-generate-diagram` | Mermaid → FigJam | diagrams |
| `figma-use-figjam` / `figma-use-slides` / `figma-use-motion` | editor-specific API deltas | FigJam, Slides, animation |
| `figma-implement-motion` | Figma motion → code | animation implementation |
| `figma-swiftui` | SwiftUI ↔ Figma | iOS |

## Official community skills (`figma/community-resources/agent_skills`)

Clustered by design domain; descriptions are outcome-first ("audits", "generates",
"extracts"). `bulk-capture` captures many live pages in parallel via
`generate_figma_design` — the nearest neighbour to this skill's capture phase.

**Inventory (33, as of 2026-09-05).** `scripts/verify-freshness.mjs --live` diffs
this list against the index; a name missing here is drift — add it, don't delete
the check.

| Category | Skills |
|---|---|
| Accessibility | `apca-compliance-figma`, `audit-accessibility-figma`, `lint-design-figma`, `scan-code-accessibility-figma` |
| AI behaviour | `emote-behavioral-contracts` |
| Components | `analyze-component-set-figma`, `arrange-component-set-figma`, `component-properties-figma`, `deep-component-figma`, `design-react-api`, `generate-component-doc-figma`, `reconstruct-component-figma` |
| Design generation | `bridge-ds`, `build-slides-figma`, `bulk-capture` |
| Design process | `annotations-figma`, `check-design-parity-figma`, `delight-audit`, `design-narrative`, `screens-to-ia` |
| Design systems | `design-system-inventory-figma`, `ds-init-figma`, `ds-compliance-audit`, `export-tokens-figma`, `generate-tokens-from-figma`, `import-tokens-figma`, `library-variables-figma`, `manage-variables-figma`, `setup-design-tokens-figma` |
| FigJam | `create-figjam-content`, `figjam-builder`, `workshop-board` |
| Localisation | `localeflow` |

## southleft `figma-console-mcp-skills` (22)

Tokens, components, a11y, versioning (REST + `$FIGMA_TOKEN`), docs, FigJam, Slides.
Its organising principle is the one this skill adopts: *load `figma-use` alongside;
it is the source of truth for the API; extend native capability, never replicate
what the MCP tools already do.*

## Other community (patterns worth knowing)

- **Hosseinkm89/figma-skills** — auto-layout refactor, layer rename, contrast audit.
  Symptom-based triggers ("this file has no auto-layout"); results delivered as a
  designed Figma page with jump links; one workflow per skill.
- **nafiurrahmanniloy/figma-skill** — design → code for seven frameworks.
- **Figma's "10 skills" blog** — `/better-interface`, `/component-handoff`,
  `/ui-state-expander`, `/superfuture-design-review` etc. Skills as reviewers and
  expanders, not just builders.

## The gap this skill fills

Nothing above covers **capture → curate → compose**: bringing brand references,
screenshots or a designer's own comps into Figma and arranging them with intent.
Nor does anything route across the ~65 skills, or handle the two-account reality of
agency work. `figma-ops` owns exactly those three things and cites the rest.

## Patterns borrowed (as ideas, not code)

| From | Pattern | Where it lives here |
|---|---|---|
| `figma-generate-library` §1 | phase checklist → progress → summary | SKILL.md §3 |
| `figma-generate-library` §4, §6 | disk ledger, idempotency by name, ask only at genuine forks, never build on rejected work | SKILL.md §7, §8 |
| `figma-generate-design` | hard gates ("no mutation until discovery is done"), verify the product font | SKILL.md §3 gates, §6 |
| southleft | extend `figma-use`, never replicate | the whole shape of this skill |
| Hosseinkm89 | symptom-based triggers; render results, don't describe them | `description`; §3 Phase 6 |
| `parallel-ops` (this repo) | a router skill for a family | SKILL.md §1 |
