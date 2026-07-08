---
name: okf-ops
description: "Assess, validate, and adopt the Open Knowledge Format (OKF) across markdown+frontmatter knowledge bases. Triggers on: OKF, open knowledge format, knowledge bundle, frontmatter conformance, validate frontmatter, markdown knowledge base, adopt OKF, is this repo OKF-ready, index.md log.md."
license: MIT
compatibility: "Python 3.8+. PyYAML used if present; falls back to a built-in parser otherwise."
allowed-tools: "Read Bash Glob Grep"
metadata:
  author: claude-mods
  related-skills: "adr-ops, doc-scanner"
---

# OKF Ops

The **Open Knowledge Format (OKF)** is a minimal, open convention for representing
*knowledge* as a directory tree of markdown files with YAML frontmatter — the metadata
and curated context that surrounds data and systems. This skill helps you **assess**
whether a repo is a good fit, **validate** a bundle for conformance, and **adopt** OKF
where it earns its keep.

Full format rules: [references/okf-spec.md](references/okf-spec.md). Copy-ready concept
doc: [assets/concept-template.md](assets/concept-template.md).

## Honest scope (read this before adopting)

OKF is a **v0.1 draft** (Google-published, platform-agnostic). It's deliberately
minimal: one required frontmatter field (`type`), reserved `index.md`/`log.md`, and a
*permissive-consumption* contract. Two consequences worth knowing up front:

- **Adoption cost is shaped by the repo, not the size.** A repo that already uses
  frontmatter consistently is often one mechanical `type`-derivation pass from
  conformant. A repo of bare prose markdown needs frontmatter authored on every file —
  often not worth it, and arguably the wrong files to make "concepts."
- **Conformance is a weak guarantee.** "OKF-conformant" means the structural floor is
  met, not that the content is good. Use the assessment to decide adoption per-repo;
  don't make it a blanket mandate.

The tools here are useful **regardless of OKF's trajectory** — `assess-okf.py` is a
general "how frontmatter-consistent is this doc tree?" scanner.

## Workflow: assess → decide → validate

### 1. Assess (read-only) — is this repo a good candidate?

```bash
python scripts/assess-okf.py docs/                    # human summary
python scripts/assess-okf.py --json docs/ | jq '.data.readiness_pct'
```

Reports total `.md`, how many already carry frontmatter, how many have a non-empty
`type`, a histogram of existing frontmatter **keys** (shows what vocabulary you already
have to derive `type` from), `type`-value distribution, reserved files present, files
that would need a `type`, and an overall **readiness %**. Never writes.

**Read the histogram, not just the %.** A repo at "0% readiness" with rich consistent
keys (e.g. every file has `title`/`level`/`tags`) is a *cheap* migration — you derive
`type` from an existing key. A repo at "0%" with mostly empty frontmatter is *expensive*.
To find candidates across many repos, run assess on each and compare.

### 2. Decide — adopt only where the squeeze is worth the juice

- **Frontmatter-consistent repo** → adopt: derive `type`, fix any malformed files, done.
- **Mixed prose + frontmatter repo** → usually skip, or adopt a subset (designate only
  the real concept docs; OKF has no built-in prose exemption — that's a known rigidity).

### 3. Validate — does a bundle conform?

```bash
python scripts/check-okf.py ./bundle                  # exit 0 conformant, 10 if not
python scripts/check-okf.py --json ./bundle | jq '.data[] | select(.severity=="error")'
python scripts/check-okf.py --strict ./bundle         # soft warnings also fail
```

Enforces only the hard rules (every non-reserved `.md` has parseable frontmatter with a
non-empty `type`; reserved files get light sanity). Per OKF's permissive-consumption
rule, broken links and missing optional fields are INFO, never failures (unless
`--strict`). Wire `check-okf.py --strict` as a CI gate (exit 10 fails the build) once a
repo has adopted OKF.

## Tools

Both scripts follow the Skill Resource Protocol: stdout is data-only (`--json` emits a
`{"data":…,"meta":{"schema":…}}` envelope), framing/progress to stderr, `--help` with
examples, semantic exit codes. Stdlib-only; PyYAML used if present, else a built-in
frontmatter parser (announced on stderr).

| Script | Role | Exit codes |
|--------|------|-----------|
| `scripts/assess-okf.py` | Read-only readiness scan of a doc tree | `0` scanned, `2` usage, `3` not-found |
| `scripts/check-okf.py` | Conformance validator for a bundle | `0` conformant, `10` non-conformant, `4` unparseable frontmatter, `3` not-found, `2` usage |

## See also

- [references/okf-spec.md](references/okf-spec.md) — the format: frontmatter fields,
  reserved files, conformance rules, permissive-consumption, versioning.
- [assets/concept-template.md](assets/concept-template.md) — copy-ready OKF concept doc.
