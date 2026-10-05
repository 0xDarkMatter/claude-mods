# Repo Integrity: Isolation, Detection and Containment

The operational half of [repo-integrity.md](repo-integrity.md) (which holds the kill
chain, keys, branch protection, the audit log and the checklist): walls around
untrusted code and builds, VS Code Workspace Trust, the `config-drift-check.py`
detector, and how far containment has to reach once a poisoned repo is found.
Sections keep the numbering of the parent file.

## Contents

1. [4. Isolation — untrusted code and the build both get walls](#4-isolation--untrusted-code-and-the-build-both-get-walls)
2. [5. VS Code Workspace Trust + auto-run tasks](#5-vs-code-workspace-trust--auto-run-tasks)
3. [6. The pre-commit + CI detector](#6-the-pre-commit--ci-detector)
4. [7. Containment — the real blast radius is everyone who *built* it](#7-containment--the-real-blast-radius-is-everyone-who-built-it)

## 4. Isolation — untrusted code and the build both get walls

- **Disposable environments for untrusted repos.** A fork, a candidate's take-home, or
  anything external is opened in a **devcontainer / throwaway VM / Codespace**, never
  in your primary checkout with your keys mounted. This is the direct counter to Stage
  1: the malicious `.vscode/tasks.json` or `.woff2` detonates in a container with no
  credentials and no push access, then is destroyed.
- **Build isolation.** Builds run in **ephemeral CI containers with no standing
  secrets** — secrets are short-lived, scoped, and injected per-job, so a build-time
  loader (Stage 2) that does fire finds nothing durable to steal and cannot push
  anywhere. Pair with egress control (e.g. Harden-Runner) so a build reaching out to a
  blockchain explorer API / RPC node is *blocked and logged*, not silently allowed.
- **No mounting your real `~/.ssh`, `~/.aws`, or `~/.claude` into a container that runs
  untrusted code.**
- **Agentic dev tooling is a force-multiplier — scope it.** An AI coding agent (Claude
  Code, etc.) with repo write access and the ability to run build commands is exactly
  the capability this attack abuses: it reads and writes across many repos and executes
  code. Agents should hold **no standing credentials**, run with **sandboxed
  file/network/exec scope**, and have their repo writes pass the **same signing + review
  gates as a human's** — an agent push is not a trusted push.

## 5. VS Code Workspace Trust + auto-run tasks

Stage 1's quietest vector is `.vscode/tasks.json` with
`"runOptions": {"runOn": "folderOpen"}` — a task that executes the moment you open the
folder, before you read a line of code.

- **Keep Workspace Trust enabled** (`security.workspace.trust.enabled: true`, the
  default). An **untrusted** (Restricted Mode) folder will **not auto-run tasks**,
  won't run debug configs, and disables workspace-scoped settings that could launch
  code. Open anything external as *untrusted* first.
- **`task.allowAutomaticTasks: off`** (the default is `off`) so folder-open tasks never
  auto-run even in a trusted folder without an explicit "Allow Automatic Tasks".
- Treat a repo that *ships* a `folderOpen` task as suspicious until you've read it —
  `config-drift-check.py` flags `tasks.json` auto-run entries.
- Don't blanket-trust parent folders (`security.workspace.trust.untrustedFiles` /
  trusted-folders list) — that re-enables auto-run for everything underneath.

## 6. The pre-commit + CI detector

[`scripts/config-drift-check.py`](../scripts/config-drift-check.py) is the on-disk half
of this defense. It scans a repo's build-config and editor-task files for the Stage 2
injection signatures — appended/obfuscated/minified blobs, new `eval` / `new Function`
/ Buffer-XOR / dynamic-require / outbound-fetch code, blockchain explorer-API / RPC
dead-drop endpoints, and `tasks.json` `runOn: folderOpen` auto-run — and exits **10**
on a finding. Wire it both as a **pre-commit hook** (catch it before it's committed)
and as a **CI status check** (catch a force-pushed injection at the gate):

`--staged` reads each config from the git **index**, not the working tree: the
commit carries the staged bytes, and a clean file on disk can sit beside a poisoned
staged one. Any non-zero exit should block - `5` means a config could not be read.

```bash
# pre-commit (.git/hooks/pre-commit or a pre-commit framework hook); S = this skill's scripts/
bash "$S/run-python.sh" "$S/config-drift-check.py" --staged || exit 1

# CI step (fails the job on a finding; --json for a machine-readable report)
bash "$S/run-python.sh" "$S/config-drift-check.py" --root . --json
```

It is zero-dependency (Python stdlib) and read-only. A finding is an incident: read the
flagged file, check the commit's signature + server-side push timestamp
([repo-integrity.md §3](repo-integrity.md#3-the-audit-log-is-ground-truth--git-dates-are-not)), and
rotate any credential the build could have touched.

**Treat it as one signal, not the fix.** It is a heuristic scanner, and a determined
adversary evades heuristics: the payload can be **obfuscated to read like a plausible
plugin import**, **hidden in a local module the config merely `require()`s** (dodging a
config-file-only scan), or **split across files**. This skill already learned the limit
of grep-style heuristics on obfuscated/minified code (the `scan-extensions` experience —
both false positives and evasion). Its real value is raising the attacker's cost and
catching the un-obfuscated majority; the controls that *don't* depend on out-guessing the
obfuscator are the deterministic ones — **egress-denied builds** (a build that can't
reach the dead-drop can't fetch the payload) and **touch-to-sign keys**. Pair them; do
not lean on the scanner alone.

## 7. Containment — the real blast radius is everyone who *built* it

When a poisoned repo is found, the instinct is "scrub the commits, revoke the key." That
under-scopes it. The Stage-2 payload activates **on build** — so anyone who *pulled and
built* a poisoned repo ran the loader and is now potentially infected. The reported
blast radius was not "22 repos"; it was "every machine that built any of those 22 repos."
Containment must therefore:

- **Trace and re-image every machine that built a poisoned repo**, not just the
  originally-infected host.
- **Rotate every credential the infected machine(s) could read** — not just the deploy
  key: npm tokens, cloud keys, SSH keys, `.env` secrets, **GitHub session tokens / PATs**
  (the ones that enable the
  [§2 takeover](repo-integrity.md#the-bypass-this-control-does-not-survive-on-its-own--account-takeover)), and any wallet material.
- **Audit what shipped to customers** during the injection window — if a poisoned build
  artifact was published or deployed, the internal incident is now a *downstream*
  supply-chain incident. Build provenance / artifact attestation (SLSA, GitHub Artifact
  Attestations) is what lets you answer this with confidence.
- **Establish a signed baseline** of the config files so re-injection is immediately
  visible on the next `config-drift-check.py` run.
