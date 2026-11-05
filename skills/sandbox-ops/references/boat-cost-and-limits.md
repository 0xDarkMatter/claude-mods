# Cost, plans and start limits

Source tags as in SKILL.md. Published figures are [docs: pricing / limits], read
2026-10-27; `scripts/check-boat-facts.py --live` re-checks the ones the skill relies on.

## Rates

| Size | $/hour | Hours of `default` per hour |
|---|---|---|
| `small` | $0.018 | 0.5 |
| `default` | $0.036 | 1 |
| `large` | $0.072 | 2 |
| `xlarge` | $0.200 | 5.56 (needs the $100 plan or higher) |

- Billed per second, only while a box runs; a stopped box costs no machine time. Egress
  is not billed [docs].
- Cross-check per box: `boat usage <id> --json` gives `dollars`, `seconds` and
  `billingMultiplier`; usage was billed at $0.00001 per box-second (100,000 s per dollar,
  multiplier 1) on `default` [field], and matched rate x lifetime within 1% [bench].
- Seconds count from create to delete, including time a box waits for you to collect
  results: one batch billed about 80 s per box of waiting on a 30 s gate [field]. Delete
  as soon as results are home.

## Plans and limits

- The $20 plan includes 555 h of `default`, 100 boxes at once and 12 / 60 / 200 starts
  per minute / hour / day [docs]. Bigger plans: $100 (300 at once, 30 / 210 / 840),
  $500, $2000. Included time does not carry over.
- An organization multiplies every limit by its seats [docs]. One org account read
  24 / 120 / 400 starts and 200 at once in `boat limits` [field], which matches two
  seats of the $20 plan (inferred). Read your own: `boat --no-update limits --json`.
- Create, fork and resume each count as one start; start windows roll over the last 60 s,
  hour and 24 h [docs: limits]. A refused start does not count.
- Above a limit, starts are paid from the wallet ($0.03-$0.07 each) up to 3x the limit,
  only after a first payment and while the wallet has money [docs].
- The free trial: 2 boxes at once, 5 / 25 / 75 starts, 25 h in total, no `large` or
  `xlarge`, auto-stop at most 2 h [docs: limits].
- API keys live 90 days by default, 365 at most, or never [docs: limits]. Put the expiry
  in a calendar when a key goes into CI.

## Errors worth handling [docs: limits]

| Status / code | Meaning | Do |
|---|---|---|
| 429 `rate_limited` | too many starts in a window (the body names it) | wait for the window; a retry loop does not help for hour and day |
| 429 `limit_reached` | the at-once limit is full | delete or stop a box |
| 402 `billing_required` | included time used and the wallet empty | stop; ask the account owner |
| 503 `no_ready_machine` | `--fail-fast` found no machine | retry after `retryAfterSeconds` (5) |
| 503 `out_of_capacity` | boat is briefly out of machines | retry after `retryAfterSeconds` (120) |
| 409 `idempotency_in_progress` | an earlier create with the same `Idempotency-Key` is still running | retry the same request; the box id comes back once it is done [field] |

- Send an `Idempotency-Key` on API creates: a retry with the same key never makes a
  second box and does not spend a start [docs]. The CLI does not retry for you.
- Pace bulk starts: the benchmarks started boxes 5.2 s apart to stay under 12 a minute
  [field].

## Measured costs

| Job | Cost |
|---|---|
| A 23-minute bench on one `default` box | $0.0138 estimated, $0.01379 from `boat usage` [bench] |
| A Python/bash CI gate, about 5 min on `default` | $0.0033 median per run [field] |
| A TypeScript `pnpm check` gate, about 30 s | $0.0011 per run including about 80 s of waiting; about $0.0004 without [field] |
| A PHP site's Docker image build | $0.0003-$0.0006 per build [field] |
| 30 CI benchmark boxes in all | under $0.10 [field] |
| Three `large` boxes for a heavy compute job | $0.0053 [field] |
| 35 agent lanes sharing one `default` box | about $0.001 per lane-hour of box compute [driver] |

Against GitHub's hosted Linux runner at $0.006 a minute, rounded up to whole minutes per
job: the same gate took 15.1 min there (median) and cost about $0.096 [field]. Through a CI path that
needs two small GitHub jobs to start and delete the box (about 2 billed minutes), the
boat run comes to about $0.015 (inferred). At that scale the case for boat is speed, not
money.
