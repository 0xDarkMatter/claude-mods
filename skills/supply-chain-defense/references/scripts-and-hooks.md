# Scripts, launcher, hooks and portability

What ships in `scripts/`, how to launch it, the optional hooks that live outside
this folder, and what the skill does and does not need when copied on its own.

## Contents

1. [Launching the scripts](#launching-the-scripts)
2. [The scripts](#the-scripts)
3. [Portability: what is and is not in this folder](#portability-what-is-and-is-not-in-this-folder)
4. [Hook setup — two checkpoints for the two ways a dep enters](#hook-setup--two-checkpoints-for-the-two-ways-a-dep-enters)

## Launching the scripts

Paths are relative to the skill folder.

- **`.py` scripts: `bash scripts/run-python.sh scripts/<name>.py [args]`.** The
  launcher tries `python3`, `python`, then `py` and runs the first that passes a real
  Python 3.8+ check. On Windows `python3` is often the Microsoft Store alias, which
  exits 49 without running anything, and it is also what the scripts'
  `#!/usr/bin/env python3` shebang finds, so don't execute them directly.
  `bash scripts/run-python.sh --which` prints the interpreter it would use; exit 5
  means no Python 3.8+ is on PATH.
- **`.sh` scripts: `bash scripts/<name>.sh [args]`.**
- **`.ps1` (Windows): `pwsh -NoProfile -File scripts/phone-home-monitor.ps1 [args]`.**

## The scripts

All seven follow one contract: `--help` with EXAMPLES, `--json` for
machine-readable output, stdout = data / stderr = progress, semantic exit codes
(0 ok, 2 usage, 3 not-found, 4 invalid, 5 missing-dep, 7 unavailable, **10 = signal
found** — review items / inside-cooldown / exposed / behavioural finding).
Pipe-friendly: `--json | jq`.

**A check that could not run never reports clean.** When a script cannot do part of
its job (a missing tool, an unreachable registry, a log or file it may not read) it
exits 5 or 7, not 0, and names what went unchecked on stderr, whatever `-q` says.
When it also has findings, 10 wins and the gap rides along in the JSON envelope
(`postinstall-audit.py --live` → `meta.live`, `config-drift-check.py` →
`meta.unscanned`).

**Dependencies.** Every script's *default* mode needs only baseline tooling: bash +
coreutils + `curl` for the `.sh` scripts (`jq` for `preinstall-check.sh`, which
parses registry JSON with it, and otherwise only for `--json`), Python 3.8+
(stdlib only) for the `.py` scripts, PowerShell 7 on Windows for the `.ps1`. `scan-extensions.sh
--deep` auto-detects `guarddog`+`semgrep` and uses them when present; when absent it
runs inventory + recency and *loudly recommends* the on-demand install rather than
reporting a behavioural scan it never ran (which would be the same false-clean
GuardDog itself hits without semgrep). Nothing heavyweight is kept on the machine by
default. All named tools (socket, guarddog, semgrep, zizmor, OSV-Scanner) are an
optional *menu* — see [tooling-landscape.md](tooling-landscape.md) → "How the controls
interact" for the minimum viable set.

| Script | Purpose | Side effects |
|---|---|---|
| `scripts/integrity-audit.sh` | Scan AI-tool configs (Claude Code/Desktop, Gemini, MCP host JSON) + editor settings (VS Code, Cursor, Windsurf, VSCodium) for injected persistence hooks/MCP servers; flag workflows with live OIDC publish trust (uses `zizmor` if installed). Exit 10 if anything to review. | Read-only |
| `scripts/preinstall-check.sh` | Given package specs (npm incl. scoped `@scope/pkg[@version]`, PyPI, Composer, Cargo, Go), report registry publish age, flag any inside the cooldown window, route to `socket` if available. Exit 10 if any inside cooldown; 7 if any package's age stayed unknown (registry unreachable, or no publish time for that version - listed on stderr, `unchecked_reason` in `--json`); 5 without `curl` or `jq`. | Read-only (queries registries) |
| `scripts/exposure-check.py` | Match on-disk **npm (package-lock/pnpm/yarn) / PyPI / Composer / Cargo / Go / RubyGems** lockfiles **and installed editor extensions** against an IOC catalog (`assets/exposure-catalog.json`) — the "are we running a named-bad version/extension?" check. Supports a `*` wildcard for tag-rewrite attacks. Exit 10 if exposed. Catalog format borrowed from Bumblebee. | Read-only |
| `scripts/phone-home-monitor.ps1` | **Windows outbound-connection tripwire** — map every outbound TCP connection to owning process + parent chain + signing status; flag IOC endpoints (`assets/network-ioc.json`), `node_modules`/Temp binaries, package-manager children, interpreter→raw-IP. Sources: Sysmon EID 3 (`-Sysmon`, preferred) or TCP-table polling (default). `-Watch`/`-InstallTask` for continuous capture with a ring-buffer JSONL log. Exit 10 on medium+ findings; 7 if a capture source failed and 5 if it refused this session (run elevated) - an empty result from a failed read is never clean, and `-Watch` logs each uncollected poll as `collection-failed`. Live modes need Windows (gated on `[Environment]::OSVersion.Platform`); `-InputJson` replay runs anywhere. | Read-only (except `-InstallTask`, which registers a logon scheduled task) |
| `scripts/postinstall-audit.py` | **On-disk behavioural scan** — walks installed `node_modules` + Python `site-packages` under `--root` dirs and flags what already-unpacked packages *do*: shell/downloader lifecycle scripts, credential-path reads paired with exfil endpoints, env harvesting, obfuscation, persistence writes, files modified after install (tamper). Two-signal combos to avoid `node_modules` false-positives. Incremental per-package fingerprint cache (daily-runnable); `--deep` confirms flags with GuardDog; `--live` checks the registry still serves a flagged npm version (unpublished = IOC). Exit 10 on findings ≥ `--min-severity`; a `--live` registry outage keeps 10 and is reported as `meta.live: "unavailable"` plus a stderr ERROR (`--live` only checks flagged packages). See [postinstall-audit.md](postinstall-audit.md). | Read-only |
| `scripts/config-drift-check.py` | **Repo-integrity / config-as-code scanner** (layer 6) — scans build configs (`vite/tailwind/webpack/next/rollup/postcss/svelte/astro.config.*`), `.vscode/tasks.json`, and `package.json` scripts for PolinRider/EtherHiding injection: blockchain explorer-API / RPC dead-drop endpoints (extends from `assets/network-ioc.json`), `eval`/`new Function`/shell-exec, Buffer-XOR decode loops, outbound network in a config, `_0x..`/long-escape obfuscation, an obfuscated appended blob, and `tasks.json` `runOn:folderOpen` auto-run. `--staged` for pre-commit (scans the **index** copy, the bytes the commit will carry, not the working tree), `--root` for CI. Exit 10 on a finding; 5 if a config could not be read (`meta.unscanned`). Zero-dep. See [repo-integrity.md](repo-integrity.md). | Read-only |
| `scripts/scan-extensions.sh` | **Unknown-bad** triage of installed editor extensions / Claude plugins / skills. Default = zero-dep **inventory + recency** (no false positives). `--deep` auto-detects `guarddog`+`semgrep`: runs the behavioural scan if present (exit 10 on a finding), else runs inventory only and *loudly recommends* the on-demand install — never a false-clean. | Read-only |

```bash
bash scripts/integrity-audit.sh --json | jq '.data.review[]'
bash scripts/preinstall-check.sh --pip requests fastapi@0.110.0 --json | jq '.data[] | select(.inside_cooldown)'
pwsh -NoProfile -File scripts/phone-home-monitor.ps1 -Json | jq '.data.findings[]'
```

`tests/run.sh` is an offline-deterministic self-test covering every script, the
launcher, the copy-alone contract, and (in the claude-mods layout) the hooks, against
crafted fixtures — run it after any edit: `bash tests/run.sh` (exit 0 = all pass).

## Portability: what is and is not in this folder

This folder runs on its own (it is copied standalone into other plugins):

- **Self-contained:** every script, `assets/` (the IOC catalogs), these references,
  the launcher, and `tests/run.sh`. Each script finds its catalog relative to itself.
- **Optional, outside the folder: terminal panels.** In the claude-mods repo the
  `.sh`/`.ps1` scripts render framed panels via `skills/_lib/term.sh` / `term.ps1`. When
  that lib is absent they fall back to plain 7-bit ASCII framing; stdout data and exit
  codes are identical either way. The `standalone` block in `tests/run.sh` copies the
  folder alone and pins this.
- **Optional, outside the folder: hooks.** `pre-install-scan.sh`,
  `manifest-dep-scan.sh` and `config-change-guard.sh` live in claude-mods' `hooks/`,
  not here. Nothing in this folder needs them; when you have them, wire them as below.
  `tests/run.sh` exercises them only when it finds them beside `skills/`.
- **Optional tools:** `socket`, `guarddog` + `semgrep`, `zizmor`, OSV-Scanner, Sysmon.
  Every script `command -v`-gates them and says when it ran a weaker check.

## Hook setup — two checkpoints for the two ways a dep enters

A dependency reaches a local machine two ways, and each gets an advisory hook:

- **`pre-install-scan.sh`** (PreToolUse / `Bash`) — fires on install verbs
  (`npm/pnpm/yarn/bun install|add`, `pip install`, `uv add`, `composer
  require|install|update`, `gem install`, `cargo add`). Surfaces the cooldown +
  `socket` equivalent. Set
  `SUPPLY_CHAIN_BLOCK=1` for a hard gate; otherwise advisory.
- **`manifest-dep-scan.sh`** (PostToolUse / `Write|Edit`) — fires when the agent
  *edits a manifest* (`package.json`, `requirements*.txt`, `composer.json`,
  `Cargo.toml`, `go.mod`, `Gemfile`, `pyproject.toml`) and the change adds a version
  spec — the Claude-Code path the install hook misses. Advises depscore + cooldown
  before install. High-signal: silent on version bumps / metadata edits.

Both read the tool call as JSON on stdin (`.tool_input`), falling back to `$1`, and
advise through one `additionalContext` JSON envelope on stdout - plain stdout from a
tool hook goes to the debug log, never the model (`hooks/README.md`, "Output channels").

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "bash \"$HOME/.claude/hooks/pre-install-scan.sh\"", "timeout": 5 } ] }
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit", "hooks": [
        { "type": "command", "command": "bash \"$HOME/.claude/hooks/manifest-dep-scan.sh\"", "timeout": 5 } ] }
    ]
  }
}
```
