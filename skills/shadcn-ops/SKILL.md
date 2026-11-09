---
name: shadcn-ops
description: "Use when building or fixing UI with shadcn/ui or in any project with a components.json: init, add, view, search, docs, info, presets and apply, Base UI vs Radix vs React Aria, Tailwind v4 theming with CSS variables, dark mode, admin dashboards (sidebar, dashboard and login blocks, data tables on TanStack Table, forms with Field and React Hook Form or TanStack Form, dialogs, sheets, toasts, charts, empty and loading states), monorepos, migrate, eject, registry authoring (registry.json, shadcn build), third-party registries and the shadcn MCP server. Runs the CLI pinned, never @latest; ships a project audit."
license: MIT
allowed-tools: "Read, Edit, Write, Glob, Grep, Bash(bash *shadcn-ops/scripts/*), Bash(pnpm exec shadcn *), Bash(npx --no shadcn *), Bash(yarn run shadcn *), Bash(bunx --no-install shadcn *), Bash(shadcn *), Bash(npx shadcn@4.23.0 *), Bash(pnpm dlx shadcn@4.23.0 *), Bash(yarn dlx shadcn@4.23.0 *), Bash(bunx shadcn@4.23.0 *)"
metadata:
  author: claude-mods
  related-skills: "react-ops, tailwind-ops, nextjs-ops, supply-chain-defense, a11y-ops, figma-ops, package-manager-ops"
---

# shadcn/ui Operations

**Why:** shadcn/ui copies component source into your project through a CLI that ships
several releases a month. Its docs and official agent skill run that CLI as `@latest`,
unpinned and pre-approved. This skill runs a pinned CLI, treats every registry as code you
are about to install, and goes deep on the admin dashboards most projects build with it.

> Versions verified 2026-11-10 against shadcn 4.23.0 (published 2026-10-27, no install
> scripts, Socket supply-chain score 97), ui.shadcn.com/docs and its llms.txt index. The pin
> and the other moving facts live in `assets/shadcn-facts.json`;
> `scripts/check-shadcn-facts.py --offline` keeps this text in step with it, and `--live`
> (weekly) fails when npm or the CLI moves.

## Hard rules

1. **Never run `shadcn@latest`**, a dist-tag (`@canary`, `@beta`), a range (`@4`), or an
   unversioned `pnpm dlx shadcn` / `yarn dlx shadcn`. Resolve the runner once per project:

   ```bash
   bash "<skill-dir>/scripts/shadcn-cmd.sh"     # {"prefix":"pnpm exec shadcn","source":"project",...}
   ```

   Then type that literal prefix in every command (`pnpm exec shadcn info --json`). This
   skill writes it as `$SHADCN`; don't store it in a shell variable, which neither survives
   between tool calls nor matches the pre-approved forms in `allowed-tools`. Order: the
   project's own devDependency, then a global `shadcn` of the pin's major, then
   `<pm> dlx shadcn@<pin>`. Exit 10 means run the frozen install first; exit 5 means nothing
   pinned is available.
2. **Read the project before writing code:** `$SHADCN info --json` gives the base, style,
   Tailwind version, aliases, resolved paths, `iconLibrary`, `isRSC` and installed
   components. Never assume the base, the icon library or the import alias.
3. **Third-party registries are untrusted code.** For anything not from `@shadcn`: `view`,
   then `add --dry-run`, then `add --diff` / `--view` per file, and read the dependencies,
   target paths and network calls before the real `add`. Never pick a registry for the user.
4. **`add` installs npm packages.** New ones follow the supply-chain rule: a 7-day cooldown
   and a behavioural scan (supply-chain-defense owns how), with the lockfile change committed
   beside the component.
5. **Installed components are the user's code.** Update with `add --dry-run` and `--diff`,
   merge by hand, and use `--overwrite` only with the user's OK, after a commit.
6. **Ask, and commit first, before project-wide rewrites:** `apply` (overwrites
   components), `init --force`, `migrate`, `add --all --overwrite`, and `eject`, which is
   irreversible.
7. **Write for the project's base.** Radix uses `asChild`; Base UI uses `render` (plus
   `nativeButton={false}` for non-buttons); React Aria keeps its own API. Select,
   ToggleGroup, Slider, Accordion and toasts differ too.
8. **Compose, don't restyle.** Existing components before markup, variants before classes,
   semantic tokens (`bg-primary`, `text-muted-foreground`) never raw colours, `gap-*` not
   `space-y-*`, items inside their groups, and a title on every Dialog, Sheet and Drawer.
9. **Don't add the shadcn MCP server to Claude Code.** It duplicates the CLI, runs in every
   session, and its documented config is unpinned. If a user insists, use the pinned
   project-scoped form in `assets/mcp.json.example`.
10. **Verify every change:** typecheck and build after an `add`, read the files it wrote
    (imports, icon library, composition), and check keyboard and screen-reader basics;
    a11y-ops runs full audits.

## Start here

1. Resolve the CLI (rule 1).
2. Audit the project. It only reads files; it never runs the CLI, a package manager or git:

   ```bash
   bash "<skill-dir>/scripts/run-python.sh" "<skill-dir>/scripts/shadcn-audit.py" .
   bash "<skill-dir>/scripts/run-python.sh" "<skill-dir>/scripts/shadcn-audit.py" apps/web --json | jq '.data[]'
   ```

   Exit 10 means findings (severity, id, `file:line`, message, fix; high first), 0 clean,
   3 no components.json (at a monorepo root it names the workspaces), 4 invalid JSON.
3. `$SHADCN info --json`, then `$SHADCN docs <component>` and fetch the URLs it prints
   before using a component whose API you haven't read in this session.
4. Find before you build: `$SHADCN search @shadcn -q "<need>"`, and blocks before pages.
5. Add, read what was written, fix imports and icons, typecheck.

## Route by task

| Task | Read |
|---|---|
| CLI commands and flags, the runner, updating installed components, bumping the pin | [cli-and-pinning.md](references/cli-and-pinning.md) |
| What `add` changes, trust by source, reviewing an item, private registries and tokens | [supply-chain-and-registries.md](references/supply-chain-and-registries.md) |
| components.json fields, styles, aliases, Tailwind v3 vs v4 | [components-json.md](references/components-json.md) |
| Base UI vs Radix vs React Aria: `asChild`/`render`, Select, toasts, changing base | [bases.md](references/bases.md) |
| Styling and composition rules, icons, which component for which need, chat UIs | [composition-rules.md](references/composition-rules.md) |
| Forms: Field, React Hook Form, TanStack Form, validation, server errors | [forms.md](references/forms.md) |
| Data tables: TanStack Table v9, row actions, server-side paging, states | [data-tables.md](references/data-tables.md) |
| Dashboard shell: blocks, sidebar, dialogs and sheets, toasts, page states, auth pages, dark mode | [admin-layouts.md](references/admin-layouts.md) |
| Charts and KPI cards (Recharts v3) | [charts.md](references/charts.md) |
| Theme tokens, custom colours, radius, presets, `apply` | [theming.md](references/theming.md) |
| A design system from a DESIGN.md or brand spec | [design-systems.md](references/design-systems.md) |
| `migrate`, Tailwind v3 to v4, React 19, `eject` | [migrations-and-eject.md](references/migrations-and-eject.md) |
| Monorepos (`init --monorepo`, two components.json files) | [monorepo.md](references/monorepo.md) |
| Publishing your own registry (`registry.json`, `build`, GitHub registries) | [registry-authoring.md](references/registry-authoring.md) |
| The shadcn MCP server | [mcp.md](references/mcp.md) |

## Admin dashboards at a glance

| Need | Use | Notes |
|---|---|---|
| The whole shell | `$SHADCN add dashboard-01 --dry-run`, then adapt | or a `sidebar-01`..`sidebar-16` block |
| Navigation | `Sidebar` (`collapsible="icon"`, tooltips on items), `Breadcrumb` | Cmd/Ctrl+B toggles |
| Lists | the data-table guide (TanStack Table v9) on `Table` | server-side paging when data is large |
| Create and edit | `Dialog` + `Field` forms; `Sheet` for side panels | validate on client and server |
| Delete and other irreversible actions | `AlertDialog` naming the action | never straight from a menu item |
| Feedback | Base UI `toast`; Radix and React Aria Sonner | one `<Toaster />` in the root layout |
| KPIs and trends | `Card` + `Badge`; `Chart` with `min-h-*` | colours from `--chart-1..5` |
| Loading, empty, failed | `Skeleton`, `Empty`, `Alert variant="destructive"` | distinguish "none yet" from "no matches" |
| Login and sign-up | `login-*`, `signup-*` blocks | layout only; wire your auth |
| Theme | `next-themes` (Next.js) or the Vite ThemeProvider; `.dark` tokens | check contrast in both |

New projects start on Tailwind CSS v4 and React 19 with `--base base` (the default) unless
told otherwise; check an existing project's lines with the audit before writing code for it.

## Scripts and assets

| Resource | Use |
|---|---|
| `scripts/shadcn-cmd.sh [--cwd DIR] [--prefix \| --json] [--pm PM] [--no-dlx]` | the pinned runner; default output is JSON `{prefix, source, version, pm, pin, installed}` |
| `scripts/shadcn-audit.py [DIR] [--json] [--ignore ID] [--checks]` | read-only audit; `--checks` lists the 20 check ids |
| `scripts/check-shadcn-facts.py --offline` | after editing the facts, SKILL.md or a reference: pin, allowed-tools, code blocks and prose agree |
| `scripts/check-shadcn-facts.py --live` | weekly: npm (pin age, majors, install scripts, ecosystem majors) and the pinned CLI's `--help`; exit 7 is advisory |
| `scripts/run-python.sh` | launches the `.py` scripts with the first real Python 3.8+ |
| `assets/shadcn-facts.json` | the pin, cooldown and age policy, commands, migrations, bases, styles, ecosystem majors |
| `assets/mcp.json.example` | a pinned, project-scoped `.mcp.json` for those who use the MCP server anyway |

The audit's checks: components.json shape (`config-missing-field`, `style-unknown`,
`style-deprecated`), files (`css-missing`, `tailwind-config-missing`, `tailwind-mismatch`),
aliases (`alias-unresolved`, `alias-missing`), the CLI pin (`shadcn-css-orphan`,
`cli-not-installed`, `cli-range-open`, `cli-unlocked`, `cli-old-major`), unpinned runs in
package.json scripts, README, AGENTS.md, CLAUDE.md and MCP configs (`unpinned-cli`,
`unpinned-mcp`), registries (`third-party-registry`, `registry-insecure-url`,
`registry-literal-secret`, values never printed), `react-pre-19` and `monorepo-mismatch`.
`--ignore <id>` records a deliberate exception.

## Boundaries

| Topic | Owner |
|---|---|
| Tailwind itself: utilities, `@theme`, the v4 engine, plugins | tailwind-ops |
| React patterns, hooks, state, error boundaries | react-ops |
| Next.js App Router: server/client boundary, Server Actions, caching, `loading.tsx`/`error.tsx` | nextjs-ops |
| Vetting a package: cooldown, Socket, IOCs, install scripts | supply-chain-defense |
| Lockfiles, package managers, workspaces, npx discipline | package-manager-ops |
| Accessibility audits and WCAG | a11y-ops |
| Figma designs to shadcn code (Figma MCP, Code Connect) | figma-ops |

## Sources

- ui.shadcn.com/docs (the llms.txt page index): CLI, components.json, theming, Tailwind v4,
  forms, data table, sidebar, chart, toast, sonner, dark mode, monorepo, registry, MCP, and
  the changelog through October 2026.
- `shadcn --help` for every command of 4.23.0; npm registry metadata; Socket's score.
- shadcn-ui/ui source: the init templates, the registry base definitions (which packages
  `init` installs, including the `shadcn` devDependency) and the `eject` command.
- The official shadcn skill (shadcn-ui/ui `skills/shadcn/`, MIT licence, last changed
  2026-10-14), ported and adapted; each reference that draws on it says so.
