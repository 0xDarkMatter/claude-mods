# Vetting Sentry's packages

Evidence labels are defined in `SKILL.md`. For the general dependency gate, cooldown and
behavioural scan, see `supply-chain-defense`.

## Contents

- Choosing the version
- Reading a package without installing it
- Socket scores on 2026-11-06 [measured]
- `@sentry/agent-plugin` (0.4.1)
- The wizard

## Choosing the version

Check the cooldown against the version you will actually install.

Sorting npm's `time` map by date misleads here, because Sentry publishes backports. On 2026-10-28
both `11.10.0` and a later-stamped `10.78.0` went out [measured from the registry], so "newest by
date" can name an older major. Use `dist-tags.latest` to find the target, then read that version's
own timestamp:

```bash
curl -s https://registry.npmjs.org/@sentry%2fcloudflare | \
  jq -r '."dist-tags".latest as $v | "\($v) \(.time[$v])"'
```

On 2026-11-06 that gave `11.11.0`, one day old, which fails a 7-day cooldown, so the right pin was
`11.10.0`, nine days old [measured]. Those particular numbers will age. The method won't.

Pin every `@sentry/*` package to the same exact version: `@sentry/astro` depends on its siblings at
exact versions [code], so a mismatch installs two copies of the SDK.

## Reading a package without installing it

A package's published code is what runs, and you can read it without executing anything:

| Need | How |
|---|---|
| File list with integrity hashes | `https://unpkg.com/<pkg>@<version>/?meta` [measured] |
| One file | `https://unpkg.com/<pkg>@<version>/<path>` |
| Everything, offline | Download the tarball from the registry and extract it to an empty scratch directory. Don't run anything in it |
| Lifecycle scripts | `curl -s https://registry.npmjs.org/<pkg>/<version> \| jq .scripts` |
| Deps | Same URL, `.dependencies` |
| Unpacked size | Same URL, `.dist.unpackedSize` |

To answer "does this SDK still have option X?", grep the unpacked build for it. That's how the
`sendDefaultPii` removal shows up in seconds.

`dist.unpackedSize` is the package, not your bundle. `@sentry/cloudflare` 11.10.0 is about 3 MB
unpacked [measured], with cjs, esm, dev and prod builds and source maps, yet a minimal Worker bundles
to 171 KB [measured]. Measure the Worker bundle before and after, from build output.
`wrangler deploy --dry-run` sits too close to the deploy boundary to reach for casually.

## Socket scores on 2026-11-06 [measured]

| Package | supplyChain | Notes |
|---|---|---|
| `@sentry/astro` 11.10.0 | 99 | |
| `@sentry/wizard` 9.1.0 | 98 | |
| `@sentry/cloudflare` 11.10.0 | 91 | |
| `@sentry/agent-plugin` 0.4.1 | 75 | Lowest of the four |

A score is one input and moves over time. Look it up again.

## `@sentry/agent-plugin` (0.4.1)

**It doesn't instrument your app.** It installs Sentry's assistant plugin only, so running it won't
add error reporting [code, README; not run].

What it does:

- For Claude Code: registers the official marketplace if needed, then runs
  `claude plugin install sentry@claude-plugins-official`. It can run
  `claude mcp login plugin:sentry:sentry` for the Sentry MCP [code]. Sentry's docs describe the MCP
  server as configured during install [docs].
- `--no-interactive` installs into **every detected agent** (Claude Code, Codex, Cursor, Grok) [README].
- `org-slug#code` only builds a prompt, so an agent can report progress to Sentry's onboarding run
  [README]. It isn't a credential.
- **It sends its own telemetry**, with `tracesSampleRate: 1`, to a hard-coded DSN unless you pass
  `--no-telemetry` or set `DO_NOT_TRACK` to `1`, `true` or `yes` [code].
- **A `SENTRY_DSN` in your environment overrides that hard-coded DSN** [code]. So if your shell has
  a project DSN set, the installer's crash reports and traces go to your project [inferred].

Pinning `@sentry/agent-plugin@0.4.1` pins little below it:

- `@sentry/node`, `listr2`, `citty` and the inquirer packages float on carets [code].
- It brings in `@sentry/node` v10, not the v11 you may be installing.
- `node-pty 1.2.0-beta.14` is pinned, but it's a beta with `install` and `postinstall` scripts [code].
- `npx` resolves this tree outside your lockfile, so it sidesteps a workspace's cooldown [inferred].

**The simpler route** if you want the plugin in Claude Code: run the native command yourself, and
skip the npm tree and its telemetry altogether:

```bash
claude plugin install sentry@claude-plugins-official
```

That is the command the package would run [code]. We haven't run it here. A plugin brings its own
skills and an MCP server with access to your Sentry data, which is a separate decision from adding
the SDK. Read what it asks for.

## The wizard

`npx @sentry/wizard@latest` is the route Sentry's docs give for source maps and for some framework
setups. It:

- Logs you in, picks a project, installs packages, and configures your build and CI [docs].
- Is unpinned by its documented command, so it's a day-zero install each time. Pin a version that has
  aged past your cooldown.
- Writes the demo defaults discussed in `SKILL.md`. Review its diff line by line as you would a
  stranger's pull request.

Its version moves fast: 9.0.0 landed one week before 9.1.0 [measured].

Doing the same setup by hand from the docs takes little longer, gives you the same result, and
leaves you knowing what each line does.
