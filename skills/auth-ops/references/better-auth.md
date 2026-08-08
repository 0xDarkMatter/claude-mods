# Better Auth (TypeScript)

Deep-dive reference for [Better Auth](https://www.better-auth.com) — the framework-agnostic TypeScript authentication library: owned auth (your database, your users table) with batteries included (social login, passkeys, 2FA, organizations) via a plugin system.

> **Freshness note:** Better Auth moves fast — plugin names, option shapes, and adapter APIs change between minor versions. The patterns below are architectural and stable, and specifics were verified against better-auth.com/docs as of 2026-08 — but **re-verify exact API signatures against the current docs before applying them.** Where this file and the live docs disagree, the live docs win. The docs ship an `llms.txt` index (`better-auth.com/llms.txt`) — fetch it to enumerate current pages before deep-diving.

## Where It Sits

| Approach | You own | They own | Examples |
|----------|---------|----------|----------|
| **Hand-rolled** (Lucia-style: library-assisted sessions, you write the flows) | Everything — flows, tokens, edge cases, security hardening | Nothing | Lucia (now a learning resource), custom JWT/session code per `jwt-sessions.md` |
| **Auth library, your DB** | Data, deployment, customization | Flow implementation, plugin features, security patches | **Better Auth**, Auth.js/NextAuth |
| **Hosted IdP / auth SaaS** | Integration code | Everything else — including your user data | Auth0, Clerk, WorkOS, Supabase Auth, Cognito |
| **Identity-aware proxy** | App authorization | Authentication entirely, at the network edge | Cloudflare Access (see `cloudflare-access.md`) |

Better Auth's pitch: the feature ceiling of a hosted IdP (social login, passkeys, 2FA, orgs/multi-tenant, magic links) without surrendering user data, per-MAU pricing, or the login UX to a third party. Users live in **your** database in **your** schema (extended by plugins), and every flow runs in your process.

### When to choose which

```
Who are your users, and who should own the credential risk?
│
├─ Staff/partners behind an existing IdP, internal tools?
│  └─ Identity-aware proxy (Cloudflare Access) — don't build login at all
│     └─ see cloudflare-access.md
│
├─ Consumer/SaaS product, TypeScript stack, want to own user data?
│  └─ Better Auth
│     ├─ Full-featured via plugins (passkeys, 2FA, orgs, magic links)
│     ├─ Your DB, your schema, no per-MAU bill
│     └─ You own uptime and patching of the auth path
│
├─ Compliance/enterprise-sales pressure (the buyer's checklist names a
│  vendor), or a team with no capacity to own auth code?
│  └─ Hosted IdP (Auth0/Clerk/WorkOS)
│     ├─ Someone else's pager owns the auth path
│     ├─ Costs scale per-MAU; user data lives with the vendor
│     └─ Note: enterprise SSO alone no longer forces this — Better Auth
│        ships sso (SAML/OIDC) + SCIM plugins; the trade is ownership
│
└─ Unusual auth model no library expresses (exotic tokens, research)?
   └─ Hand-rolled on the primitives in jwt-sessions.md / implementation.md
      └─ Budget for the hardening checklist you inherit (rate limits,
         enumeration, rotation, reset flows — see implementation.md)
```

The Lucia lesson: its maintainers deprecated the library and turned it into a tutorial, concluding that a thin session library saves too little over hand-rolling while still hiding the parts you need to understand. The ecosystem's answer to "I want auth *implemented*, not just assisted" is a full-featured library — which in TypeScript today usually means Better Auth.

## Core Setup: Server Instance + Client

Two halves, mirrored: a **server instance** (`betterAuth(...)`) that owns the database and exposes an HTTP handler + server API, and a **client** (`createAuthClient(...)`) whose methods call those endpoints. Plugins come in pairs too — a server plugin and its client counterpart.

```typescript
// server: auth.ts — the single source of truth for auth config
import { betterAuth } from 'better-auth';

export const auth = betterAuth({
  database: /* adapter — see next section */,
  emailAndPassword: {
    enabled: true,
    // hand the email-sending to YOUR mailer; Better Auth calls these hooks
    sendResetPassword: async ({ user, url }) => { /* send url to user.email */ },
  },
  socialProviders: {
    github: {
      clientId: process.env.GITHUB_CLIENT_ID!,
      clientSecret: process.env.GITHUB_CLIENT_SECRET!,
    },
  },
  plugins: [/* passkey(), twoFactor(), organization(), ... */],
});
```

```typescript
// client: auth-client.ts — framework-specific import path
// (react / vue / svelte / solid / vanilla variants exist)
import { createAuthClient } from 'better-auth/react';

export const authClient = createAuthClient({
  baseURL: 'https://app.example.com', // where the auth routes are mounted
  plugins: [/* client halves of the server plugins */],
});

// usage: authClient.signIn.email({...}), authClient.signIn.social({provider: 'github'}),
// authClient.signUp.email({...}), authClient.signOut(), authClient.useSession() (hook)
```

The server instance exposes:

| Surface | What | Use for |
|---------|------|---------|
| `auth.handler` | A `Request => Response` fetch-style handler serving all auth routes (conventionally mounted at `/api/auth/*`) | Wiring into your framework's router |
| `auth.api.*` | Server-side callable endpoints (e.g. get the session from request headers) | Middleware, server components, RSC/loader code |

Mount the handler once; never build login/logout routes by hand next to it.

## Database Adapters

Better Auth owns its tables (user, session, account, verification — plus plugin tables) inside **your** database, through an adapter:

| Adapter family | Notes |
|----------------|-------|
| Kysely-based direct connections | Postgres / MySQL / SQLite via the built-in layer |
| ORM adapters | Drizzle, Prisma, MongoDB adapters wrap your existing ORM instance |
| Serverless/edge databases | Work through the same adapters (e.g. D1 via Drizzle) — check current docs for your combination |

Schema management is CLI-driven: the Better Auth CLI can **generate** the schema (migration files / ORM schema for your adapter) and, for direct connections, **migrate** the database. Plugins add columns/tables; re-run generate after adding one. Treat the generated schema as owned artifacts in your repo — review and commit them like any migration.

**Secondary storage** (optional): a KV/Redis-style store can be configured alongside the database for hot data (sessions, rate-limit counters), keeping per-request reads off the primary DB. On serverless platforms this is the natural home for session lookups.

## Session Model

Better Auth's default is **database-backed sessions with a cookie** — the `jwt-sessions.md` "session" column, not the JWT column:

- Sign-in creates a session row; the browser holds an httpOnly, secure session cookie.
- Every request resolves cookie → session row → user. Revocation is immediate (delete the row); there's no stateless-token revocation problem. The API ships revocation at three granularities — one session (`revokeSession`), all-but-current (`revokeOtherSessions`), and all (`revokeSessions`) — plus `revokeOtherSessions: true` on password change, which should be your default there.
- Expiration is a sliding window: sessions live `expiresIn` (default 7 days) and are re-extended once older than `updateAge` (default 1 day) — so an active user never logs in again, an idle one ages out.
- **Cookie cache** (`session.cookieCache`): an optional short-lived signed cookie carrying the session data (`enabled`, `maxAge`, an encoding `strategy`, auto-`refreshCache`, and a `version` string that bulk-invalidates all cached sessions when bumped). Most requests skip the DB read and only re-validate on cache expiry. This is the latency escape hatch for serverless/edge — with immediate-revocation traded down to "within the cache window."
- **Secondary storage** takes over session reads by default when configured; `storeSessionInDatabase` keeps the DB copy too, and `preserveSessionInDatabase` retains revoked-session rows for audit.
- A JWT plugin exists for handing tokens to *other* services (a separate API consuming identity), not as a replacement for the cookie session between your SPA and your server.

Server-side session access is the integration point for everything else in your app:

```typescript
// in middleware / a loader / an RSC — shape per current docs
const session = await auth.api.getSession({ headers: request.headers });
if (!session) return unauthorized();
// session.user is YOUR user row (plus plugin fields) — feed it to your
// authorization layer (roles, tenant scope) exactly as in authorization.md
```

The same fail-closed layering as every other auth source applies: Better Auth authenticates; your role/scope binding on `session.user` authorizes. Never trust identity from a request body.

## Email/Password + Social Providers

**Email/password** is a config flag plus hooks. Better Auth implements the flows (signup, sign-in, verification, password reset with single-use expiring tokens, password hashing) and calls *your* functions to actually send email — it deliberately does not ship a mailer. Turn on email verification for real deployments; wire the reset/verification senders to your provider (Resend, SES, Cloudflare Email, …). The hardening in `implementation.md` (rate limiting, enumeration-safe responses) is largely handled by the library — configuration, not reimplementation.

**Social providers** are config entries per provider (OAuth2/OIDC under the hood — the flows from `oauth2-oidc.md`, implemented for you):

- Built-ins for the majors (Google, GitHub, Apple, Microsoft, Discord, …) plus a **generic OAuth plugin** for any OIDC-conformant provider.
- Redirect URI is derived from where the handler is mounted (`<baseURL>/api/auth/callback/<provider>` by convention) — register that with the provider.
- **Account linking** connects a social login to an existing user with the same verified email (configurable — auto-link only trusted, email-verifying providers; see gotchas).
- The `account` table stores the provider linkage and tokens per user — one user, many linked providers.

## Plugins: Passkeys, 2FA, Organizations

Plugins are the differentiating layer. Each has a server half (routes + schema) and a client half (typed methods). Representative set — check current docs for the full catalog:

| Plugin | Gives you | Notes |
|--------|-----------|-------|
| **passkey** | WebAuthn registration + sign-in | The `implementation.md` passkey checklist, implemented: challenge handling, credential storage, multiple credentials per user |
| **twoFactor** | TOTP + backup codes (OTP-on-login) | Enable/verify flows, recovery codes; gate it on your risk model |
| **organization** | Orgs/teams, membership, roles, invitations | The multi-tenant building block — org rows, member rows with roles, invitation email hooks; pair with your data-layer tenant scoping (`authorization.md`) — the plugin manages *membership*, your queries must still enforce *scope* |
| **admin** | User administration (list, ban, impersonate) | Impersonation should stay audited — log the real admin identity on writes |
| **magicLink** / **emailOTP** | Email magic-link or emailed-code sign-in | You send the email; the library handles token issue/verify |
| **sso** / **scim** | Enterprise SAML/OIDC SSO and SCIM user provisioning | The plugins that let a self-hosted Better Auth answer enterprise-IT checklists — the capability that used to force a hosted IdP |
| **oidcProvider** / **oauthProvider** / **mcp** | Your app *issues* tokens — act as an OIDC/OAuth provider (including for MCP clients) | Turns the app into the IdP for its own satellite services |
| **apiKey** / **bearer** / **jwt** | Machine callers and token handoff to other services | Keep machine routes structurally separate from human session routes (same doctrine as `cloudflare-access.md` service-auth section) |
| **genericOAuth** | Any OIDC-conformant provider not built in | For long-tail IdPs |

The full catalog is considerably larger (40+ official plugins: username, anonymous, phoneNumber, multiSession, oneTap, oneTimeToken, deviceAuthorization, captcha, haveIBeenPwned breached-password checks, siwe, payments integrations like stripe/polar, openAPI, test-utils, …) — enumerate the current list via the docs' llms.txt rather than from memory.

Plugin doctrine: add the server plugin, add its client counterpart, re-run schema generation, and let the plugin own its flow end-to-end — don't hand-build a parallel 2FA/passkey path beside it.

## Middleware Integration (incl. Hono)

Better Auth speaks fetch-standard `Request`/`Response`, so any framework that exposes those integrates the same way: **route `/api/auth/*` to `auth.handler`, and read the session in middleware for everything else.**

```typescript
// Hono (Workers/Node/Bun) — verified against the official integration docs 2026-08
import { Hono } from 'hono';
import { auth } from './auth';

const app = new Hono();

// 0. If the frontend is on another origin: CORS middleware BEFORE the routes,
//    with credentials: true (and credentials: 'include' on the client fetch).

// 1. Mount the auth routes — GET and POST both reach the handler
app.on(['POST', 'GET'], '/api/auth/*', (c) => auth.handler(c.req.raw));

// 2. Session middleware for your app routes
app.use('/api/*', async (c, next) => {
  const session = await auth.api.getSession({ headers: c.req.raw.headers });
  if (!session) return c.json({ error: 'unauthorized' }, 401);
  c.set('user', session.user);      // then bind roles/tenant scope server-side
  await next();
});
```

Cross-origin cookie shape, when the SPA and API live on different hosts: same-site subdomains → enable `crossSubDomainCookies` and keep `SameSite=Lax`; genuinely different domains → `sameSite: "none"` + `secure: true` cookie attributes (and accept the third-party-cookie fragility that entails — a shared parent domain is the saner architecture, per `jwt-sessions.md`).

Framework notes (details per current docs):

- **Next.js**: a catch-all route handler (`app/api/auth/[...all]/route.ts`) exporting the handler's GET/POST; session via `auth.api.getSession({ headers: headers() })` in server components/actions. Treat proper session checks in data-access code — not just in `middleware.ts` — as the real gate (Next middleware alone has been bypassable; CVE-2025-29927).
- **SvelteKit / Nuxt / SolidStart / TanStack Start / Astro / Remix**: same two moves via each framework's handler-mounting idiom.
- **Express/Fastify (Node)**: adapt Node req/res to fetch `Request` (helpers exist — `toNodeHandler` or the framework's own adapter).
- **Serverless/edge (Workers)**: works — pair with an edge-resident DB or secondary storage so session reads aren't cross-region; enable cookie caching.

One rule regardless of framework: the auth config object lives in **one** module; handler mounting and session reads both import it. Two `betterAuth()` instances with drifted config is a subtle way to break sessions.

## Extending the User Model

The user/session tables are extensible from config (`user.additionalFields`-style options): declare extra fields, re-run schema generation, and the server types pick them up; the client can infer them via the type-inference plugin so `session.user` stays end-to-end typed. Use this for *identity-adjacent* fields (display name, locale, onboarding flags). Keep *authorization* data (roles, tenant membership) in your own domain tables keyed by user id — mixing authz into the auth library's schema couples your permission model to its migrations.

## Migrating In

Official migration guides exist for Auth0, Clerk, NextAuth/Auth.js, Supabase Auth, and WorkOS — start there. The architectural points that make migrations tractable:

- **Password hashes import.** The password hashing functions are configurable, so existing bcrypt/argon2 hashes can be verified as-is (or verified-then-rehashed on first login) instead of forcing a global reset.
- **Users/accounts map cleanly**: exported users become `user` rows; per-provider identities become `account` rows. Social-login users need no secret material at all — only the provider linkage.
- **Sessions don't migrate.** Plan for a one-time global re-login at cutover; communicate it.

## Operational Notes

- **Secrets**: a `BETTER_AUTH_SECRET`-style signing secret plus per-provider OAuth credentials — platform secret store, never committed (see `implementation.md` on secret handling).
- **Rate limiting**: built-in on auth endpoints (tighter on sign-in/sign-up) — configure storage (memory/DB/secondary) appropriately for multi-instance deployments; memory-only limits don't coordinate across serverless instances.
- **Hooks/lifecycle**: before/after hooks on auth events (user created, session created, …) are the place for provisioning side-effects — creating a tenant on signup, audit rows, welcome email. Keep them idempotent.
- **Upgrades**: fast-moving library — read the changelog on every minor bump, re-run schema generation after upgrading or adding plugins, and keep an integration test that exercises sign-up → sign-in → session → sign-out against a real database.

## Common Gotchas

| Gotcha | Why It's Dangerous | Fix |
|--------|--------------------|-----|
| Pinning API snippets from memory or old tutorials | The API surface shifts between minors; stale option names fail silently or at type-check | Verify against current docs; keep Better Auth in one module so upgrades touch one file |
| Building login/reset routes beside the mounted handler | Two auth paths, one hardened, one yours | Everything auth goes through `auth.handler` / `auth.api` / plugins |
| Skipping schema regeneration after adding a plugin | Runtime errors on missing tables/columns | Re-run CLI generate/migrate on every plugin add and version bump |
| Auto-linking accounts from providers with unverified emails | Account takeover: attacker registers your email at a lax provider, links into your account | Restrict auto-linking to trusted, email-verifying providers; require verification otherwise |
| Auth checks only in framework middleware (Next.js) | Middleware can be bypassed (CVE-2025-29927-class bugs) | Check the session in the data-access layer / route handlers too |
| DB-per-request session reads on edge/serverless with a distant DB | Latency tax on every request | Cookie cache and/or secondary storage near the compute |
| Treating org membership as data scoping | Membership says who's *in* the org; queries still need tenant filters | Enforce tenant scope at the repository/query layer (`authorization.md`) |
| Memory rate-limit storage on multi-instance deploys | Each instance counts separately — limits are ~N× looser | Database or secondary-storage backed rate limiting |
| Secrets in client-reachable config | Provider secrets leak to the bundle | Server module only; client gets nothing but `baseURL` and plugin client halves |
| Ignoring the mailer hooks (no verification/reset emails wired) | Signup verification and password reset silently can't complete | Wire `sendResetPassword` / verification senders to a real mailer before launch |

## See Also

- `jwt-sessions.md` — the session/cookie model Better Auth implements (and when raw JWTs fit instead)
- `oauth2-oidc.md` — the flows underneath `socialProviders`
- `implementation.md` — password hashing, MFA, rate limiting fundamentals (what the library is doing for you)
- `authorization.md` — roles/tenant scoping to layer on `session.user`
- `cloudflare-access.md` — the delegate-it-entirely alternative for staff/internal apps
