# boat snapshots: the golden-image exception

The default stands: every box that runs private or client code is created with
`--no-snapshots`, so nothing of it outlives the box. The one exception is a **golden
snapshot**: a plain base image (a runtime and its tools, nothing else) that new boxes
start from with `boat new --from <name|share code>` [cli]. It saves the minutes a setup
script spends installing the same toolchain on every box.

Source tags as in SKILL.md: [docs] boat docs 2026-10-27, [cli] `boat help`, [field]
field reports. Adapted from a team's working policy, with its account details removed.

## When a golden snapshot is allowed

Only while all of these hold:

- **Built only from the setup script, never hand-patched.** A builder box runs the script
  (`--setup-file`), is saved with `boat snapshot <id> <name>` [cli], then is deleted and
  confirmed gone like any other box. The builder alone omits `--no-snapshots`, because a
  box created with it cannot be saved [cli]. A fix goes into the script, and the image is
  rebuilt.
- **No client code, data, secrets or `.env`.** Create the builder with `--no-env` and copy
  nothing from a client repo onto it. Snapshot copies can be stored outside the EU [docs:
  security], so the image may hold only what could be public.
- **Share codes live in the team's secret store**, never in a repo, a box or a log. A
  share code (`bsh_...`) creates a box from the image [cli]: treat it like a key. On the
  account that saved the image, start boxes by its name, which is not secret. `--from`
  takes a share code in argv, so use one only on a machine no one else shares, and never
  in CI.
- **Rebuilt weekly and on any version-pin bump**, under the 7-day dependency cooldown:
  the script installs only versions published at least 7 days ago (the
  `supply-chain-defense` skill).
- **Only on an account without zero data retention.** With zero data retention on, the
  account cannot save snapshots [field].

## Using the image

A box started from the image to run client code still takes `--no-snapshots --no-env
--no-monitoring`; if boat refuses that with `--from`, use the setup script instead, never
drop `--no-snapshots`. Name it like any other box (`<who>-<what>-<MMDD-HHMM>`), because a
box started with `--from` takes the snapshot's name unless you pass `--name` [docs:
cli-reference].

A first run may always skip the image: create a plain `--no-snapshots` box with the same
`--setup-file`. That needs no saved snapshot, so it works with zero data retention on.

## Cleaning up

A saved snapshot keeps its data after every box made from it is deleted; `boat snapshot
rm <name>` removes it [docs: cli-reference]. List and prune old images when you rebuild,
so the account holds one current golden image per runtime, not a trail of them.
