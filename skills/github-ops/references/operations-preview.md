# Operations: What Needs a Preview

Per-operation preview requirements for issues and pull requests (hard rule 8). Playbooks: [issue-ops.md](issue-ops.md), [pr-ops.md](pr-ops.md).

### Issues

Reads (no preview): `gh issue view <n>`, `gh issue view <n> --comments`, `gh issue list`, `gh api repos/<o>/<r>/issues/<n>` (for fields not in the default view).

Writes:

| Op | Command | Preview? |
|---|---|---|
| Create | `gh issue create --title --body` | **Yes** (title + body) |
| Comment | `gh issue comment <n> --body` | **Yes** (body) |
| Edit title/body | `gh issue edit <n> --title --body` | **Yes** |
| Triage (label/assign/milestone) | `gh issue edit <n> --add-label … --assignee … --milestone …` | No (mechanical) |
| Close / reopen | `gh issue close <n>` / `gh issue reopen <n>` | No, **unless** closing with a comment — preview the comment |
| Transfer | `gh issue transfer <n> <target-repo>` | No (mechanical), but confirm target with user |

See `references/issue-ops.md` for full playbooks, triage flow, and closing-comment templates.

### Pull Requests

Reads (no preview): `gh pr view <n>`, `gh pr view <n> --comments`, `gh pr list`, `gh pr diff <n>`, `gh pr checks <n>`, `gh pr checks <n> --watch`, `gh api repos/<o>/<r>/pulls/<n>/comments` (inline review comments).

Writes:

| Op | Command | Preview? |
|---|---|---|
| Create | `gh pr create --title --body` | **Yes** (title + body) |
| Comment | `gh pr comment <n> --body` | **Yes** |
| Review (approve / request changes / comment) | `gh pr review <n> --approve --body …` | **Yes** (body, if any) |
| Edit title/body | `gh pr edit <n> --title --body` | **Yes** |
| Edit labels / reviewers | `gh pr edit <n> --add-label … --add-reviewer …` | No (mechanical) |
| Mark ready (un-draft) | `gh pr ready <n>` | No (mechanical) |
| Merge | `gh pr merge <n> --squash` (or `--merge` / `--rebase`) | No body to preview by default, but **explicit user approval required** + run pre-merge gate first. If passing `--subject` / `--body`, preview those (they become the commit message on `main`) |
| Close | `gh pr close <n>` | No, **unless** closing with a comment — preview the comment |
