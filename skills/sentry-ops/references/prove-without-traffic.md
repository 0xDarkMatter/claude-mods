# Proving a setup without traffic to Sentry

Evidence labels are defined in `SKILL.md`.

The idea: a DSN is just an address. Point it at a listener you control, trigger real errors, and
read exactly what the SDK would have sent. No account, no quota, and no personal data leaves the
machine while you're still finding out whether it would.

## Contents

- What has been measured
- Steps
- What the sink records

## What has been measured

Against `@sentry/cloudflare` 11.10.0, `withSentry` on Node 22 with a stand-in handler [measured]:

| Case | Result |
|---|---|
| DSN `http://publickey@127.0.0.1:<port>/1` | Accepted, one POST per error, plain JSON envelope |
| Handler throws, no privacy options | Captured and rethrown. Client IP, custom header, body, query and console text all present |
| Handler throws, `dataCollection` strict + `maxBreadcrumbs: 0` | Fields gone. **Email in the error message still present** |
| Same + `beforeSend` | Clean: no planted value found |
| No DSN | No request |
| Handler **returns** a 500 | No request |

**Not measured:** the same run inside workerd, and the browser SDK against this listener. Run on
Node this proves the SDK's behaviour, not your Worker's. So do step 3 against your real build, and
treat anything that differs as a finding.

## Steps

### 1. Tests first

Run the scrub tests and watch them fail once: break the scrubber on purpose (comment out a
`delete`) and see the named test go red. A scrub test that can't fail proves nothing.

### 2. Plant canaries

Add a temporary route, or use an existing one that can fail, and send a request carrying unique
values in every channel:

| Channel | Example value |
|---|---|
| Error message | `new Error("boom for person@example.com")` |
| Query | `?email=person@example.com` |
| Cookie | `session=CANARY_COOKIE; theme=dark` |
| Header | `x-custom: CANARY_HEADER` |
| Client IP header | `cf-connecting-ip: 203.0.113.9` |
| Body | `{"message":"CANARY_BODY"}` |
| Log line | `console.log("CANARY_LOG")` |

Use documentation values only (`example.com`, `203.0.113.0/24`). Remove the route afterwards, or
guard it so it can't ship.

### 3. Real build, real runtime

Build the artifact that deploys and run that. A dev server often has a different entry point:
`@sentry/astro` doesn't wrap the Worker under `astro dev`, for one [code].

For a Worker, that generally means your production build plus `wrangler dev`, with the fake DSN in
`.dev.vars`:

```bash
python "<skill-dir>/scripts/envelope-sink.py" listen --out ./envelopes --count 1 --timeout 120
```

```dotenv
SENTRY_DSN=http://publickey@127.0.0.1:8191/1
```

Wait for the `listening` line before you trigger anything. An SDK that posts to an unbound port
loses the event quietly, which looks exactly like a pass [measured: one of our runs did this on
a loaded machine]. Check that the listener's "received" count matches what you sent.

The port range is the throwaway one, 8190 to 8199. The script binds to loopback only and exits by
itself on `--timeout`. Make sure it has gone before you finish.

[open] That workerd under `wrangler dev` reaches a plain-HTTP loopback address the way Node does. We
expect it to, but if nothing arrives, that's the first thing to rule out: try it with a route that
only calls `fetch` on the listener.

### 4. Read the bytes

```bash
python "<skill-dir>/scripts/envelope-sink.py" inspect ./envelopes \
  --forbid person@example.com --forbid person%40example.com \
  --forbid CANARY_COOKIE --forbid CANARY_HEADER --forbid CANARY_BODY --forbid CANARY_LOG \
  --forbid 203.0.113.9 --strict
```

Exit 10 means a finding. Include the URL-encoded form: the query canary appears percent-encoded in
`request.url` [measured]. `--strict` also fails on any personal-data field being present, such as
`request.headers` or `user`, even when no canary matched. Leave it out if your project chose to send
one of those.

The scan is byte matching on the decoded envelope. It won't see through a transform your code
applies, or through compressed Replay segments.

### 5. No DSN means nothing

```bash
python "<skill-dir>/scripts/envelope-sink.py" listen --out ./none --timeout 30 --expect-none
```

Run the same trigger with `SENTRY_DSN` unset. Exit 10 means something was sent. This also needs a
positive control, or a broken trigger passes it: step 3 used the same trigger and did send.

### 6. One live event, last

Only now point the real DSN at it and send one event with a unique message. Capture the event id,
either from `Sentry.captureException()`'s return value or a sink run just before it, and find that
id in Sentry. Then read the stored event, because server-side processing can add fields: anything
Sentry shows beyond your envelope came from its side, such as derived geo data. Delete the test
issue afterwards.

That one event is the only traffic. It proves the whole path: DSN correct, project correct,
network open, and quota not exhausted. Steps 1 to 5 can't.

A deploy is a separate step with its own owner. Proving stops before it.

## What the sink records

Envelope format: one JSON header line, then for each item a JSON header line and a payload. An item
header with `length` gives the payload's byte count, because payloads can be binary. Details:
develop.sentry.dev/sdk/data-model/envelopes/

The saved files contain whatever your app sent, so they may hold personal data if your scrubbing
failed. Keep them out of the repo, and delete them when you're done.
