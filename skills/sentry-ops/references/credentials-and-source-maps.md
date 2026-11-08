# Credentials and source maps

Evidence labels are defined in `SKILL.md`.

## DSN

A DSN tells the SDK where to send events. It only allows submitting events, with no read
access, and Sentry calls it safe to keep public [docs]. Browser builds inline it, so it can't
be secret anyway. Call it semi-public: someone who has it can send you junk events, using up
quota and adding noise. You can rotate or revoke it in the project's Client Keys
settings [docs].

Keep it out of committed config anyway, because config per environment is what lets you run with
a fake DSN or none:

| Where | How |
|---|---|
| Worker | `env.SENTRY_DSN`, from `.dev.vars` locally. A plain var or a secret both work; a secret stays out of dashboards |
| Client | Build-time public variable, or a literal |
| Secret scanners | Exclude DSNs: Sentry publishes a pattern for that [docs: token formats] |

Empty or absent DSN means nothing is sent [docs; measured]. That is your off switch, and it
lets preview environments stay silent.

## Auth token

A real credential. Here it has exactly one job: uploading source maps during the build.

| Type | Use | Notes |
|---|---|---|
| Organization token | **Default for CI** [docs] | Limited, fixed permissions. Prefix `sntrys_` |
| Internal integration | Full API access on behalf of an org | Custom scopes |
| Personal token | Your own API calls and CLI | Prefix `sntryu_`. Not for CI: it stops working when the person leaves [docs] |

Rules:

- One token per use, so you can revoke one without breaking the others [docs].
- **Build environment only.** It must never reach the Worker's env, client code, or any
  `PUBLIC_` variable. Runtime code has no use for it.
- Locally, `.env.sentry-build-plugin` is read automatically by the plugin [docs]. Gitignore it
  before creating it. Vite doesn't load `.env` into `process.env` when evaluating its config, so
  `process.env.SENTRY_AUTH_TOKEN` can be empty unless you use `loadEnv` [docs].
- Organization tokens are shown once [docs]. Put one in your secret manager straight away.
- The wizard can generate an organization token [docs], and it needs to store that somewhere
  [inferred]. Check `git status` afterwards.
- Scanning: `sntrys_`/`sntryu_` prefixes are searchable. Org tokens run about 180 to 250
  characters, so don't match a fixed length [docs]. Bare 64-hex legacy and integration tokens
  have no prefix, so look at the names around them: `SENTRY_AUTH_TOKEN`, `authToken` [docs].

## The source map decision

Without maps, stack traces in Sentry point at minified code. With them, you get file, line and
function names. The price:

- A credential in your build, as above.
- Your source goes to a third party.
- Build and deploy now depend on Sentry's API being reachable, and a token being present. Decide
  what a failed upload does. The plugin takes an `errorHandler` [code].
- A release must link the maps to the events. Workers can use `SENTRY_RELEASE`, or a
  `CF_VERSION_METADATA` binding [docs].

It's a sound choice for most production apps, just a separate one from "report errors". Reporting
works without it, so ship errors first if that gets you moving.

### Facts from the code

From `@sentry/astro` 11.10.0's integration [code, not run]:

- Upload setup is skipped under `astro dev`.
- `sourcemaps.disable: true` turns it off.
- If you never set a sourcemap option, it enables maps and deletes them from `dist/` after upload
  (`filesToDeleteAfterUpload`). Your own setting changes that, so check what your build leaves
  behind, because a public `.map` file publishes your source.
- `org`, `project` and `authToken` fall back to `SENTRY_ORG`, `SENTRY_PROJECT`,
  `SENTRY_AUTH_TOKEN`.
- **The build plugin's own telemetry defaults to on** (`telemetry ?? true`). A build is therefore
  not automatically traffic-free. Pass `telemetry: false` when you're proving a setup.

Wrangler's `upload_source_maps` is a different thing. It is Cloudflare's setting for Cloudflare's
own stack traces. Sentry's docs also mention it for Workers source maps, so read that guide
before assuming which destination you're configuring.

### Proving a build sends nothing

[open] We haven't measured what the build plugin does with no token and `telemetry: false`. To
check it, run the build with no token in the environment and watch outbound connections, or at
least read the build log. Don't infer it from the options.
