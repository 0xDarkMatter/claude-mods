# Supply Chain Tooling Landscape

Socket.dev is the behavioural-scanning leader, but a single vendor is not defense
in depth. This file maps the wider ecosystem - **almost all free / open-source** -
onto the layers (detection, interception, hygiene, self-integrity) and says which
to reach for when. Per-tool detail, commands and verified gotchas, layer by layer:
[tooling-by-layer.md](tooling-by-layer.md).

## Contents

1. [The picture in one table](#the-picture-in-one-table)
2. [When to use which](#when-to-use-which)
3. [How the controls interact](#how-the-controls-interact)
4. [Minimum viable set + dependency note](#minimum-viable-set--dependency-note)

## The picture in one table

| Tool | Layer | Cost | Engine | Covers |
|---|---|---|---|---|
| **Socket.dev** | 1 | Free CLI + $0 tier; paid for scale | Behavioural (static + LLM), hosted feed | npm, PyPI, Go, Maven, RubyGems |
| **GuardDog** (Datadog) | 1 | Free / OSS | Behavioural heuristics + Semgrep rules, local | npm, PyPI, GitHub Actions |
| **OSV-Scanner** (Google) | 1 | Free / OSS | CVE/advisory (OSV.dev) | ~broad: npm, PyPI, Go, Maven, crates, …|
| **`npm audit` / `pip-audit`** | 1 | Free / built-in | CVE/advisory | npm / PyPI |
| **`npm audit signatures`** | 1 | Free / built-in | Registry signature + provenance check | npm |
| **`ignore-scripts` config** | 2 | Free / built-in | Disables lifecycle scripts | npm, pnpm, yarn |
| **`socket` wrapper** | 2 | Free | Intercepts install pre-execution | npm / npx |
| **lockfile-lint** | 2 | Free / OSS | Lockfile URL/host/https/integrity validation | npm, yarn |
| **zizmor** (Trail of Bits) | 3 | Free / OSS | Static analysis of GitHub Actions | GHA workflows |
| **Harden-Runner** (StepSecurity) | 2/3 | Free for public repos | Runtime egress monitoring/blocking on CI runners | GitHub Actions runners |
| **gitleaks** | 3 | Free / OSS | Secret scanning (token leak detection) | any repo |
| **Trivy** (Aqua) | 1/3 | Free / OSS | SCA + IaC + secrets + container | many |
| **Bumblebee** (Perplexity) | 4 | Free / OSS | On-disk inventory + IOC catalog match | npm/pypi/go/rubygems/composer + editor & browser extensions + MCP (**macOS/Linux only**) |
| **`exposure-check.py`** (this skill) | 4 | Free | IOC catalog match, cross-platform | npm/pnpm/yarn/bun, PyPI, Composer, Cargo, Go, RubyGems + editor extensions (runs on Windows, where Bumblebee can't) |

> The whole table reinforces the thesis: **you can stand up real defense in depth
> at $0.** Paid tiers buy noise-reduction and scale, not the core capability.

## When to use which

- **Before adding a dependency** → Socket depscore (MCP/CLI) + optionally GuardDog
  for an offline second opinion; `scripts/preinstall-check.sh` for release age.
- **On every PR** → Socket GitHub app (behavioural) + OSV-Scanner (CVE breadth).
- **At the install command** → `socket` wrapper or `ignore-scripts`; `lockfile-lint`
  on the committed lockfile.
- **Auditing CI** → zizmor (static workflow analysis) + Harden-Runner (runtime
  egress). Rotate tokens; gitleaks for leaks.
- **Checking this machine** → `scripts/integrity-audit.sh`.

Mono-sourcing on any one tool recreates a single point of failure. The 2026 worms
adapted to each defensive response in turn — layered, multi-engine coverage is the
point.

## How the controls interact

These do **not** form a pipeline — nothing pipes one tool's output into another.
They are independent verdicts at different points in a dependency's lifecycle, with
deliberate redundancy at the two highest-value chokepoints.

| Lifecycle stage | Control(s) | How they relate |
|---|---|---|
| Considering a package | Socket depscore (primary); GuardDog *situational* | **Overlapping** — Socket is the daily driver; add GuardDog only for offline/privacy/auditable second opinions, not a parallel daily run |
| Is it too new? | `preinstall-check.sh` | Orthogonal — answers release age, not maliciousness |
| Install runs | `ignore-scripts` / socket wrapper / `pre-install-scan.sh` | Alternatives at one point; `ignore-scripts` is the most aggressive (kills all lifecycle scripts) |
| Lockfile committed | lockfile-lint | Orthogonal — validates the lock's resolved URLs, not the package contents |
| PR opened | Socket app **+** OSV-Scanner | Complementary — behavioural vs CVE breadth. **OSV supersedes `npm audit`** (run one, not both) |
| CI runs | zizmor **+** Harden-Runner | **Complementary, not redundant** — zizmor fixes the misconfigured door (static, pre-run); Harden-Runner alarms if someone walks through (runtime egress) |
| This machine | `integrity-audit.sh` | Orthogonal — the victim side |

**The only real integration:** `integrity-audit.sh` invokes `zizmor` when it's on
PATH (and degrades to a weaker `rg` check, loudly, when it isn't).

**The one conflict to plan for:** Harden-Runner's `egress-policy: block` will choke
`socket ci`, installs, and anything that phones a registry — you must allowlist the
package registry plus `api.socket.dev` / `mcp.socket.dev` when you tighten it. Start
in `audit` mode, learn the baseline, then block with an allowlist.

**Overlap summary:** redundant pairs (Socket/GuardDog, Socket/OSV at the PR) are
intentional — different engines, different blind spots. Complementary pairs
(zizmor/Harden-Runner) cover different phases. OSV is an upgrade over `npm audit`,
not an addition to it.

## Minimum viable set + dependency note

**This is a menu, not a mandatory stack.** Running all of it on every project is
overkill. The minimum viable set — all free, ~1 hour to stand up — is four things:

1. depscore MCP in Claude Code (`claude mcp add --transport http socket-mcp https://mcp.socket.dev/`)
2. Socket GitHub app on the repo
3. Renovate `minimumReleaseAge: 7 days` on production deps
4. `npm config set ignore-scripts true` where build hooks aren't needed

Everything beyond that is situational: add GuardDog when you want an offline second
engine, OSV when you need CVE breadth across many ecosystems, zizmor + Harden-Runner
when CI holds publish credentials.

**None of these are dependencies of this skill.** Its scripts require only baseline
tooling (bash, coreutils, `curl`; `jq` for `preinstall-check.sh` and `--json`; Python 3.8+ stdlib for the
`.py` scripts, launched via `scripts/run-python.sh`) and treat every supply-chain
tool above as optional — `command -v`-gated
with graceful fallback (`preinstall-check.sh` runs without `socket`;
`integrity-audit.sh` runs without `zizmor`, telling you it's the weaker check). You
can adopt zero, some, or all of the tools without affecting whether the skill loads
or its scripts run.
