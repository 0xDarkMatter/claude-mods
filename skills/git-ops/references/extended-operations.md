# Extended Operations

Recipes beyond the release workflow, which stays in SKILL.md with its local/remote boundary rules.

### Changelog Generation

When user asks to "generate changelog" or "update CHANGELOG.md":

1. **Inline (T1):** Gather commit history for the range
2. **Dispatch to git-agent (T2):** Categorise commits, format as Keep a Changelog, write file

### PR Workflow (Full Cycle)

When user says "create a PR" or "open a PR":

1. **Inline (T1):** Check branch state, diff against main
2. **Gather context:** What was the user working on? What does the conversation tell us about the goal?
3. **Dispatch to git-agent (T2):** Create PR with contextual title and body
4. **Report:** PR number, URL, summary

### Branch Cleanup

When user asks to "clean up branches" or "delete merged branches":

1. **Inline (T1):** List merged branches
   ```bash
   git branch --merged main | grep -v "main\|master\|\*"
   ```
2. **Show list to user** - this is a T3 preflight (deletion)
3. **On confirmation:** Dispatch to git-agent to delete them

### Semantic Versioning Analysis

When user asks "what should the next version be":

1. **Inline (T1):** Analyse commits since last tag
2. Categorise by Conventional Commits
3. Report recommended bump with reasoning

### Conflict Resolution Support

When user encounters merge conflicts:

1. **Inline (T1):** `git status` to show conflicted files
2. **Inline (T1):** Read conflict markers in each file
3. **Present options:** ours, theirs, manual resolution
4. **After resolution:** Dispatch to git-agent (T2) for staging and continue
