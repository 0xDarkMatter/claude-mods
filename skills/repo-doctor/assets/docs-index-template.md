# Docs Index

<!-- Template: assets/docs-index-template.md (repo-doctor skill). Save as
     docs/00_INDEX.md. The two anti-rot rules are baked in below: (1) this file
     carries its own maintenance instruction; (2) volatile lists are DELEGATED to
     the filesystem, never hand-copied. One line per doc: what it is, why you'd
     read it. -->

> **Maintenance:** adding/removing a doc in `docs/` updates this index in the same
> commit. Keep entries to one line. Never add per-item lists that the filesystem
> already answers — delegate them (see Decisions below).

## Canonical

| Doc | What it is — why you'd read it |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | <system map — read before structural changes> |
| [<doc>.md](<doc>.md) | <one line> |

## Decisions

Architecture Decision Records live in [adr/](adr/) — **the directory is the index**:
`ls docs/adr/ADR-*.md`. Newest ADR = highest number. (Managed by the `adr-ops` skill.)

## Plans & status

| Doc | Liveness |
|---|---|
| [PLAN.md](PLAN.md) | <what's NEXT — shipped phases marked done; history lives in CHANGELOG/git> |

## Archive

Superseded docs move to [archive/](archive/) with a one-line tombstone here only if
they're still cited elsewhere; otherwise the move IS the record.
