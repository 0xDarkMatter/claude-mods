# Repo Visibility Default

When publishing a new repo to GitHub, **default to private**. Public is opt-in only.

## Why

User-stated preference (codified 2026-04-26): wants control over what's published openly. Private-by-default prevents accidental public exposure of work-in-progress, unfinished projects, or material that needs review before going public.

## Application rules

- `gh repo create` → always pass `--private` unless the user has **explicitly** said "public" / "make it public" / "publish openly" for *this specific repo*.
- Existing private → public flips also require explicit approval. Use:
  ```bash
  gh repo edit <org>/<repo> --visibility public --accept-visibility-change-consequences
  ```
- "Push to GitHub" / "publish this" / "ship it" alone = **private**.
- Even if a repo is going to the 0xDarkMatter org and other repos there are public, do not infer this one should be public.
- When proposing the publish plan, surface the visibility decision as a **flippable line** the user can read and react to:

  > Creating as **private** at github.com/0xDarkMatter/<repo> — say 'public' to flip.

  Not buried in a flag soup.

## Per-repo override

If a user says "make this one public" for a specific repo, treat that as authorization for that single repo. It does not change the default for future repos. Always ask again on the next new repo.

## What private mode loses

For visibility, list these in the publish plan so the user can make an informed call:

- No public README rendering on github.com (still works for the repo owner)
- No public clone/star/fork
- GitHub Actions still works but minutes count against private quota
- Releases are private
- Issues/PRs are private

If any of these matter for the project's purpose (e.g. a skill plugin that needs public install URLs, a portfolio piece), the user will likely flip to public — but that's their call to surface.
