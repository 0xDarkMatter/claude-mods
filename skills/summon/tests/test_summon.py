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

    print(f"\nsummon tests: {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
