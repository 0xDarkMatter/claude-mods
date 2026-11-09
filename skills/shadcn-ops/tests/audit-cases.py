#!/usr/bin/env python3
"""The shadcn-audit fixture matrix, run by tests/run.sh (one PASS|/FAIL| row per check on stdout).

FIXTURES: every file under tests/fixtures/ ends in `.fx`; materialise() strips the suffix
into a temp dir. Guard: never rename them to bare package.json / pnpm-lock.yaml /
components.json - Dependabot, Socket and npm would treat the fixture manifests as real, and
the repo's own audits would report the deliberately broken ones.

A case is tests/fixtures/cases/<name>/: its `.fx` files are laid over a base fixture
(`_base`, default clean-v4), the paths in `_delete` are removed, and shadcn-audit.py runs on
the folder named by `_dir` (default the root). `_expect` lists the EXACT set of finding ids
the audit must report (empty = a clean control that must exit 0), so a new false positive
fails as surely as a missed finding. `_tailwind` optionally pins meta.project.tailwind.
A fake secret is spelled FIXTURE-LITERAL-VALUE or FIXTURE-URL-SECRET: every case holding
one is checked in both output modes, and the value must never appear.

Usage:   audit-cases.py <skill-dir> <fixtures-dir> <tmp-dir>
Exit:    0 always when it ran (the rows carry the verdicts); 1 on a harness crash
"""
import json
import shutil
import subprocess
import sys
import traceback
from pathlib import Path

skill, fixtures, tmp = (Path(a) for a in sys.argv[1:4])
audit = skill / "scripts" / "shadcn-audit.py"
SECRETS = ("FIXTURE-LITERAL-VALUE", "FIXTURE-URL-SECRET")


def row(ok, msg):
    print(f"{'PASS' if ok else 'FAIL'}|{msg}")


def crash(kind, exc, tb):
    # The bash side counts rows; an uncaught exception must become a FAIL row, not silence.
    row(False, f"audit-cases harness crashed: {''.join(traceback.format_exception_only(kind, exc)).strip()}")
    sys.exit(1)


sys.excepthook = crash


def materialise(src: Path, dest: Path):
    for f in src.rglob("*.fx"):
        out = dest / f.relative_to(src).with_suffix("")
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(f, out)


def run(target: Path, *extra):
    return subprocess.run([sys.executable, str(audit), *extra, str(target)], capture_output=True, text=True)


cases = sorted(p for p in (fixtures / "cases").iterdir() if (p / "_expect").is_file())
row(len(cases) >= 25, f"{len(cases)} audit fixture case(s)")
covered = set()
for case in cases:
    meta = {n: (case / n).read_text().strip() for n in ("_base", "_dir", "_delete", "_tailwind") if (case / n).is_file()}
    dest = tmp / "cases" / case.name
    shutil.rmtree(dest, ignore_errors=True)
    materialise(fixtures / meta.get("_base", "clean-v4"), dest)
    materialise(case, dest)
    for d in meta.get("_delete", "").split():
        (dest / d).unlink()
    target = dest / meta.get("_dir", ".")
    want = sorted(set((case / "_expect").read_text().split()))
    proc = run(target, "--json")
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        row(False, f"{case.name}: --json output does not parse (exit {proc.returncode}): {proc.stderr.strip()[:200]}")
        continue
    got = sorted({f["id"] for f in data["data"]})
    covered.update(got)
    want_rc = 10 if want else 0
    row(got == want and proc.returncode == want_rc,
        f"{case.name}: ids {got or '[]'} exit {proc.returncode} (want {want or '[]'} exit {want_rc})")
    if meta.get("_tailwind"):
        t = data["meta"]["project"].get("tailwind")
        row(t == meta["_tailwind"], f"{case.name}: meta.project.tailwind {t!r} (want {meta['_tailwind']!r})")
    if any(s in f.read_text(errors="replace") for f in case.rglob("*.fx") for s in SECRETS):
        text = run(target)
        leaked = [s for s in SECRETS if s in proc.stdout + proc.stderr + text.stdout + text.stderr]
        row(not leaked, f"{case.name}: secret values never printed (text and --json, stdout and stderr)")

# Every check id the audit knows must be exercised by at least one case.
listed = subprocess.run([sys.executable, str(audit), "--checks"], capture_output=True, text=True)
ids = set(listed.stdout.split())
missing = sorted(i for i in ids if i not in covered)
row(not missing and len(ids) >= 15, f"every check id has a case that fires it ({len(ids)} ids; missing: {missing or 'none'})")
