# Admin fixture

Add a component with the pinned devDependency:

```bash
pnpm exec shadcn add button
pnpm exec shadcn add @shadcn/sidebar --dry-run
```

One-off use outside the project pins the exact release: `npx shadcn@4.23.0 info`.
Registry items such as `@shadcn/button` are not CLI runs.
