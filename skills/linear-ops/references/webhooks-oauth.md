# Webhooks and OAuth

Building a receiver or an app. `[O]` Linear's developer docs, `[I]` inferred. Seen 2026-11-05. Nothing here was exercised against a
live app.

## Contents

- [Webhook facts](#webhook-facts)
- [Verify every delivery](#verify-every-delivery)
- [Webhook pitfalls](#webhook-pitfalls)
- [OAuth endpoints and scopes](#oauth-endpoints-and-scopes)
- [Tokens](#tokens)
- [Actor](#actor)
- [Where doc and changelog disagree](#where-doc-and-changelog-disagree)

## Webhook facts

- Resources: Issues, Issue attachments, Issue comments, Issue labels, Comment reactions, Projects, Project updates, Documents,
  Initiatives, Initiative Updates, Cycles, Customers, Customer Requests, Users, Issue SLA, OAuthApp revoked `[O]`.
- Agent categories: `AgentSessionEvent`, `AppUserNotification`, `PermissionChange` `[O]`.
- Actions: `create`, `update`, `remove`. SLA actions: `set`, `highRisk`, `breached` `[O]`.
- Headers: **`Linear-Signature`** (hex HMAC-SHA256 of the raw body), `Linear-Delivery` (UUID v4), `Linear-Event`, `Linear-Timestamp`
  (ms), `User-Agent: Linear-Webhook` `[O]`.
- Respond 200 within **5 seconds**. Retries: 3, after **1 minute, 1 hour, 6 hours**. Persistently failing webhooks may be disabled and
  need manual re-enabling `[O]`.
- Quotas since 2026-10: 30 per team, 50 per workspace `[O, changelog]`.
- Creating or reading webhooks needs admin or the `admin` scope `[O]`.

## Verify every delivery

Compute over the **raw bytes**, compare in constant time, then check `webhookTimestamp` in the parsed body is within 60 seconds `[O]`.

```javascript
import crypto from "node:crypto";

export function verifyLinear(rawBody, signature, secret, now = Date.now()) {
  const expected = crypto.createHmac("sha256", secret).update(rawBody).digest();
  const given = Buffer.from(signature ?? "", "hex");
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) return false;
  return Math.abs(now - JSON.parse(rawBody).webhookTimestamp) <= 60_000;
}
```

`@linear/sdk/webhooks` also offers `LinearWebhookClient`, `LINEAR_WEBHOOK_SIGNATURE_HEADER` and `LINEAR_WEBHOOK_TS_FIELD` `[O]`.

## Webhook pitfalls

- **A body parser that runs first breaks verification** `[O]`. In Express use `express.raw()` on the route; in Hono read
  `c.req.raw.arrayBuffer()` or `text()` before parsing `[I]`.
- Acknowledge fast and do the work in a queue, because the 5-second limit counts `[I]`.
- Dedupe on `Linear-Delivery`, since retries repeat events `[I]`.
- An update event fired by your own write can loop: skip events your own actor caused `[I]`.
- The agent-session webhook category shows session UI to customers as soon as it's enabled `[O]`.
- Outbound IPs were updated in 2026-09; check `https://linear.app/docs/security` if you allowlist `[O]`.

## OAuth endpoints and scopes

- Authorize `https://linear.app/oauth/authorize`, token `https://api.linear.app/oauth/token`, revoke
  `https://api.linear.app/oauth/revoke` `[O]`.
- Scopes: `read` (always), `write`, `issues:create`, `comments:create`, `timeSchedule:write`, `admin`. Agent: `app:assignable`,
  `app:mentionable`, `customer:read|write`, `initiative:read|write` `[O]`.
- App manifests exist at `https://linear.app/developers/oauth-app-manifests` `[O]`.

## Tokens

- **Access tokens last 24 hours. All apps moved to refresh-token rotation on 2026-04-01.** Each refresh returns a new pair, with a
  30-minute replay grace if the new refresh token was lost `[O]`. Store the new refresh token atomically.
- Client credentials: `grant_type=client_credentials`, enabled per app, 30-day token, no refresh token, app actor, up to 1000 active
  tokens for identical scopes. **Requesting different scopes revokes existing app tokens.** For CI, mint at the start of each run `[O]`.

## Actor

`actor=user` is the default. `actor=app` makes the app the actor; legacy `actor=application` still works but is deprecated. `createAsUser`
and `displayIconUrl` render "User (via Application)" on `issueCreate` and `commentCreate`. `actor=app` can't request `admin` `[O]`.

## Where doc and changelog disagree

- PKCE: the doc says `plain` or `S256`; the 2026-10 changelog says the flow now requires S256. Use S256.
- Client credentials: the doc says tokens reach all public teams; the 2026-10 changelog says they no longer reach public teams outside the
  app user's selected teams. Trust the changelog, and test it.
