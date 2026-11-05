# Privacy baseline

Evidence labels are defined in `SKILL.md`. Measurements are SDK 11.10.0: `withSentry`
running on Node with a stand-in handler, not on workerd.

## Contents

- The two layers
- `dataCollection`, v11
- `beforeSend`
- Server-side settings
- Replay
- Before you call it done

## The two layers

| Layer | Stops | Misses |
|---|---|---|
| `dataCollection` | Whole categories at collection: cookies, headers, bodies, query, inferred IP | Anything your code wrote into an error message, `setUser()`, `setContext()` |
| `beforeSend` | Whatever is left on the event, including message text | Spans, logs, metrics, transactions, which have their own hooks [docs] |

Neither layer alone was enough [measured]. With `dataCollection` fully off, an email in
`new Error("boom for person@example.com")` still went out. With only `beforeSend`, a new
field the scrubber doesn't know about would go out. Keep both.

## `dataCollection`, v11

Defaults, from `resolveDataCollectionOptions.js` in `@sentry/core` 11.10.0 [code]:

| Key | Default | Strict value |
|---|---|---|
| `userInfo` | `true` (inferred IP and similar) | `false` |
| `cookies` | `true` | `false` |
| `httpHeaders` | request and response | `false` |
| `httpBodies` | all four types | `[]` |
| `urlQueryParams` | `true` | `false` |
| `graphQL` | document and variables | both `false` |
| `genAI` | inputs and outputs | both `false` |
| `mcp` | inputs and outputs (11.9.0+) | both `false` |
| `databaseQueryData` | `true` | `false` |
| `queues` | `true` | `false` |
| `stackFrameVariables` | `true` | `false` |
| `frameContextLines` | `5` | `0` |

`assets/scrub-event.mjs` exports this as `STRICT_DATA_COLLECTION`. Relax a key only when you
can name the bug you need it for. `frameContextLines: 0` loses inline source in stack frames
but keeps file and line.

On **v10** the same option exists from 10.57.0, and `sendDefaultPii` still controls collection
when `dataCollection` is unset [docs]. So a v10 project with no options is more private than a
v11 project with no options. **Upgrading from v10 to v11 widens collection without any code
change.** That belongs in the upgrade's review.

If you keep headers on, IP addresses can still arrive through `x-forwarded-for` and similar.
The docs suggest a deny list of `forwarded`, `-ip`, `remote-`, `via`, `-user` [docs].
`cf-connecting-ip` matches `-ip`, so that list should cover it, though we measured only the
strict setting.

## `beforeSend`

`assets/scrub-event.mjs` provides `makeBeforeSend({ isSensitivePath })`. It:

- Removes `user`, `breadcrumbs`, `extra`, and request `cookies`, `headers`, `data`,
  `query_string`, `env`.
- Cuts query string and fragment from `request.url`.
- Redacts email addresses and URL query strings in messages and exception values.
- Removes `frame.vars`.
- On a sensitive route (forms, admin), keeps only error type and path, and removes source
  lines too.
- **Drops the event if scrubbing throws.** Losing one report beats sending it unscrubbed.

It is pure, with no SDK import, so it can be tested without Sentry. Its tests are in
`tests/scrub-event.test.mjs` and were each seen failing against a broken copy. Copy them along
with the file, and add your own routes and any identifiers your app uses. An email regex won't
find a customer number.

### What stays

After both layers, a real event carried [measured]: `event_id`, `timestamp`, `level`,
`platform`, `environment`, `sdk`, `request.method`, `request.url` (origin and path, no query),
`exception` (type, stack frames), `contexts` (trace ids, `runtime`, `cloud_resource`). Add a
path rule if your paths hold identifiers, because Sentry always sends the path [docs].

## Server-side settings

These are in Sentry, not your code, and take effect on new events without a deploy [docs]:

- **Project Settings > Security & Privacy**: "Prevent Storing of IP Addresses", plus additional
  sensitive fields. Check the exact label in the UI, since it isn't pinned here.
- **Data scrubbing is on by default.** Keep it on [docs]. It works on keys and some value
  patterns, and only on certain fields, so it is a backstop.
- An organization-level setting overrides the project's [docs].

## Replay

Replay masks all text and blocks media by default [docs]. Those defaults are good, and each
`unmask` or `unblock` you add is a privacy decision. It is still the largest byte cost, and it
records user behaviour, which a privacy page should mention. Sample rates are a cost choice.
If error reports alone answer your questions, leave it out.

Not measured here: what a real recording contains on your pages. If you adopt it, record a
session against the sink and inspect it. Recording payloads are binary, so `inspect --forbid`
may miss text in compressed segments [inferred].

## Before you call it done

- [ ] `grep -r sendDefaultPii` finds nothing in the app.
- [ ] `dataCollection` is set on **every** SDK init: server, client and any Durable Object or
      other wrapper. Each one has its own options.
- [ ] A canary run through `envelope-sink.py inspect --strict` is clean.
- [ ] The privacy page names Sentry, and the data processing agreement is handled.
- [ ] Nothing calls `setUser()` with more than you intend.
