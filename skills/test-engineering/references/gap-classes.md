# Gap classes (G1-G13)

Where realistic bugs went through green suites. Design mode walks this list to build the
failure list; audit mode uses it to aim mutants. Every class below produced surviving mutants
in real, well-maintained repos, which is the point: these are the failures nobody anticipates.

The strongest single signal from the evidence: **behaviour whose failure a site comment
warned about was protected 87% of the time; unflagged behaviour 66%.** Teams test what they
anticipated. The list exists to supply the anticipation.

Examples here are generic shapes. This skill ships publicly: never add an audited repo's code,
test names, paths or bug text, and never describe an open security survivor closely enough to
locate it. Audit findings stay in the private audit report.

| Id | Class | Ask | Typical survivor |
|---|---|---|---|
| G1 | Negative path of a guard | Does a test drive the forged, empty, expired, wrong-tenant or second-party input into **every** guard? | an authorisation check that is never shown refusing anything |
| G2 | Boundaries | Is the exact edge pinned: equal to the limit, page ceiling equal to the total, day 0, month 13, the bucket edge? | `>` vs `>=` on a spend limit or capacity check |
| G3 | Aggregation and ordering | Mixed statuses, ties, sort direction, totals across groups, empty groups? | a summary that drops one status from its total |
| G4 | Partial failure | When step 2 of 3 fails, is what already happened reported truthfully? | "0 written" reported after 1 of 3 writes succeeded |
| G5 | Identity and ambiguity | Two entities with the same name, first-match fallbacks, scan caps? | a lookup that silently picks the first of two matches |
| G6 | Error classification | Is each status mapped to the right retry, exit code and "may have happened" outcome? | an ambiguous 5xx on a POST treated as "did not happen" and retried |
| G7 | Units, time, rounding | Seconds vs ms, per-token vs per-million, half-cent, negative rounding, timezone, DST? | half-cent rounding direction; negative totals formatted as positive |
| G8 | Wiring | Is the value plumbed to where it is used: URL, sink, exit code, header? | a computed cost never reaching the record that bills it |
| G9 | Idempotency and replay | Are cache and idempotency keys complete, retries safe, claims not stolen? | a dedup window constant changed with no test noticing |
| G10 | Output-channel hygiene | Does anything write to a protocol stream (MCP stdout, JSON output)? | one stray log line corrupting a stdio protocol |
| G11 | Defaults and config parsing | Is the "off" spelling tested (`=false`, `=0`, empty, unset), not only "on"? | `FEATURE=false` treated as enabled because the string is truthy |
| G12 | Security edges | Exact match vs prefix/suffix, regex anchors, array audiences, redaction on **every** output path? | an allow-list matched by suffix, so `evil-example.com` passes as `example.com`; a path checked before it is URL-decoded; a secret redacted in logs but echoed in an error message |
| G13 | Injection boundaries (MCP and LLM shapes) | Does untrusted content (tool results, fetched pages, repo text) reach an instruction surface without being framed as data? Is there a drift gate on model-facing tool descriptions? | a tool result spliced into a prompt verbatim |

## Which classes are mandatory where

Risk zones in `.test-profile.yml` make classes mandatory for design mode (profile.md has the
full table): `money` -> G7, G3, G2; `pii` -> G12 redaction on every path, G10; `auth` -> G1
for every guard, G12; `irreversible` -> G9, G4, G6 and the confirmation gate's negative path;
`mission-critical` -> every class that applies, plus G11.

## Protection is not discovery

A gap class asks "would a test notice if this broke?" It cannot find logic that was never
written: a missing guard, an exclusion list that forgets a file. Those come from reading the
code against its threat model (security-ops), and the finding then comes back here as a
regression test that is seen failing against the vulnerable revision.
