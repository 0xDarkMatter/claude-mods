# The Session Store: Resolving a Wrapper to Its Transcript

Detail behind SKILL.md's mental model: how a Desktop session wrapper maps to its transcript file, and where that mapping surprises you.

**The uuid-mismatch trap.** The wrapper filename uuid (`local_<uuid>.json` / `sessionId`) does **not** name the transcript — the transcript file is named by the wrapper's `cliSessionId`, a different uuid (e.g. wrapper `local_6577b24c-…` → transcript `e640a2a8-….jsonl`). And the transcript's parent dir is the *munged cwd* (`D:\code\myapp\.claude\worktrees\funny-hypatia-5e54f7` → `D--code-myapp--claude-worktrees-funny-hypatia-5e54f7`), which occasionally doesn't derive from the wrapper's recorded cwd at all. All toolbox modes resolve via `cliSessionId` at the expected munged path first, then fall back to scanning every project dir for `<cliSessionId>.jsonl`.
