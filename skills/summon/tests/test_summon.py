#!/usr/bin/env python3
"""Regression tests for summon.py — selection/confirmation flow + encoding safety.

Hermetic: builds a throwaway Claude Desktop directory tree in a temp sandbox
and points the script at it via HOME/USERPROFILE/APPDATA. No network, no real
account data touched.

Covers:
  1. --yes does NOT bypass the selection picker (piped picks are honoured)
  2. --select answers the picker non-interactively
  3. --select all selects everything
  4. Without --yes, declining the confirmation cancels (nothing copied)
  5. Without --yes, confirming 'y' proceeds
  6. --yes with empty stdin cancels instead of auto-selecting all
  7. Non-cp1252 chars in session titles don't crash on cp1252 stdout

Toolbox modes (rebind / recover / pick / doctor):
  8.  rebind rewrites cwd + rebases originCwd/worktreePath, backs up outside
      the store, bridges the transcript into the new munged dir, exits 0
  9.  rebind --dry-run touches nothing
  10. rebind with unknown id exits 3; ambiguous prefix exits 2
  11. rebind to a nonexistent path exits 3 without --force, 0 with it
  12. doctor flags the broken-cwd session (exit 10, --json envelope), and
      goes healthy (exit 0) after the rebind
  13. recover --no-distill emits the plain pointer prompt on stdout; transcript
      found via the scan fallback when the munged dir doesn't derive from the
      recorded cwd; no handover cache is written
  14. recover with unknown id exits 3
  15. pick --select N emits the recovery prompt for the Nth candidate
  16. rebind into a .claude/worktrees/ path prints the `git worktree repair` hint

Distilled handover (recover -> extract -> distill -> cache -> emit):
  17. extract_conversation keeps user/assistant text, skips tool_use inputs and
      tool_result blobs (fixture JSONL); respects the char budget with the
      verbatim tail winning
  18. recover distills via a PATH-shimmed fake `claude`, emits brief + pointer
      clause, caches at <transcript>.handover.md
  19. cache hit: unchanged transcript reuses the cached brief (no re-distill);
      --refresh forces re-distillation; a newer transcript mtime busts the cache
  20. degrade: `claude` absent from PATH -> plain pointer prompt, exit 0,
      stderr warning; failing `claude` (exit 1) -> same advisory fallback

Pick --json (the in-chat visual picker's data feed):
  21. pick --json emits a parseable claude-mods.summon.pick/v1 envelope on a
      stdout free of panel glyphs (pure-ASCII JSON, nothing before/after it)
  22. worktree cwds are split into projectRoot + worktree; non-worktree cwds
      get worktree ""; brokenCwd flags the session whose recorded cwd is gone;
      transcriptPath is resolved (scan fallback included) and ISO timestamps
      parse
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "summon.py"

SRC_UUID = "aaaaaaaa-1111-4111-8111-111111111111"
DEST_UUID = "bbbbbbbb-2222-4222-8222-222222222222"

PASS = 0
FAIL = 0


def ok(name: str) -> None:
    global PASS
    PASS += 1
    print(f"  PASS  {name}")


def no(name: str, detail: str = "") -> None:
    global FAIL
    FAIL += 1
    print(f"  FAIL  {name}" + (f" — {detail}" if detail else ""))


def claude_dir(env: dict) -> Path:
    if sys.platform == "win32":
        return Path(env["APPDATA"]) / "Claude"
    if sys.platform == "darwin":
        return Path(env["HOME"]) / "Library/Application Support/Claude"
    return Path(env["HOME"]) / ".config/Claude"


def build_sandbox(tmp: Path, titles: list[str]) -> tuple[dict, Path, Path]:
    """Create src account (len(titles) sessions, newest first = #1) + dest account."""
    home = tmp / "home"
    appdata = home / "AppData" / "Roaming"
    env = os.environ.copy()
    env["HOME"] = str(home)
    env["USERPROFILE"] = str(home)
    env["APPDATA"] = str(appdata)
    env.pop("PYTHONIOENCODING", None)
    env.pop("TERM_ASCII", None)

    cdir = claude_dir(env)
    now_ms = int(time.time() * 1000)

    src_ws = cdir / "claude-code-sessions" / SRC_UUID / "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    src_ws.mkdir(parents=True)
    for i, title in enumerate(titles):
        sid = f"src-sess-{i}"
        (src_ws / f"local_{sid}.json").write_text(json.dumps({
            "sessionId": f"local_{sid}",
            "cliSessionId": f"cli-{sid}",
            "title": title,
            "cwd": "",  # no cwd -> no transcript lookup -> copy proceeds
            "lastActivityAt": now_ms - (i + 1) * 60_000,  # newest first
            "completedTurns": 5 + i,
        }), encoding="utf-8")

    dest_ws = cdir / "claude-code-sessions" / DEST_UUID / "22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    dest_ws.mkdir(parents=True)
    (dest_ws / "local_dest-own.json").write_text(json.dumps({
        "sessionId": "local_dest-own",
        "cliSessionId": "cli-dest-own",
        "title": "dest resident",
        "cwd": "",
        "lastActivityAt": now_ms,
        "completedTurns": 1,
    }), encoding="utf-8")

    return env, src_ws, dest_ws


def run_summon(env: dict, extra_args: list[str], stdin_text: str = "") -> tuple[int, str]:
    cmd = [sys.executable, str(SCRIPT),
           "--to", DEST_UUID[:8], "--from", SRC_UUID[:8], "--days", "3"] + extra_args
    r = subprocess.run(cmd, input=stdin_text.encode("utf-8"),
                       env=env, capture_output=True, timeout=60)
    out = (r.stdout.decode("utf-8", "replace")
           + r.stderr.decode("utf-8", "replace"))
    return r.returncode, out


def copied_titles(dest_ws: Path) -> set[str]:
    titles = set()
    for f in dest_ws.glob("local_src-sess-*.json"):
        titles.add(json.loads(f.read_text(encoding="utf-8"))["title"])
    return titles


def with_sandbox(titles=("alpha", "beta", "gamma")):
    tmp = Path(tempfile.mkdtemp(prefix="summon-test-"))
    env, src_ws, dest_ws = build_sandbox(tmp, list(titles))
    return tmp, env, src_ws, dest_ws


def encode_cwd(cwd: str) -> str:
    """Mirror of summon.py's munging: cwd -> ~/.claude/projects/ subdir name."""
    return (cwd.replace(":", "-").replace("\\", "-")
               .replace("/", "-").replace(".", "-"))


def build_toolbox_sandbox(tmp: Path) -> dict:
    """One account, three sessions exercising the toolbox modes.

    sess-a  'moved'   worktree session; recorded cwd no longer exists (project
                      moved old-root -> new-root); transcript under enc(old cwd)
    sess-b  'healthy' cwd exists, transcript at the expected munged path
    sess-c  'mismatch' cwd exists, but the transcript lives under a munged dir
                      that does NOT derive from the recorded cwd (scan-fallback)
    """
    home = tmp / "home"
    appdata = home / "AppData" / "Roaming"
    env = os.environ.copy()
    env["HOME"] = str(home)
    env["USERPROFILE"] = str(home)
    env["APPDATA"] = str(appdata)
    env.pop("PYTHONIOENCODING", None)
    env.pop("TERM_ASCII", None)

    cdir = claude_dir(env)
    projects = home / ".claude" / "projects"
    now_ms = int(time.time() * 1000)

    old_root = tmp / "proj-old"                    # moved away -> missing
    new_root = tmp / "proj-new"
    old_wt = old_root / ".claude" / "worktrees" / "wt1"
    new_wt = new_root / ".claude" / "worktrees" / "wt1"
    new_wt.mkdir(parents=True)
    good = tmp / "proj-good"
    good.mkdir()

    ws = cdir / "claude-code-sessions" / SRC_UUID / "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    ws.mkdir(parents=True)

    def wrapper(sid, cli, title, cwd, age_min, **extra):
        d = {"sessionId": f"local_{sid}", "cliSessionId": cli, "title": title,
             "cwd": cwd, "lastActivityAt": now_ms - age_min * 60_000,
             "completedTurns": 7}
        d.update(extra)
        (ws / f"local_{sid}.json").write_text(json.dumps(d), encoding="utf-8")

    wrapper("aaaa-moved", "cli-moved", "moved session", str(old_wt), 30,
            originCwd=str(old_root), worktreePath=str(old_wt),
            branch="claude/wt1")
    wrapper("bbbb-healthy", "cli-healthy", "healthy session", str(good), 60)
    wrapper("cccc-mismatch", "cli-mismatch", "mismatch session", str(good), 90)

    for enc_dir, cli in ((encode_cwd(str(old_wt)), "cli-moved"),
                         (encode_cwd(str(good)), "cli-healthy"),
                         ("X--some-unrelated-munged-dir", "cli-mismatch")):
        d = projects / enc_dir
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{cli}.jsonl").write_text(
            '{"type":"user","message":{"content":"hello"}}\n', encoding="utf-8")

    return {"env": env, "ws": ws, "projects": projects,
            "old_wt": old_wt, "new_wt": new_wt, "new_root": new_root,
            "old_root": old_root, "home": home}


def run_mode(env: dict, argv: list[str], stdin_text: str = "") -> tuple[int, str, str]:
    r = subprocess.run([sys.executable, str(SCRIPT)] + argv,
                       input=stdin_text.encode("utf-8"),
                       env=env, capture_output=True, timeout=60)
    return (r.returncode,
            r.stdout.decode("utf-8", "replace"),
            r.stderr.decode("utf-8", "replace"))


def toolbox_tests() -> None:
    tmp = Path(tempfile.mkdtemp(prefix="summon-toolbox-"))
    try:
        sb = build_toolbox_sandbox(tmp)
        env, ws = sb["env"], sb["ws"]
        new_wt, new_root = sb["new_wt"], sb["new_root"]
        wrapper_a = ws / "local_aaaa-moved.json"

        # 9. dry-run first (order matters: before the real rebind)
        rc, out, err = run_mode(env, ["rebind", "aaaa-moved", "--cwd", str(new_wt),
                                      "--dry-run"])
        data = json.loads(wrapper_a.read_text(encoding="utf-8"))
        backups = sb["home"] / ".claude" / "summon-backups"
        if rc == 0 and data["cwd"] == str(sb["old_wt"]) and not backups.exists():
            ok("rebind --dry-run touches nothing")
        else:
            no("rebind --dry-run touches nothing",
               f"rc={rc} cwd={data['cwd']!r} backups={backups.exists()}")

        # 10a. unknown id
        rc, _, _ = run_mode(env, ["rebind", "zzzz-nope", "--cwd", str(new_wt)])
        if rc == 3:
            ok("rebind unknown id exits 3")
        else:
            no("rebind unknown id exits 3", f"rc={rc}")

        # 10b. ambiguous prefix: 'cli-' hits several cliSessionIds... use
        # wrapper-id ambiguity instead — 'aaaa' vs 'aaaa-moved' is unique, so
        # craft the collision on the shared '' prefix? No: use 'cli-m' which
        # prefixes cli-moved and cli-mismatch — two distinct sessions.
        rc, _, err = run_mode(env, ["rebind", "cli-m", "--cwd", str(new_wt)])
        if rc == 2 and "different sessions" in err:
            ok("rebind ambiguous prefix exits 2")
        else:
            no("rebind ambiguous prefix exits 2", f"rc={rc} err-tail={err[-200:]!r}")

        # 11. nonexistent target path
        ghost = tmp / "not-there-yet"
        rc, _, _ = run_mode(env, ["rebind", "aaaa-moved", "--cwd", str(ghost)])
        if rc == 3:
            ok("rebind to nonexistent path exits 3 without --force")
        else:
            no("rebind to nonexistent path exits 3 without --force", f"rc={rc}")

        # 12a. doctor pre-rebind: flags exactly the moved session, exit 10
        rc, out, _ = run_mode(env, ["doctor", "--json"])
        try:
            env_doc = json.loads(out)
        except json.JSONDecodeError:
            env_doc = {"data": [], "meta": {}}
        ids = [f["sessionId"] for f in env_doc.get("data", [])]
        if (rc == 10 and ids == ["local_aaaa-moved"]
                and env_doc["meta"].get("checked") == 3
                and env_doc["meta"].get("schema") == "claude-mods.summon.doctor/v1"):
            ok("doctor flags the broken cwd (exit 10, --json envelope)")
        else:
            no("doctor flags the broken cwd (exit 10, --json envelope)",
               f"rc={rc} ids={ids} meta={env_doc.get('meta')}")

        # 8. real rebind: wrapper rewritten, siblings rebased, backup taken,
        #    transcript bridged into enc(new cwd)
        rc, out, err = run_mode(env, ["rebind", "aaaa-moved", "--cwd", str(new_wt)])
        data = json.loads(wrapper_a.read_text(encoding="utf-8"))
        resolved_new_wt = str(new_wt.resolve())
        resolved_new_root = str(new_root.resolve())
        bridged = (sb["projects"] / encode_cwd(resolved_new_wt) / "cli-moved.jsonl")
        original = (sb["projects"] / encode_cwd(str(sb["old_wt"])) / "cli-moved.jsonl")
        backup_files = list(backups.rglob("*.json")) if backups.exists() else []
        checks = {
            "rc": rc == 0,
            "cwd": data["cwd"] == resolved_new_wt,
            "originCwd": data["originCwd"] == resolved_new_root,
            "worktreePath": data["worktreePath"] == resolved_new_wt,
            "backup": len(backup_files) == 1,
            "bridged": bridged.exists(),
            "copy-not-move": original.exists(),
        }
        if all(checks.values()):
            ok("rebind rewrites wrapper + backup + transcript bridge")
        else:
            no("rebind rewrites wrapper + backup + transcript bridge",
               f"failed={[k for k, v in checks.items() if not v]} rc={rc}")

        # 16. rebind into a worktree path prints the `git worktree repair` hint
        if "git worktree repair" in out and str(new_wt.resolve()) in out:
            ok("rebind worktree hint present (git worktree repair)")
        else:
            no("rebind worktree hint present (git worktree repair)",
               f"out-tail={out[-300:]!r}")

        # 12b. doctor post-rebind: healthy, exit 0
        rc, out, _ = run_mode(env, ["doctor", "--json"])
        try:
            env_doc = json.loads(out)
        except json.JSONDecodeError:
            env_doc = {"data": ["unparsed"]}
        if rc == 0 and env_doc.get("data") == []:
            ok("doctor healthy after rebind (exit 0)")
        else:
            no("doctor healthy after rebind (exit 0)",
               f"rc={rc} data={env_doc.get('data')}")

        # 11b. --force allows a not-yet-existing path (rebind back and forth)
        rc, _, _ = run_mode(env, ["rebind", "aaaa-moved", "--cwd", str(ghost), "--force"])
        data = json.loads(wrapper_a.read_text(encoding="utf-8"))
        if rc == 0 and data["cwd"] == str(ghost):
            ok("rebind --force accepts a nonexistent path")
        else:
            no("rebind --force accepts a nonexistent path", f"rc={rc} cwd={data['cwd']!r}")

        # 13. recover --no-distill: plain pointer prompt on stdout, scan
        #     fallback for the mismatched dir, no handover cache written
        rc, out, err = run_mode(env, ["recover", "cccc-mismatch", "--no-distill"])
        scan_path = sb["projects"] / "X--some-unrelated-munged-dir" / "cli-mismatch.jsonl"
        cache = scan_path.with_name(scan_path.name + ".handover.md")
        if (rc == 0 and str(scan_path) in out
                and "Continue a previous Claude session" in out
                and "TAIL of the transcript" in out
                and "Continue a previous" not in err
                and not cache.exists()):
            ok("recover --no-distill emits pointer prompt; scan fallback; no cache")
        else:
            no("recover --no-distill emits pointer prompt; scan fallback; no cache",
               f"rc={rc} cache={cache.exists()} out-head={out[:200]!r}")

        # 14. recover unknown id
        rc, _, _ = run_mode(env, ["recover", "zzzz-nope"])
        if rc == 3:
            ok("recover unknown id exits 3")
        else:
            no("recover unknown id exits 3", f"rc={rc}")

        # 15. pick --select 2 -> second-newest candidate (healthy session)
        rc, out, _ = run_mode(env, ["pick", "--select", "2", "--no-distill"])
        if rc == 0 and "healthy session" in out and "cli-healthy.jsonl" in out:
            ok("pick --select 2 recovers the 2nd candidate")
        else:
            no("pick --select 2 recovers the 2nd candidate",
               f"rc={rc} out-head={out[:200]!r}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _load_summon_module():
    """Import summon.py as a module for unit-testing extraction (no side effects
    at import time beyond terminal-capability sniffing)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("summon_under_test", SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod  # dataclass needs the module registered
    spec.loader.exec_module(mod)
    return mod


def extraction_tests() -> None:
    """17. extract_conversation: tool blobs skipped, budget respected."""
    mod = _load_summon_module()
    tmp = Path(tempfile.mkdtemp(prefix="summon-extract-"))
    try:
        tr = tmp / "fixture.jsonl"
        recs = [
            {"type": "user", "message": {"content": "Build the frobnicator widget"}},
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Plan: refactor the gadget first"},
                {"type": "tool_use", "name": "Bash",
                 "input": {"command": "echo TOOL-INPUT-NOISE && make all"}},
            ]}},
            {"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "t1",
                 "content": "TOOL-RESULT-BLOB " * 200},
            ]}},
            {"type": "summary", "summary": "not a conversation turn"},
            {"type": "assistant", "message": {"content": [
                {"type": "text", "text": "Done; committed abc1234 on lane/foo"},
            ]}},
        ]
        tr.write_text("\n".join(json.dumps(r) for r in recs) + "\n", encoding="utf-8")
        out = mod.extract_conversation(tr, 120_000)
        checks = {
            "user-text": "frobnicator" in out,
            "assistant-text": "abc1234" in out,
            "roles": "USER:" in out and "ASSISTANT:" in out,
            "no-tool-input": "TOOL-INPUT-NOISE" not in out,
            "no-tool-result": "TOOL-RESULT-BLOB" not in out,
        }
        if all(checks.values()):
            ok("extraction keeps text turns, skips tool_use/tool_result blobs")
        else:
            no("extraction keeps text turns, skips tool_use/tool_result blobs",
               f"failed={[k for k, v in checks.items() if not v]}")

        # Budget: 40 turns x ~1KB, budget 5000 -> verbatim tail wins, earliest
        # turns dropped, output within budget.
        tr2 = tmp / "long.jsonl"
        recs2 = [{"type": "user" if i % 2 == 0 else "assistant",
                  "message": {"content": f"turn-{i} " + "x" * 1000}}
                 for i in range(40)]
        tr2.write_text("\n".join(json.dumps(r) for r in recs2) + "\n", encoding="utf-8")
        out2 = mod.extract_conversation(tr2, 5_000)
        if len(out2) <= 5_000 and "turn-39" in out2 and "turn-0 " not in out2:
            ok("extraction respects char budget; verbatim tail wins")
        else:
            no("extraction respects char budget; verbatim tail wins",
               f"len={len(out2)} tail-present={'turn-39' in out2}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def make_claude_shim(shim_dir: Path, brief_file: Path | None, fail: bool = False) -> None:
    """Drop a fake `claude` onto PATH: prints brief_file's content, or exits 1."""
    if sys.platform == "win32":
        bat = shim_dir / "claude.bat"
        if fail:
            bat.write_text("@echo off\r\nexit /b 1\r\n", encoding="ascii")
        else:
            bat.write_text(f'@echo off\r\ntype "{brief_file}"\r\n', encoding="ascii")
    else:
        sh = shim_dir / "claude"
        if fail:
            sh.write_text("#!/bin/sh\ncat >/dev/null\nexit 1\n", encoding="ascii")
        else:
            sh.write_text(f'#!/bin/sh\ncat >/dev/null\ncat "{brief_file}"\n',
                          encoding="ascii")
        sh.chmod(0o755)


def distill_tests() -> None:
    """18-20. recover distillation: shim claude, cache lifecycle, degrade paths."""
    tmp = Path(tempfile.mkdtemp(prefix="summon-distill-"))
    try:
        sb = build_toolbox_sandbox(tmp)
        env = sb["env"]
        good = tmp / "proj-good"
        transcript = sb["projects"] / encode_cwd(str(good)) / "cli-healthy.jsonl"
        cache = transcript.with_name(transcript.name + ".handover.md")

        shim = tmp / "shim"
        shim.mkdir()
        brief_file = tmp / "brief.txt"
        brief_file.write_text("## Goal\nBRIEF-ONE\n", encoding="utf-8")
        make_claude_shim(shim, brief_file)
        env_shim = dict(env)
        env_shim["PATH"] = str(shim) + os.pathsep + env.get("PATH", "")

        # 18. distill + cache write + brief-and-pointer emission
        rc, out, err = run_mode(env_shim, ["recover", "bbbb-healthy"])
        if (rc == 0 and "BRIEF-ONE" in out
                and "consult it only if something specific is missing" in out
                and str(transcript) in out
                and cache.exists() and "BRIEF-ONE" in cache.read_text(encoding="utf-8")
                and "BRIEF-ONE" not in err):
            ok("recover distills via shim claude; brief + pointer; cache written")
        else:
            no("recover distills via shim claude; brief + pointer; cache written",
               f"rc={rc} cache={cache.exists()} out-head={out[:200]!r} err-tail={err[-200:]!r}")

        # 19a. cache hit: shim now yields BRIEF-TWO but the cache must win
        brief_file.write_text("## Goal\nBRIEF-TWO\n", encoding="utf-8")
        rc, out, err = run_mode(env_shim, ["recover", "bbbb-healthy"])
        if rc == 0 and "BRIEF-ONE" in out and "BRIEF-TWO" not in out and "cached" in err:
            ok("cache hit: unchanged transcript reuses cached brief")
        else:
            no("cache hit: unchanged transcript reuses cached brief",
               f"rc={rc} out-head={out[:200]!r}")

        # 19b. --refresh forces re-distillation
        rc, out, _ = run_mode(env_shim, ["recover", "bbbb-healthy", "--refresh"])
        if rc == 0 and "BRIEF-TWO" in out:
            ok("--refresh forces re-distillation")
        else:
            no("--refresh forces re-distillation", f"rc={rc} out-head={out[:200]!r}")

        # 19c. newer transcript mtime busts the cache
        brief_file.write_text("## Goal\nBRIEF-THREE\n", encoding="utf-8")
        newer = cache.stat().st_mtime + 10
        os.utime(transcript, (newer, newer))
        rc, out, _ = run_mode(env_shim, ["recover", "bbbb-healthy"])
        if rc == 0 and "BRIEF-THREE" in out:
            ok("newer transcript mtime busts the cache")
        else:
            no("newer transcript mtime busts the cache", f"rc={rc} out-head={out[:200]!r}")

        # 20a. degrade: claude absent from PATH -> pointer prompt, exit 0, warning
        emptybin = tmp / "emptybin"
        emptybin.mkdir()
        env_absent = dict(env)
        env_absent["PATH"] = str(emptybin)
        rc, out, err = run_mode(env_absent, ["recover", "cccc-mismatch"])
        if (rc == 0 and "TAIL of the transcript" in out
                and "not on PATH" in err):
            ok("degrade: absent claude falls back to pointer prompt (exit 0)")
        else:
            no("degrade: absent claude falls back to pointer prompt (exit 0)",
               f"rc={rc} err-tail={err[-300:]!r}")

        # 20b. degrade: failing claude (exit 1) -> same advisory fallback
        shim_fail = tmp / "shim-fail"
        shim_fail.mkdir()
        make_claude_shim(shim_fail, None, fail=True)
        env_fail = dict(env)
        env_fail["PATH"] = str(shim_fail)
        rc, out, err = run_mode(env_fail, ["recover", "cccc-mismatch"])
        if (rc == 0 and "TAIL of the transcript" in out
                and "exited 1" in err):
            ok("degrade: failing claude falls back to pointer prompt (exit 0)")
        else:
            no("degrade: failing claude falls back to pointer prompt (exit 0)",
               f"rc={rc} err-tail={err[-300:]!r}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def pick_json_tests() -> None:
    """21-22. pick --json: envelope shape, clean stdout, worktree split, brokenCwd."""
    import re
    tmp = Path(tempfile.mkdtemp(prefix="summon-pickjson-"))
    try:
        sb = build_toolbox_sandbox(tmp)
        env = sb["env"]

        # _is_live also checks wrapper mtime — the fixtures were just written,
        # so backdate them past the 10-minute liveness window.
        stale = time.time() - 3600
        for f in sb["ws"].glob("local_*.json"):
            os.utime(f, (stale, stale))

        # 21. parseable envelope, schema match, stdout clean of panel glyphs
        rc, out, _ = run_mode(env, ["pick", "--json"])
        try:
            envlp = json.loads(out)
        except json.JSONDecodeError:
            envlp = {}
        pure_ascii = all(ord(c) < 128 for c in out)
        checks = {
            "rc": rc == 0,
            "parses": bool(envlp),
            "schema": envlp.get("meta", {}).get("schema") == "claude-mods.summon.pick/v1",
            "count": envlp.get("meta", {}).get("count") == 3 == len(envlp.get("data", [])),
            "stdout-json-only": out.lstrip().startswith("{") and pure_ascii,
            "no-glyphs": not any(g in out for g in ("╭", "│", "╰", "├", "\x1b[")),
        }
        if all(checks.values()):
            ok("pick --json emits parseable pick/v1 envelope; stdout clean")
        else:
            no("pick --json emits parseable pick/v1 envelope; stdout clean",
               f"failed={[k for k, v in checks.items() if not v]} rc={rc} out-head={out[:200]!r}")
            return

        rows = {r["sessionId"]: r for r in envlp["data"]}
        moved = rows.get("local_aaaa-moved", {})
        healthy = rows.get("local_bbbb-healthy", {})
        mismatch = rows.get("local_cccc-mismatch", {})

        # 22a. worktree cwd split into projectRoot + worktree
        if (moved.get("projectRoot") == str(sb["old_root"])
                and moved.get("worktree") == "wt1"
                and healthy.get("worktree") == ""
                and healthy.get("projectRoot") == healthy.get("cwd")):
            ok("pick --json splits worktree cwd into projectRoot + worktree")
        else:
            no("pick --json splits worktree cwd into projectRoot + worktree",
               f"moved-root={moved.get('projectRoot')!r} wt={moved.get('worktree')!r}")

        # 22b. brokenCwd flags the moved session only
        if (moved.get("brokenCwd") is True and healthy.get("brokenCwd") is False
                and mismatch.get("brokenCwd") is False):
            ok("pick --json flags brokenCwd for the missing-cwd session")
        else:
            no("pick --json flags brokenCwd for the missing-cwd session",
               f"moved={moved.get('brokenCwd')} healthy={healthy.get('brokenCwd')}")

        # 22c. transcriptPath resolved (incl. scan fallback), booleans + ISO stamps
        scan_path = sb["projects"] / "X--some-unrelated-munged-dir" / "cli-mismatch.jsonl"
        iso_re = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
        checks = {
            "scan-fallback": mismatch.get("transcriptPath") == str(scan_path),
            "expected-path": str(healthy.get("transcriptPath") or "").endswith("cli-healthy.jsonl"),
            "branch": moved.get("branch") == "claude/wt1",
            "not-running": healthy.get("isRunning") is False,
            "not-archived": healthy.get("isArchived") is False,
            "iso": all(iso_re.match(r["lastActivityAt"]) for r in envlp["data"]),
            "short-id": moved.get("id") == "aaaa-mov",
        }
        if all(checks.values()):
            ok("pick --json resolves transcriptPath; ISO stamps + field types sane")
        else:
            no("pick --json resolves transcriptPath; ISO stamps + field types sane",
               f"failed={[k for k, v in checks.items() if not v]}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main() -> int:
    # 1. Piped selection honoured even with --yes (the original bug: --yes
    #    used to select ALL candidates, ignoring the piped picks).
    tmp, env, _, dest_ws = with_sandbox()
    try:
        rc, out = run_summon(env, ["--yes"], stdin_text="1,3\n")
        got = copied_titles(dest_ws)
        if rc == 0 and got == {"alpha", "gamma"}:
            ok("--yes honours piped selection (copies 2 of 3)")
        else:
            no("--yes honours piped selection", f"rc={rc} copied={sorted(got)}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 2. --select answers the picker without stdin.
    tmp, env, _, dest_ws = with_sandbox()
    try:
        rc, out = run_summon(env, ["--select", "2", "--yes"])
        got = copied_titles(dest_ws)
        if rc == 0 and got == {"beta"}:
            ok("--select 2 copies exactly session #2")
        else:
            no("--select 2 copies exactly session #2", f"rc={rc} copied={sorted(got)}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 3. --select all selects everything.
    tmp, env, _, dest_ws = with_sandbox()
    try:
        rc, out = run_summon(env, ["--select", "all", "--yes"])
        got = copied_titles(dest_ws)
        if rc == 0 and got == {"alpha", "beta", "gamma"}:
            ok("--select all copies all 3")
        else:
            no("--select all copies all 3", f"rc={rc} copied={sorted(got)}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 4. Without --yes, declining the confirmation cancels.
    tmp, env, _, dest_ws = with_sandbox()
    try:
        rc, out = run_summon(env, [], stdin_text="1,2\nn\n")
        got = copied_titles(dest_ws)
        if rc == 0 and not got and "cancelled" in out:
            ok("confirmation 'n' cancels, nothing copied")
        else:
            no("confirmation 'n' cancels, nothing copied",
               f"rc={rc} copied={sorted(got)}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 5. Without --yes, confirming 'y' proceeds.
    tmp, env, _, dest_ws = with_sandbox()
    try:
        rc, out = run_summon(env, [], stdin_text="1\ny\n")
        got = copied_titles(dest_ws)
        if rc == 0 and got == {"alpha"}:
            ok("confirmation 'y' proceeds with the pick")
        else:
            no("confirmation 'y' proceeds with the pick",
               f"rc={rc} copied={sorted(got)}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 6. --yes with empty stdin cancels — must NOT fall back to select-all.
    tmp, env, _, dest_ws = with_sandbox()
    try:
        rc, out = run_summon(env, ["--yes"], stdin_text="")
        got = copied_titles(dest_ws)
        if rc == 0 and not got and "cancelled" in out:
            ok("--yes with no selection cancels (no auto-all)")
        else:
            no("--yes with no selection cancels (no auto-all)",
               f"rc={rc} copied={sorted(got)}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 7. Unicode title on cp1252 stdout must not crash (UnicodeEncodeError
    #    regression: U+2192 in a title with Windows cp1252 console encoding).
    tmp, env, _, dest_ws = with_sandbox(
        titles=("Update docs: Dagu → process-compose gallery", "beta", "gamma"))
    try:
        env_cp = dict(env)
        env_cp["PYTHONIOENCODING"] = "cp1252"
        rc, out = run_summon(env_cp, ["--select", "all", "--yes", "--dry-run"])
        if rc == 0 and "would copy" in out:
            ok("cp1252 stdout survives U+2192 in session title")
        else:
            no("cp1252 stdout survives U+2192 in session title",
               f"rc={rc} out-tail={out[-300:]!r}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    # 8-16. Toolbox modes: rebind / recover / pick / doctor
    toolbox_tests()

    # 17. Extraction (in-process unit tests)
    extraction_tests()

    # 18-20. Distilled handover: shim claude, cache lifecycle, degrade paths
    distill_tests()

    # 21-22. pick --json: envelope, clean stdout, worktree split, brokenCwd
    pick_json_tests()

    print(f"\nsummon tests: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
