# Registries and supply chain: what `add` brings in

`shadcn add` is an installer. It writes source files into your project, can add CSS and
environment variables, and runs your package manager to install the npm packages an item
declares. Treat each part by who wrote it. Facts checked against ui.shadcn.com/docs
(registry, namespaces, authentication, components-json, changelog) on 2026-11-10. The
behavioural vetting of npm packages is owned by the supply-chain-defense skill; this file
says where it applies, not how it works.

## Contents

- [What one add can change](#what-one-add-can-change)
- [Trust by source](#trust-by-source)
- [Reviewing an item before you add it](#reviewing-an-item-before-you-add-it)
- [The npm packages behind components](#the-npm-packages-behind-components)
- [Configuring namespaced and private registries](#configuring-namespaced-and-private-registries)
- [Never guess the registry](#never-guess-the-registry)

## What one add can change

A registry item (registry-item.json) can carry:

| Field | Effect in your project |
|---|---|
| `files` | new or replaced source files; `registry:file` and `registry:page` items name a `target` path anywhere in the project |
| `dependencies`, `devDependencies` | npm packages installed with your package manager, at the versions the item names (or the newest) |
| `registryDependencies` | more items pulled in, from shadcn or from other registries |
| `cssVars`, `css`, `tailwind` | edits to your global CSS (variables, layers, utilities) |
| `envVars` | variables written to your env file |
| `docs` | text printed after the install |

So an item from an unknown source is code that runs in your build and your users' browsers,
plus packages that run at install time (lifecycle scripts) and at build time.

## Trust by source

| Address | Who publishes | Treat as |
|---|---|---|
| `button`, `@shadcn/button` | shadcn | first-party, still reviewed when it overwrites local edits |
| `@acme/item` (a namespace in components.json) | whoever runs that URL | third-party: review every time |
| `owner/repo/item` | anyone with a public GitHub repo | third-party; pin it to a commit: `owner/repo/item#<sha>` |
| `https://.../item.json`, `./item.json` | whoever serves or wrote that file | third-party |
| `@v0/...` | output generated in v0 | generated code: review like a stranger's pull request |

Being listed in the registry directory (ui.shadcn.com/docs/directory) means a registry is
discoverable, not that anyone reviewed it. Private GitHub registries (supported since
August 2026 through the GitHub CLI's credentials or `GH_TOKEN`) are as trustworthy as the
people with write access to that repository.

## Reviewing an item before you add it

```bash
$SHADCN view @acme/data-grid                      # metadata, dependencies, file contents
$SHADCN add @acme/data-grid --dry-run             # the files it would write in THIS project
$SHADCN add @acme/data-grid --diff                # diffs of the first five files
$SHADCN add @acme/data-grid --view lib/fetcher.ts # one file in full
```

Read, in order:

1. **Dependencies.** Every new npm package goes through the supply-chain-defense checks
   below before the real `add`.
2. **Targets.** Files outside `components/`, `lib/`, `hooks/` (config files, `.env*`,
   scripts, CI files, `.claude/` or other agent folders) need a reason.
3. **Code that reaches out.** `fetch` to hosts the item doesn't need, `eval`,
   `dangerouslySetInnerHTML`, reads of `process.env` or `document.cookie`, analytics.
4. **CSS and env changes** that the `--diff` of your global CSS and env file shows.
5. **Imports.** Third-party items often hard-code `@/components/ui/...`; rewrite them to
   this project's aliases (`$SHADCN info --json`) and its `iconLibrary`.

Only then run the `add` without `--dry-run`, and read the written files once more.

## The npm packages behind components

Even first-party components pull packages: `@base-ui/react`, `radix-ui` or
`react-aria-components` (by base), `class-variance-authority`, `cn`, `lucide-react` (or the
configured icon library), and, depending on the component and base, packages such as
`recharts` (chart), `cmdk` (command), `sonner`, `react-day-picker` (calendar),
`embla-carousel-react` (carousel), `input-otp` and `react-resizable-panels`. Guides add
more that you install yourself (`@tanstack/react-table`, `react-hook-form`, `zod`,
`next-themes`), and a third-party item can name anything. `view` shows an item's list.

They follow this repository's supply-chain rule (rules/supply-chain.md, the
supply-chain-defense skill): a 7-day cooldown after a release before it reaches a build, and a
behavioural scan (Socket score or the depscore MCP), not only `npm audit`. In practice:

- Prefer letting the lockfile decide: `add` uses your package manager, so an existing locked
  version stays. A new package arrives at its newest version: check it before committing.
- pnpm 11+ applies `minimumReleaseAge` (default one day) to installs; raise it in
  `pnpm-workspace.yaml` to match the cooldown if the team agrees.
- Commit the lockfile change with the component, so review sees both.

## Configuring namespaced and private registries

```json
{
  "registries": {
    "@acme": "https://registry.example.com/r/{name}.json",
    "@private": {
      "url": "https://registry.example.com/private/{name}.json",
      "headers": { "Authorization": "Bearer ${REGISTRY_TOKEN}" },
      "params": { "version": "v2" }
    }
  }
}
```

- Namespaces start with `@`; the URL must contain `{name}`; `@shadcn` is built in.
- `${VAR}` in a URL, header or param is read from the environment. Keep the value in
  `.env.local` (git-ignored) or the CI secret store; never a literal token in
  components.json, and HTTPS only. `$SHADCN registry add @acme` writes an entry for you.
- Query-string tokens end up in logs and shell history: prefer a header.

The audit reports every configured registry (`third-party-registry`), plain-http URLs and
literal credentials (`registry-literal-secret`, value never printed).

## Never guess the registry

When the user asks for "a login block" or "a fancy data grid" without naming a source, ask
which registry. `@shadcn` is a sensible offer; a community registry is the user's decision,
because it is their trust call. Search first: `$SHADCN search @shadcn -q "login" -t block`.
