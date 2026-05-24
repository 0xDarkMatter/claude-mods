# Socket.dev — CLI, MCP, and pricing reference

Accurate command surface as of May 2026. Distilled from
[docs.socket.dev/docs/socket-cli](https://docs.socket.dev/docs/socket-cli),
[socket.dev/pricing](https://socket.dev/pricing), and
[github.com/SocketDev/socket-mcp](https://github.com/SocketDev/socket-mcp). Verify
against the live docs before quoting versions — Socket iterates fast.

## Is it free? — yes, and free covers this threat

The **Socket CLI is open-source and free to install and run.** A **free account**
($0) is enough to defend against the 2026 worm campaign. Paid tiers buy
noise-reduction (reachability) and scale, not the core malware detection.

| Capability | Free ($0) | Team ($25/dev/mo) | Business ($50/dev/mo) | Enterprise |
|---|---|---|---|---|
| `socket` CLI | ✅ | ✅ | ✅ | ✅ |
| Malware blocking + AI behavioural analysis, 70+ risk types | ✅ | ✅ | ✅ | ✅ |
| Private repos | ✅ unlimited | ✅ | ✅ | ✅ |
| GitHub app (PR risk comments) | ✅ | ✅ | ✅ | ✅ |
| **depscore MCP (no API key)** | ✅ | ✅ | ✅ | ✅ |
| Scans / month | 1,000 | 5,000 | unlimited | unlimited |
| Members | 3 | 10 | unlimited | unlimited |
| Repository labels | 1 | 3 | unlimited | unlimited |
| Reachability analysis (cuts ~60% CVE false positives) | ❌ | ✅ | ✅ | ✅ |
| SSO/SAML, SBOM import/export, compliance | ❌ | ❌ | ✅ | ✅ |
| GitHub Actions + AI-model scanning | ❌ | ❌ | ✅ | ✅ |
| Function-level reachability (~90% CVE reduction) | ❌ | ❌ | ❌ | ✅ |
| GitLab / Bitbucket / Azure DevOps, SCIM, audit logs | ❌ | ❌ | ❌ | ✅ |

> **Open-source projects:** "Socket is and will always be free to use for
> open-source." Qualifying OSS teams can request a **complimentary Team account**
> (the larger scan cap + reachability) for free.

**Recommendation:** start on Free. The 1,000-scan cap and 3 members are generous
for a small team trialling one repo. Move to Team only when CVE false-positive
noise (reachability) or seat count justifies $25/dev.

## Installation

```bash
npm install -g socket          # CLI is published as the `socket` npm package
```

> ⚠️ Terminology correction: older write-ups (and the originating briefing) call
> the wrappers "safe npm" / "safe pip". The current CLI is `npm install -g socket`
> then `socket npm …` / `socket wrapper on`. There is **no documented `socket pip`
> wrapper** — for PyPI use `socket scan` against the manifest + the GitHub app +
> the depscore MCP rather than expecting a pip wrapper.

## Authentication

```bash
socket login                   # interactive; stores API token locally
socket logout                  # remove stored credentials
SOCKET_SECURITY_API_TOKEN=xyz socket <command>   # non-interactive / CI
```

The depscore MCP **remote** needs no login at all (see below).

> Verified: `socket package score` and `socket scan` **require a token** — without
> `socket login` they exit 2 with "This command requires a Socket API token". The
> login/account is free, but the CLI is not zero-auth. If you want behavioural
> scoring with *no* account at all, use the depscore MCP remote.

## Core commands

| Command | Purpose |
|---|---|
| `socket scan create [path]` | Generate a behavioural security scan of a project's manifests |
| `socket scan list` | List existing scans |
| `socket scan --report` | Validate a scan against your org's security/license policies |
| `socket scan github` | GitHub-specific scanning |
| `socket package score <ecosystem> <name> [version]` | Retrieve a package's security score |
| `socket ci` | Run policy-enforced scanning in a CI pipeline |
| `socket npm` / `socket npx` | Wrapper that routes npm/npx through Socket before lifecycle scripts run |
| `socket wrapper on` / `off` | Toggle workspace-wide aliasing of `npm`/`npx` through Socket |
| `socket raw-npm` / `socket raw-npx` | Bypass the wrapper for one invocation |
| `socket fix` | Apply security updates |
| `socket optimize` | Apply package overrides |
| `socket threat-feed` | Real-time threat intelligence feed |
| `socket analytics` | Security-health dashboards |
| `socket manifest` / `socket manifest cdxgen` | Manifest operations / generate via cdxgen |
| `socket organization` / `socket repository` / `socket audit-log` | Org / repo / audit-log management |

### Common flags

| Flag | Effect |
|---|---|
| `--json` | JSON output (pipe to `jq`) |
| `--markdown` | Markdown output |
| `--config '<JSON>'` | Override config for this run |
| `--dry-run` | Validate inputs without executing |
| `--help` / `--version` | Per-command help / CLI version |

## depscore MCP server — the Claude Code win (free, no key)

The Socket MCP server exposes a **`depscore`** tool so an AI assistant can query a
package's behavioural/quality score *before* suggesting you add it. Two variants:

### Remote (recommended — zero auth, zero install)

```bash
claude mcp add --transport http socket-mcp https://mcp.socket.dev/
```

No API key. This is the fastest way to give Claude Code behavioural package
scoring.

### Local / self-hosted (stdio, needs a free API key)

```bash
claude mcp add socket-mcp -e SOCKET_API_KEY="your-api-key-here" \
  -- npx -y @socketsecurity/mcp@latest
```

The only required permission scope for the API key is `packages:list` (lets the
server query package metadata for scores). Create the key from a free Socket
account.

> Package: [`@socketsecurity/mcp`](https://socket.dev/npm/package/@socketsecurity/mcp).
> Note the irony — you can have Socket score its own MCP package before installing
> it.

## GitHub app (layer 1 for PRs)

Install Socket as a GitHub App on a repo. It auto-evaluates every change to
`package.json` and other manifests; when a PR adds a dependency it leaves a comment
indicating the risk profile. Works on the free tier including private repos
(subject to the 1,000-scan/month cap).

## Sources

- CLI guide: <https://docs.socket.dev/docs/socket-cli>
- Pricing: <https://socket.dev/pricing>
- MCP server: <https://github.com/SocketDev/socket-mcp>
- MCP for Claude Desktop: <https://docs.socket.dev/docs/socket-mcp-for-claude-desktop>
- GitHub app: <https://docs.socket.dev/docs/socket-for-github>
