#!/usr/bin/env python3
"""summon — Claude Desktop session toolbox: cross-account transfer + recover/rebind/doctor.

Usage:   summon [MODE] [ID] [OPTIONS]
Input:   optional MODE positional (rebind|pick|recover|doctor; omit for transfer),
         ID = sessionId/cliSessionId prefix for rebind/recover; picker reads stdin
Output:  transfer/pick/doctor render TTY panels; recover/pick emit a paste-ready
         handover on stdout — a Sonnet-distilled brief (Goal / What landed /
         Unfinished / Open decisions / Key context) + transcript pointer, cached
         at <transcript>.handover.md; falls back to the plain pointer prompt when
         the `claude` CLI is unavailable or --no-distill is set. doctor --json
         emits {"data": [...], "meta": {"schema": "claude-mods.summon.doctor/v1"}};
         pick --json emits the session inventory as
         {"data": [...], "meta": {"schema": "claude-mods.summon.pick/v1"}}
Stderr:  context panels for recover/pick, distillation progress, warnings, errors
Exit:    0 ok (including the non-distilled fallback — worker unavailability is
         advisory, never fatal), 2 usage/ambiguous id, 3 session or path not
         found, 10 doctor found broken sessions

Examples:
  summon --to mknv74                          # transfer: push sessions to next account
  summon pick                                 # fzf/numbered picker -> distilled handover
  summon pick --json | jq '.data[]'           # machine-readable session inventory
  summon recover 6577b24c                     # distilled handover brief for one session
  summon recover 6577b24c --refresh           # ignore cached brief, re-distill
  summon recover 6577b24c --no-distill        # plain pointer prompt, no LLM call
  summon recover 6577b24c --model haiku       # distill with a different model
  summon rebind 6577b24c --cwd X:\\Maplab\\LCMap\\.claude\\worktrees\\funny-hypatia-5e54f7
  summon doctor                               # scan all sessions for broken cwd bindings
  summon doctor --json | jq '.data[]'

Transfer mode (no positional) is documented in SKILL.md: copy by default, --move
to relocate, destination auto-detected as the most-recently-active account.

Output rendering follows docs/TERMINAL-DESIGN.md (Terminal Panel Design System).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import uuid as uuidlib
from collections import OrderedDict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


# ============================================================
#  DESIGN: terminal panel rendering (per docs/TERMINAL-DESIGN.md)
# ============================================================

def _stdout_supports_unicode() -> bool:
    enc = (getattr(sys.stdout, "encoding", "") or "").lower()
    return "utf" in enc or "cp65001" in enc


class Term:
    WIDTH = 80
    USE_ASCII = (
        os.environ.get("TERM_ASCII") == "1"
        or os.environ.get("TERM") == "dumb"
        or not _stdout_supports_unicode()
    )
    USE_COLOR = (
        sys.stdout.isatty()
        and os.environ.get("NO_COLOR") is None
        and os.environ.get("TERM") != "dumb"
        and os.environ.get("FORCE_COLOR") != "0"
    )

    @classmethod
    def g(cls, uni: str, asc: str) -> str:
        return asc if cls.USE_ASCII else uni

    @classmethod
    def color(cls, token: str, text: str) -> str:
        if not cls.USE_COLOR:
            return text
        codes = {
            "accent": "36",   # cyan
            "ok": "32",       # green
            "warn": "33",     # yellow
            "alarm": "31",    # red
            "tag": "35",      # magenta
            "meta": "2",      # dim
            "dim": "2",
            "default": "",
        }
        c = codes.get(token, "")
        if not c:
            return text
        return f"\033[{c}m{text}\033[0m"


_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def vlen(s: str) -> int:
    """Visible length, excluding ANSI escape codes."""
    return len(_ANSI_RE.sub("", s))


def trunc(s: str, width: int) -> str:
    """Truncate with ellipsis if too long."""
    if vlen(s) <= width:
        return s
    ell = Term.g("…", "...")
    return s[: width - vlen(ell)] + ell


# Brand emoji for summon (not in TERMINAL-DESIGN.md registry yet — registering here)
BRAND_EMOJI = "🪄"
BRAND_ASCII = "[S]"


def panel_open(name: str, indicator: str = "") -> str:
    """╭── 🪄 summon ─────────────────  indicator ───●"""
    em = Term.g(BRAND_EMOJI, BRAND_ASCII)
    tl = Term.g("╭", "+")
    h = Term.g("─", "-")
    term = Term.g("●", "*")
    left = f"{tl}{h}{h} {em} {Term.color('accent', name)} "
    if indicator:
        right = f" {Term.color('meta', indicator)} {h}{h}{h}{term}"
    else:
        right = f" {h}{h}{h}{term}"
    fill_count = max(2, Term.WIDTH - vlen(left) - vlen(right))
    return left + (h * fill_count) + right


def panel_close(hotkeys: list[tuple[str, str]] | None = None,
                healths: list[tuple[str, str]] | None = None) -> str:
    """╰── y confirm · n cancel ───── • 5 ready ───●"""
    bl = Term.g("╰", "+")
    h = Term.g("─", "-")
    term = Term.g("●", "*")
    bullet = Term.g("•", "(+)")
    hotkeys = hotkeys or []
    healths = healths or []

    sep = Term.g(" · ", " | ")
    hot_str = sep.join(f"{Term.color('accent', k)} {v}" for k, v in hotkeys)
    health_str = "  ".join(f"{Term.color(c, bullet)} {v}" for c, v in healths)

    left = f"{bl}{h}{h} {hot_str}" if hot_str else f"{bl}{h}{h}"
    if hot_str:
        left += " "
    right = f" {health_str} {h}{h}{h}{term}" if health_str else f" {h}{h}{h}{term}"
    fill = max(2, Term.WIDTH - vlen(left) - vlen(right))
    return left + (h * fill) + right


def panel_blank() -> str:
    return Term.g("│", "|")


def section(label: str, count: int = -1, color_token: str = "accent") -> str:
    """├── LABEL (count)"""
    tee = Term.g("├", "+")
    h = Term.g("─", "-")
    parens = f" ({count})" if count >= 0 else ""
    return f"{tee}{h}{h} {Term.color(color_token, label)}{Term.color('meta', parens)}"


def sub_section(label: str, count: int = -1, color_token: str = "default") -> str:
    """│   ├── LABEL (count)   — second-level grouping"""
    pipe = Term.g("│", "|")
    tee = Term.g("├", "+")
    h = Term.g("─", "-")
    parens = f" ({count})" if count >= 0 else ""
    return f"{pipe}   {tee}{h}{h} {Term.color(color_token, label)}{Term.color('meta', parens)}"


def sub_section_last(label: str, count: int = -1, color_token: str = "default") -> str:
    """│   └── LABEL (count)   — last sub-section"""
    pipe = Term.g("│", "|")
    corner = Term.g("└", "`")
    h = Term.g("─", "-")
    parens = f" ({count})" if count >= 0 else ""
    return f"{pipe}   {corner}{h}{h} {Term.color(color_token, label)}{Term.color('meta', parens)}"


def leaf(num: int, name: str, *, meta: str = "", age: str = "",
         last: bool = False, depth: int = 2,
         parent_last: bool = False,
         meta_color: str = "meta", age_color: str = "meta") -> str:
    """│   │   ├──  3. session-name        meta      age

    parent_last: when at depth 2 inside a last-sub-section, drop the inner
    pipe so it reads as siblings of the corner `└──` rather than continuing.
    """
    pipe = Term.g("│", "|")
    h = Term.g("─", "-")
    conn = Term.g("└", "`") if last else Term.g("├", "+")

    if depth == 1:
        prefix = f"{pipe}   "
    elif depth == 2:
        inner = "    " if parent_last else f"{pipe}   "
        prefix = f"{pipe}   {inner}"
    else:
        prefix = pipe + ("   " * depth)

    num_str = f"{num:>2}." if num else "   "
    name_field = trunc(name, 32).ljust(32)
    # Tight meta column — turn count only (e.g. "30t").
    meta_width = 8
    meta_visible = vlen(meta)
    if meta_visible <= meta_width:
        pad = " " * (meta_width - meta_visible)
        meta_field = Term.color(meta_color, meta) + pad
    else:
        meta_field = Term.color(meta_color, meta)
    age_field = Term.color(age_color, age).rjust(6) if age else " " * 6

    return f"{prefix}{conn}{h}{h} {num_str} {name_field}  {meta_field}  {age_field}"


def summary_line(text: str) -> str:
    """├── 4 lanes · 3 active   (dim)"""
    tee = Term.g("├", "+")
    h = Term.g("─", "-")
    return f"{tee}{h}{h} {Term.color('meta', text)}"


# Hint registry — each entry has a `when` predicate (over a context dict) and
# a `text` template (str.format-able). Predicates returning True make the hint
# eligible; one is picked at random.
HINTS: list[dict] = [
    # --- Conditional ---
    {
        "id": "density",
        "when": lambda c: c["count"] > 30,
        "text": "{count} sessions — narrow with --cwd <pat> or --title <pat>, "
                "or shorten the window with --1d/--3d/--7d",
    },
    {
        "id": "generic-titles",
        "when": lambda c: c["generic_count"] >= 3,
        "text": "{generic_count} sessions have generic titles (dev, general, untitled). "
                "Use `summon --peek <id>` to preview the last messages before pulling",
    },
    {
        "id": "default-window",
        "when": lambda c: c["window_days"] == 3 and c["count"] >= 5,
        "text": "default window is 3 days — `--all` to see everything, "
                "`--1d` for just today, `--7d` for a week, or `--days N` for custom",
    },
    {
        "id": "remote-skipped",
        "when": lambda c: c["remote_count"] > 0,
        "text": "{remote_count} remote-VM session(s) auto-skipped — they have no "
                "local transcript to bridge, so cross-account transfer isn't possible",
    },
    # --- Always-eligible (rotate as background tips) ---
    {
        "id": "peek",
        "when": lambda _: True,
        "text": "preview a session's last messages with `summon --peek <id>` — handy "
                "when titles like 'dev' don't tell you which one is which",
    },
    {
        "id": "copy-vs-move",
        "when": lambda _: True,
        "text": "default is copy (visible from both accounts) — pass `--move` "
                "to delete the source for lean cleanup",
    },
    {
        "id": "logout-login",
        "when": lambda _: True,
        "text": "Desktop only loads sessions at login — Cowork/Code toggle, Ctrl+R, "
                "and tab clicks won't rescan. Plan for Logout/Login when you switch",
    },
    {
        "id": "proactive",
        "when": lambda _: True,
        "text": "best run BEFORE switching accounts: copy sessions to the next "
                "account first, then Logout/Login (the switch you were doing anyway)",
    },
    {
        "id": "dry-run",
        "when": lambda _: True,
        "text": "`--dry-run` previews a move without touching files — pair it with "
                "`--pick` to rehearse the picker without committing",
    },
]


def _pick_hint(context: dict) -> str:
    """Pick one hint from HINTS whose predicate matches the context, or '' if none."""
    import random
    eligible = [h for h in HINTS if _hint_safe(h["when"], context)]
    if not eligible:
        return ""
    chosen = random.choice(eligible)
    try:
        return chosen["text"].format(**context)
    except (KeyError, ValueError):
        return chosen["text"]


def _hint_safe(predicate, context) -> bool:
    try:
        return bool(predicate(context))
    except Exception:
        return False


def hint(text: str, width: int = 70) -> str:
    """│   💡  text — tip riding the panel rail.

    Continuation lines wrap under the text, not under the icon, so the eye
    follows the message rather than re-finding column alignment.
    """
    pipe = Term.g("│", "|")
    bulb = Term.g("💡", "(i)")
    # Visual cells: pipe(1) + 3sp + bulb(2 if emoji, 3 if ASCII) + 2sp
    bulb_cells = 3 if Term.USE_ASCII else 2
    indent_after_pipe = 3 + bulb_cells + 2  # spaces between pipe and text
    cont_pad = " " * indent_after_pipe

    # Word-wrap to `width` chars per content line.
    words = text.split(" ")
    lines: list[str] = []
    current = ""
    for w in words:
        candidate = f"{current} {w}".strip()
        if len(candidate) <= width:
            current = candidate
        else:
            if current:
                lines.append(current)
            current = w
    if current:
        lines.append(current)
    if not lines:
        return ""

    out = [f"{pipe}   {bulb}  {Term.color('meta', lines[0])}"]
    for line in lines[1:]:
        out.append(f"{pipe}{cont_pad}{Term.color('meta', line)}")
    return "\n".join(out)


def _print_safe(line: str = "") -> None:
    """print() that survives narrow stdout encodings (e.g. Windows cp1252).

    Session titles carry arbitrary Unicode (e.g. '→') that the console
    encoding may not represent; degrade those chars to '?' instead of
    crashing with UnicodeEncodeError.
    """
    try:
        print(line)
    except UnicodeEncodeError:
        enc = getattr(sys.stdout, "encoding", None) or "ascii"
        print(str(line).encode(enc, errors="replace").decode(enc, errors="replace"))


def echo(*lines):
    if not lines:
        _print_safe()
        return
    for line in lines:
        _print_safe(line)


# ============================================================
#  Path discovery
# ============================================================

def appdata_claude() -> Path:
    plat = str(sys.platform)
    if plat == "win32":
        appdata = os.environ.get("APPDATA")
        if not appdata:
            sys.exit("APPDATA env var not set; can't locate Claude Desktop dir")
        return Path(appdata) / "Claude"
    if plat == "darwin":
        return Path.home() / "Library/Application Support/Claude"
    return Path.home() / ".config/Claude"


def cli_jsonl_root() -> Path:
    return Path.home() / ".claude" / "projects"


def encode_cwd(cwd: str) -> str:
    """Convert cwd to ~/.claude/projects/ subdir name.

    Each ':', '\\', '/', '.' becomes '-'; consecutive separators stay consecutive.
    'X:\\Forge\\Axiom\\.claude\\worktrees\\foo' -> 'X--Forge-Axiom--claude-worktrees-foo'
    """
    return (cwd
            .replace(":", "-")
            .replace("\\", "-")
            .replace("/", "-")
            .replace(".", "-"))


# ============================================================
#  Account discovery
# ============================================================

@dataclass
class Account:
    uuid: str
    sessions_dir: Path
    email: str = ""
    last_activity: float = 0.0
    session_count: int = 0

    @property
    def short(self) -> str:
        return self.uuid[:8]

    @property
    def label(self) -> str:
        sep = Term.g("·", "|")
        return f"{self.email or '(unknown)'} {sep} {self.short}"


def _iter_session_files(account_dir: Path) -> Iterable[Path]:
    for ws in account_dir.iterdir():
        if not ws.is_dir():
            continue
        yield from ws.glob("local_*.json")


def _find_account_email(agent_root: Path, account_uuid: str) -> str:
    acct_dir = agent_root / account_uuid
    if not acct_dir.is_dir():
        return ""
    for ws in acct_dir.iterdir():
        if not ws.is_dir():
            continue
        for f in ws.glob("local_*.json"):
            try:
                d = json.loads(f.read_text(encoding="utf-8"))
                email = d.get("emailAddress", "")
                if email:
                    return email
            except (json.JSONDecodeError, OSError):
                continue
    return ""


def discover_accounts(claude_dir: Path) -> list[Account]:
    sessions_root = claude_dir / "claude-code-sessions"
    if not sessions_root.is_dir():
        return []
    agent_root = claude_dir / "local-agent-mode-sessions"
    accounts: list[Account] = []
    for acct_dir in sessions_root.iterdir():
        if not acct_dir.is_dir():
            continue
        sessions = list(_iter_session_files(acct_dir))
        if not sessions:
            continue
        last = max((s.stat().st_mtime for s in sessions), default=0.0)
        accounts.append(Account(
            uuid=acct_dir.name,
            sessions_dir=acct_dir,
            email=_find_account_email(agent_root, acct_dir.name),
            last_activity=last,
            session_count=len(sessions),
        ))
    return sorted(accounts, key=lambda a: -a.last_activity)


def detect_destination(accounts: list[Account]) -> Account | None:
    return accounts[0] if accounts else None


def resolve_account(query: str, accounts: list[Account]) -> Account | None:
    q = query.lower()
    for a in accounts:
        if a.uuid == query:
            return a
    for a in accounts:
        if a.uuid.startswith(query):
            return a
    for a in accounts:
        if q in a.email.lower():
            return a
    return None


# ============================================================
#  Sessions
# ============================================================

@dataclass
class Session:
    path: Path
    data: dict
    account: Account

    @property
    def sid(self) -> str:
        return self.data.get("sessionId", "")

    @property
    def cli_id(self) -> str:
        return self.data.get("cliSessionId", "")

    @property
    def cwd(self) -> str:
        return self.data.get("cwd", "")

    @property
    def title(self) -> str:
        return self.data.get("title", "(untitled)")

    @property
    def turns(self) -> int:
        return int(self.data.get("completedTurns", 0))

    @property
    def last_activity_ms(self) -> int:
        return int(self.data.get("lastActivityAt", 0))

    @property
    def is_remote(self) -> bool:
        return self.cwd.startswith("/sessions/")

    def transcript_path(self) -> Path | None:
        if not self.cli_id or not self.cwd:
            return None
        return cli_jsonl_root() / encode_cwd(self.cwd) / f"{self.cli_id}.jsonl"


def load_sessions(account: Account) -> list[Session]:
    out: list[Session] = []
    for f in _iter_session_files(account.sessions_dir):
        try:
            data = json.loads(f.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        out.append(Session(path=f, data=data, account=account))
    return out


def filter_sessions(
    sessions: list[Session],
    *,
    days: int | None,
    cwd_pattern: str = "",
    title_pattern: str = "",
) -> list[Session]:
    now_ms = int(time.time() * 1000)
    cutoff_ms = now_ms - (days * 86_400_000) if days is not None else 0
    out = []
    for s in sessions:
        if s.is_remote:
            continue
        if days is not None and s.last_activity_ms < cutoff_ms:
            continue
        if cwd_pattern and cwd_pattern.lower() not in s.cwd.lower():
            continue
        if title_pattern and title_pattern.lower() not in s.title.lower():
            continue
        out.append(s)
    return sorted(out, key=lambda s: -s.last_activity_ms)


# ============================================================
#  Grouping
# ============================================================

_WORKTREE_MARKERS = (
    "\\.claude\\worktrees\\",
    "/.claude/worktrees/",
)


def project_root(cwd: str) -> str:
    for marker in _WORKTREE_MARKERS:
        if marker in cwd:
            return cwd.split(marker)[0]
    return cwd


def relative_under_root(cwd: str, root: str) -> str:
    if cwd == root:
        return ""
    if cwd.startswith(root):
        return cwd[len(root):].lstrip("\\/")
    return cwd


def worktree_name(cwd: str) -> str:
    """If cwd is inside a `.claude/worktrees/<name>/...` path, return <name>; else ''."""
    for marker in _WORKTREE_MARKERS:
        if marker in cwd:
            tail = cwd.split(marker, 1)[1]
            # First path segment is the worktree name; strip any deeper subpath.
            return tail.split("\\", 1)[0].split("/", 1)[0]
    return ""


# ============================================================
#  Listing
# ============================================================

def render_hierarchy(sessions: list[Session], *, grouped: bool) -> dict[int, Session]:
    """Print sessions; return {1-based-index: session}."""
    if grouped:
        return _render_grouped(sessions)
    index_map: dict[int, Session] = {}
    for n, s in enumerate(sessions, 1):
        index_map[n] = s
        ago = _ago(s.last_activity_ms)
        meta = f"{s.turns} turns"
        display = f"{s.title}  ({s.cwd})"
        echo(leaf(n, display, meta=meta, age=ago, depth=1))
    return index_map


def _render_grouped(sessions: list[Session]) -> dict[int, Session]:
    """3-level hierarchy: Account -> Project -> Session."""
    index_map: dict[int, Session] = {}

    by_account: "OrderedDict[str, list[Session]]" = OrderedDict()
    for s in sessions:
        by_account.setdefault(s.account.uuid, []).append(s)

    n = 0
    for _, acct_sessions in by_account.items():
        acct = acct_sessions[0].account

        # Group within account by project root
        by_project: "OrderedDict[str, list[Session]]" = OrderedDict()
        for s in acct_sessions:
            by_project.setdefault(project_root(s.cwd), []).append(s)

        # Account header
        echo(panel_blank())
        echo(section(acct.email or "(unknown)", len(acct_sessions), color_token="accent"))

        proj_items = list(by_project.items())
        for pi, (root, members) in enumerate(proj_items):
            is_last_proj = pi == len(proj_items) - 1
            sub_func = sub_section_last if is_last_proj else sub_section
            echo(sub_func(root, len(members), color_token="default"))

            for li, s in enumerate(members):
                n += 1
                index_map[n] = s
                is_last_session = li == len(members) - 1
                ago = _ago(s.last_activity_ms)
                meta = f"{s.turns}t"
                echo(leaf(n, s.title, meta=meta, age=ago,
                          last=is_last_session, depth=2,
                          parent_last=is_last_proj))

    echo(panel_blank())
    return index_map


def _window_label(days: int | None) -> str:
    """Render the active time-window filter label."""
    if days is None:
        return "all time"
    if days <= 1:
        return "last 24h"
    return f"last {days}d"


def _ago(ms: int) -> str:
    if ms == 0:
        return "?"
    delta_s = max(0, int(time.time()) - (ms // 1000))
    if delta_s < 60:
        return f"{delta_s}s"
    if delta_s < 3600:
        return f"{delta_s // 60}m"
    if delta_s < 86400:
        return f"{delta_s // 3600}h"
    return f"{delta_s // 86400}d"


# ============================================================
#  Picker
# ============================================================

def interactive_pick(sessions: list[Session], *, grouped: bool) -> list[Session]:
    if not sessions:
        return []
    index_map = _render_grouped(sessions) if grouped else render_hierarchy(sessions, grouped=False)
    print()
    raw = input(Term.color("accent", "select> ")
                + "(numbers like '3,5,7', 'a' for all, blank to cancel): ").strip()
    if not raw:
        return []
    if raw.lower() == "a":
        return sessions
    picks = []
    for tok in raw.split(","):
        tok = tok.strip()
        if not tok:
            continue
        try:
            i = int(tok)
            if i in index_map:
                picks.append(index_map[i])
        except ValueError:
            continue
    return picks


# ============================================================
#  Workspace selection
# ============================================================

def pick_destination_workspace(account: Account) -> Path:
    workspaces = [w for w in account.sessions_dir.iterdir() if w.is_dir()]
    if not workspaces:
        new_ws = account.sessions_dir / str(uuidlib.uuid4())
        new_ws.mkdir(parents=True)
        return new_ws
    workspaces.sort(key=lambda w: -w.stat().st_mtime)
    return workspaces[0]


# ============================================================
#  Operate
# ============================================================

def summon_session(s: Session, dest_workspace: Path, *, move: bool, dry_run: bool) -> str:
    target = dest_workspace / s.path.name
    if target.exists():
        return "skip (already there)"
    if not s.cli_id:
        return "skip (no cliSessionId)"
    transcript = s.transcript_path()
    if transcript and not transcript.exists():
        return "skip (transcript missing)"
    if dry_run:
        return "would " + ("move" if move else "copy")
    op = shutil.move if move else shutil.copy2
    op(str(s.path), str(target))
    return "moved" if move else "copied"


def nudge_watcher(workspace_dir: Path, moved_files: list[Path] | None = None) -> None:
    """Force fs.watch to fire on the destination workspace dir.

    Desktop's fs.watch is finicky — sometimes it picks up move-in events
    immediately, sometimes it doesn't. We throw the kitchen sink at it:

      1. mtime update on each moved file (write event)
      2. Rename ping-pong on each moved file (move-out + move-in events)
      3. Sentinel create+delete in workspace dir (dir-mod event)
      4. Sentinel create+delete in account dir (parent dir-mod event)
      5. mtime update on workspace dir (dir-mod event)
      6. mtime update on account dir (parent dir-mod event)

    All paths are tried; failures are silent.

    Empirically: even with all of these, Desktop's renderer may still
    require a Logout -> Login cycle to refresh the sidebar. That's
    documented in SKILL.md as the canonical fallback.
    """
    now = time.time()
    account_dir = workspace_dir.parent

    # 1. mtime update on moved files
    for f in (moved_files or []):
        try:
            os.utime(f, (now, now))
        except OSError:
            pass

    # 2. Rename ping-pong on moved files
    for f in (moved_files or []):
        if not f.exists():
            continue
        tmp = f.with_name(f.name + ".summon-tmp")
        try:
            f.rename(tmp)
            tmp.rename(f)
        except OSError:
            try:
                if tmp.exists():
                    tmp.rename(f)
            except OSError:
                pass

    # 3 + 4. Sentinel pings at workspace AND account level
    for parent in (workspace_dir, account_dir):
        sentinel = parent / f".summon-nudge-{uuidlib.uuid4().hex[:8]}"
        try:
            sentinel.touch()
            sentinel.unlink()
        except OSError:
            pass

    # 5 + 6. mtime touch on workspace and account dirs
    for d in (workspace_dir, account_dir):
        try:
            os.utime(d, (now, now))
        except OSError:
            pass


# ============================================================
#  Peek
# ============================================================

def find_session_by_id(query: str, accounts: list[Account]) -> Session | None:
    q = query.lower().removeprefix("local_")
    for acct in accounts:
        for s in load_sessions(acct):
            sid = s.sid.lower().removeprefix("local_")
            cli = s.cli_id.lower()
            if sid == q or cli == query.lower():
                return s
            if sid.startswith(q) or cli.startswith(q):
                return s
    return None


def peek_session(query: str, accounts: list[Account], turns: int = 3) -> int:
    s = find_session_by_id(query, accounts)
    if not s:
        echo(panel_open(f"summon {Term.g('·', '|')} peek", indicator="not found"))
        echo(panel_blank())
        echo(f"   no session matching: {Term.color('alarm', query)}")
        echo(panel_blank())
        echo(panel_close())
        return 1
    transcript = s.transcript_path()
    if not transcript or not transcript.exists():
        echo(panel_open(f"summon {Term.g('·', '|')} peek", indicator=f"{s.account.short} {Term.g('·', '|')} {s.title}"))
        echo(panel_blank())
        echo(f"   transcript missing: {Term.color('alarm', str(transcript))}")
        echo(panel_blank())
        echo(panel_close())
        return 2

    exchanges: list[tuple[str, str]] = []
    try:
        with transcript.open("r", encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t = rec.get("type")
                if t not in ("user", "assistant"):
                    continue
                msg = rec.get("message", {})
                text = _extract_text(msg.get("content"))
                if text:
                    exchanges.append((t, text))
    except OSError as e:
        echo(panel_open(f"summon {Term.g('·', '|')} peek", indicator="read error"))
        echo(panel_blank())
        echo(f"   {Term.color('alarm', str(e))}")
        echo(panel_blank())
        echo(panel_close())
        return 2

    indicator = f"{s.account.email or s.account.short}"
    echo(panel_open(f"summon {Term.g('·', '|')} peek", indicator=indicator))
    echo(panel_blank())
    sep = Term.g("·", "|")
    echo(summary_line(f"{s.title!r}   {s.cwd}"))
    echo(summary_line(f"{s.turns} turns {sep} last activity {_ago(s.last_activity_ms)}"))
    echo(panel_blank())

    if not exchanges:
        echo(f"   {Term.color('meta', '(transcript has no readable user/assistant messages)')}")
        echo(panel_blank())
        echo(panel_close())
        return 0

    tail = exchanges[-(turns * 2):]
    echo(section(f"last {len(tail)} message(s)", color_token="accent"))
    for role, text in tail:
        marker = Term.color("accent", ">>") if role == "user" else Term.color("ok", "<<")
        snippet = text.strip().replace("\n", " ")
        if len(snippet) > 600:
            snippet = snippet[:597] + "..."
        echo(panel_blank())
        # Wrap to 70 chars per line
        words = snippet.split(" ")
        line_width = 70
        line = ""
        first = True
        for w in words:
            candidate = (line + " " + w) if line else w
            if len(candidate) <= line_width:
                line = candidate
            else:
                pipe = Term.g("│", "|")
                lead = f"{pipe}   {marker} " if first else f"{pipe}      "
                echo(f"{lead}{line}")
                line = w
                first = False
        if line:
            pipe = Term.g("│", "|")
            lead = f"{pipe}   {marker} " if first else f"{pipe}      "
            echo(f"{lead}{line}")

    echo(panel_blank())
    echo(panel_close(hotkeys=[("q", "quit")]))
    return 0


def _extract_text(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        chunks = []
        for block in content:
            if isinstance(block, dict):
                t = block.get("type")
                if t == "text":
                    chunks.append(block.get("text", ""))
                elif t == "tool_use":
                    chunks.append(f"[tool_use: {block.get('name', '?')}]")
                elif t == "tool_result":
                    chunks.append("[tool_result]")
        return " ".join(chunks)
    return ""


# ============================================================
#  Toolbox modes: rebind / pick / recover / doctor
# ============================================================

def eecho(*lines):
    """echo() to stderr — context/panels for modes whose stdout is the data product."""
    if not lines:
        lines = ("",)
    for line in lines:
        try:
            print(line, file=sys.stderr)
        except UnicodeEncodeError:
            enc = getattr(sys.stderr, "encoding", None) or "ascii"
            print(str(line).encode(enc, errors="replace").decode(enc, errors="replace"),
                  file=sys.stderr)


def resolve_transcript(s: Session) -> tuple[Path | None, str]:
    """Locate a session's transcript JSONL.

    Returns (path, how) with how in:
      "expected"  — at ~/.claude/projects/<enc(cwd)>/<cliSessionId>.jsonl
      "scanned"   — found by scanning all project dirs for <cliSessionId>.jsonl
                    (the wrapper-uuid != transcript-filename trap: the transcript
                    is named by cliSessionId, and may live under a munged dir that
                    doesn't derive from the wrapper's recorded cwd)
      ""          — not found anywhere (path is None)
    """
    if not s.cli_id:
        return None, ""
    expected = s.transcript_path()
    if expected and expected.exists():
        return expected, "expected"
    hits = sorted(cli_jsonl_root().glob(f"*/{s.cli_id}.jsonl"))
    if hits:
        return hits[0], "scanned"
    return None, ""


# Boilerplate the first-ask sniffer must skip: slash-command echoes, skill
# preambles, interrupt markers — none of which are the session's real opening ask.
_ASK_SKIP_MARKERS = (
    "command-name", "local-command", "Sync - Session Bootstrap",
    "Base directory for this skill", "[Request interrupted",
)


def _ts_ms(value: str) -> int | None:
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)
    except (ValueError, AttributeError):
        return None


def analyze_transcript(path: Path | None, buckets: int = 24) -> dict:
    """Stream a transcript JSONL once and derive picker display metrics.

    Returns events / toolCalls / density buckets / durationMin / sizeKB /
    ctxTokens (last-turn context occupancy, matching Claude Code's live meter) /
    ctxPeak (max occupancy before any auto-compaction) / firstAsk. Every field
    degrades to a zero/empty default on a missing or unreadable transcript, so
    the picker still renders — just without the extras. One pass, so a large
    transcript costs one linear read, never a re-scan.
    """
    out = {"events": 0, "toolCalls": 0, "buckets": [0] * buckets,
           "durationMin": 0, "sizeKB": 0, "ctxTokens": 0, "ctxPeak": 0,
           "firstAsk": ""}
    if not path or not path.exists():
        return out
    try:
        out["sizeKB"] = round(path.stat().st_size / 1024)
    except OSError:
        pass
    stamps: list[int] = []
    last_ctx = peak_ctx = 0
    try:
        with path.open(encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                out["events"] += 1
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                stamp = obj.get("timestamp")
                if stamp:
                    ms = _ts_ms(stamp)
                    if ms:
                        stamps.append(ms)
                msg = obj.get("message")
                msg = msg if isinstance(msg, dict) else {}
                usage = msg.get("usage")
                if isinstance(usage, dict):
                    occ = (usage.get("input_tokens", 0)
                           + usage.get("cache_creation_input_tokens", 0)
                           + usage.get("cache_read_input_tokens", 0)
                           + usage.get("output_tokens", 0))
                    if occ:
                        last_ctx = occ
                        peak_ctx = max(peak_ctx, occ)
                typ = obj.get("type")
                if typ == "assistant":
                    content = msg.get("content")
                    if isinstance(content, list):
                        out["toolCalls"] += sum(
                            1 for p in content
                            if isinstance(p, dict) and p.get("type") == "tool_use")
                elif typ == "user" and not out["firstAsk"]:
                    content = msg.get("content")
                    if isinstance(content, str):
                        txt = content
                    elif isinstance(content, list):
                        txt = "".join(p.get("text", "") for p in content
                                      if isinstance(p, dict) and p.get("type") == "text")
                    else:
                        txt = ""
                    txt = txt.strip()
                    if txt and not txt.startswith("<") and not any(
                            m in txt for m in _ASK_SKIP_MARKERS):
                        out["firstAsk"] = txt[:280]
    except OSError:
        return out
    out["ctxTokens"] = last_ctx
    out["ctxPeak"] = peak_ctx
    if stamps:
        lo, hi = min(stamps), max(stamps)
        span = hi - lo
        out["durationMin"] = round(span / 60000)
        counts = [0] * buckets
        for ms in stamps:
            idx = 0 if span <= 0 else min(buckets - 1, int((ms - lo) / span * buckets))
            counts[idx] += 1
        out["buckets"] = counts
    return out


def find_wrappers_by_id(query: str, accounts: list[Account]) -> tuple[list[Session], bool]:
    """All wrapper files for one logical session (copies may exist in several accounts).

    Matches sessionId or cliSessionId, exact first, then prefix. Returns
    (matches, ambiguous): ambiguous=True when a prefix hits MORE than one
    distinct logical session.
    """
    q = query.lower().removeprefix("local_")
    exact: list[Session] = []
    prefix: list[Session] = []
    for acct in accounts:
        for s in load_sessions(acct):
            sid = s.sid.lower().removeprefix("local_")
            cli = s.cli_id.lower()
            if sid == q or cli == q:
                exact.append(s)
            elif sid.startswith(q) or cli.startswith(q):
                prefix.append(s)
    matches = exact or prefix
    logical = {s.sid for s in matches}
    return matches, len(logical) > 1


def _rebase_path(old_val: str, old_cwd: str, new_cwd: str) -> str:
    """Rebase a sibling path field (originCwd/worktreePath) after cwd moves.

    Worktree sessions record originCwd as the project ROOT while cwd is the
    worktree path under it — so a plain prefix replace isn't enough:
      old_val == old_cwd                      -> new_cwd
      old_cwd == old_val + suffix (root case) -> strip the same suffix off new_cwd
      old_val == old_cwd + suffix (child)     -> new_cwd + suffix
    Anything else is left untouched.
    """
    if not old_val:
        return old_val
    if old_val == old_cwd:
        return new_cwd
    if old_cwd.startswith(old_val):
        suffix = old_cwd[len(old_val):]
        if suffix and new_cwd.endswith(suffix):
            return new_cwd[: len(new_cwd) - len(suffix)]
    if old_val.startswith(old_cwd):
        return new_cwd + old_val[len(old_cwd):]
    return old_val


def mode_rebind(args, accounts: list[Account]) -> int:
    """Fix a session's recorded cwd after a folder move.

    Backs up each wrapper OUTSIDE the live store, atomically rewrites
    cwd/originCwd/worktreePath, bridges the transcript into the new munged
    project dir (Desktop resolves it via enc(cwd)), and verifies by re-read.
    """
    if not args.target:
        eecho("usage: summon rebind <id> --cwd <newpath>")
        return 2
    if not args.cwd:
        eecho("rebind needs --cwd <newpath> — the folder's new location")
        return 2

    new_path = Path(args.cwd)
    if new_path.exists():
        new_cwd = str(new_path.resolve())
    elif args.force:
        new_cwd = str(new_path)
    else:
        eecho(f"new cwd does not exist on disk: {args.cwd}",
              "(pass --force to rebind to a not-yet-existing path)")
        return 3

    matches, ambiguous = find_wrappers_by_id(args.target, accounts)
    if not matches:
        eecho(f"no session matching: {args.target}")
        return 3
    if ambiguous:
        eecho(f"'{args.target}' matches {len({m.sid for m in matches})} different sessions — be more specific:")
        for m in matches[:8]:
            eecho(f"  {m.sid}  {m.title!r}  {m.cwd}")
        return 2

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    backup_root = Path.home() / ".claude" / "summon-backups" / stamp

    echo(panel_open(f"summon {Term.g('·', '|')} rebind",
                    indicator="dry-run" if args.dry_run else matches[0].sid[:14]))
    echo(panel_blank())
    old_cwd = matches[0].cwd
    echo(summary_line(f"{old_cwd}"))
    echo(summary_line(f"{Term.g('→', '->')} {new_cwd}"))
    echo(panel_blank())

    problems = 0
    transcript_note = ""
    for i, s in enumerate(matches):
        is_last = i == len(matches) - 1
        label = f"{s.account.short}/{s.path.name}"

        if args.dry_run:
            echo(leaf(0, label, meta=Term.color("meta", "would rebind"),
                      last=is_last, depth=1))
            continue

        # 1. Backup outside the live store
        backup_root.mkdir(parents=True, exist_ok=True)
        backup = backup_root / f"{s.account.uuid}__{s.path.parent.name}__{s.path.name}"
        shutil.copy2(s.path, backup)

        # 2. Atomic rewrite
        data = dict(s.data)
        data["cwd"] = new_cwd
        for field in ("originCwd", "worktreePath"):
            if field in data:
                data[field] = _rebase_path(str(data[field] or ""), s.cwd, new_cwd)
        tmp = s.path.with_name(s.path.name + ".tmp")
        tmp.write_text(json.dumps(data, indent=2), encoding="utf-8")
        os.replace(tmp, s.path)

        # 3. Verify by re-read
        try:
            reread = json.loads(s.path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            reread = {}
        if reread.get("cwd") != new_cwd:
            problems += 1
            shutil.copy2(backup, s.path)  # restore from backup
            echo(leaf(0, label, meta=Term.color("alarm", "verify FAILED — restored"),
                      last=is_last, depth=1))
            continue

        echo(leaf(0, label, meta=Term.color("ok", "rebound"), last=is_last, depth=1))

    # 4. Transcript bridge — Desktop looks in enc(new cwd) after the rebind
    s0 = matches[0]
    if s0.cli_id:
        old_transcript, how = resolve_transcript(s0)  # s0.data still holds OLD cwd
        new_dir = cli_jsonl_root() / encode_cwd(new_cwd)
        new_transcript = new_dir / f"{s0.cli_id}.jsonl"
        if new_transcript.exists():
            transcript_note = "transcript already at new path"
        elif not old_transcript:
            transcript_note = "transcript missing everywhere — session may not reopen"
            problems += 1
        elif args.no_transcript:
            transcript_note = f"transcript NOT copied (--no-transcript): {old_transcript}"
        elif args.dry_run:
            transcript_note = f"would copy transcript {Term.g('→', '->')} {new_transcript}"
        else:
            new_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(old_transcript, new_transcript)
            transcript_note = f"transcript copied ({how}) {Term.g('→', '->')} {new_transcript}"

    echo(panel_blank())
    if transcript_note:
        echo(summary_line(transcript_note))
    if not args.dry_run:
        echo(summary_line(f"backup: {backup_root}"))
    echo(panel_blank())
    healths = [("ok", f"{len(matches)} wrapper(s)")]
    if problems:
        healths.append(("alarm", f"{problems} problem(s)"))
    echo(panel_close(healths=healths))
    if not args.dry_run and not problems:
        echo()
        echo(Term.color("warn",
             "next: restart Desktop (or Logout/Login) so the sidebar re-reads the wrapper."))
        if any(m in new_cwd for m in _WORKTREE_MARKERS):
            echo(Term.color("meta",
                 "  git worktree links break on folder moves — run "
                 f"`git worktree repair {new_cwd}` from the repo root."))
    return 1 if problems else 0


_RECOVERY_INSTRUCTION = (
    "First read only the TAIL of the transcript (last ~150-200 lines) to see where "
    "it left off — do not ingest the whole file; read earlier chunks selectively "
    "only if something is unclear. Then: summarize the session state in a few "
    "bullets (goal, what's done, what was in flight, blockers), and continue the "
    "work from there in the current directory."
)


# --- Distilled handover: extract -> distill -> cache -> emit -----------------

EXTRACT_BUDGET_DEFAULT = 120_000   # chars of conversation fed to the distiller
VERBATIM_TAIL_TURNS = 15           # final turns always included in full
HEAD_TURN_CAP = 4_000              # per-turn cap for pre-tail turns (giant pastes)
DISTILL_TIMEOUT_S = 60
DISTILL_MODEL_DEFAULT = "sonnet"

_DISTILL_INSTRUCTION = """\
You are writing a HANDOVER BRIEF so a fresh Claude session can continue an \
interrupted one. Below is the previous session's conversation with tool noise \
removed; the final turns are verbatim.

Produce ONLY the brief, in markdown, with exactly these sections:

## Goal
## What landed
## Unfinished
## Open decisions
## Key context

Rules:
- "What landed" names the branch and any commits/hashes if mentioned.
- Be specific: file paths, branch names, commands, decisions.
- Do not invent anything not present in the conversation.
- No preamble, no closing remarks, no tool use.
- Keep the entire brief under about 1000 words.
"""


def _text_only(content) -> str:
    """Conversational text only — tool_use inputs and tool_result blobs are
    skipped entirely (they are most of a transcript's bytes)."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        chunks = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                t = block.get("text", "")
                if t:
                    chunks.append(t)
        return "\n".join(chunks)
    return ""


def extract_conversation(transcript: Path, budget: int = EXTRACT_BUDGET_DEFAULT) -> str:
    """Build the distillation input from a transcript JSONL — in-script, no LLM.

    User/assistant text turns only. The final VERBATIM_TAIL_TURNS turns are
    always included in full; earlier turns fill the remaining budget from the
    START (so the goal statement survives), with the middle elided when the
    session is too long to fit.
    """
    turns: list[tuple[str, str]] = []
    try:
        with transcript.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                role = rec.get("type")
                if role not in ("user", "assistant"):
                    continue
                text = _text_only(rec.get("message", {}).get("content")).strip()
                if text:
                    turns.append((role, text))
    except OSError:
        return ""
    if not turns:
        return ""

    def fmt(role: str, text: str) -> str:
        return f"{role.upper()}: {text}"

    tail = turns[-VERBATIM_TAIL_TURNS:]
    head = turns[:-VERBATIM_TAIL_TURNS]
    tail_block = "\n\n".join(fmt(r, t) for r, t in tail)
    if len(tail_block) >= budget:
        return tail_block[-budget:]  # most recent state wins

    remaining = budget - len(tail_block)
    head_parts: list[str] = []
    elided = not head
    for r, t in head:
        if len(t) > HEAD_TURN_CAP:
            t = t[:HEAD_TURN_CAP] + " …[turn truncated]"
        piece = fmt(r, t)
        cost = len(piece) + 2
        if cost > remaining:
            elided = True
            break
        head_parts.append(piece)
        remaining -= cost

    parts = list(head_parts)
    if elided and head_parts:
        parts.append("[… middle of session elided to fit extraction budget …]")
    parts.append(tail_block)
    return "\n\n".join(parts)


def handover_cache_path(transcript: Path) -> Path:
    return transcript.with_name(transcript.name + ".handover.md")


def load_cached_brief(transcript: Path, *, refresh: bool) -> str | None:
    """Cached brief, valid only when newer than the transcript itself."""
    if refresh:
        return None
    cache = handover_cache_path(transcript)
    try:
        if cache.exists() and cache.stat().st_mtime > transcript.stat().st_mtime:
            text = cache.read_text(encoding="utf-8").strip()
            return text or None
    except OSError:
        pass
    return None


def store_brief(transcript: Path, brief: str) -> None:
    cache = handover_cache_path(transcript)
    tmp = cache.with_name(cache.name + ".tmp")
    try:
        tmp.write_text(brief + "\n", encoding="utf-8")
        os.replace(tmp, cache)
    except OSError as e:
        eecho(f"warning: could not cache handover brief at {cache}: {e}")


def distill_brief(extraction: str, s: Session, model: str) -> str | None:
    """One-shot tool-less `claude -p` summarisation (gated child: dontAsk,
    no allowlist — per loop-engineering, never bypassPermissions).

    Returns None on any worker unavailability — absent CLI, non-zero exit,
    timeout, empty output — with a stderr warning. Advisory, never fatal.
    """
    claude_bin = shutil.which("claude")
    if not claude_bin:
        eecho("warning: `claude` CLI not on PATH — emitting non-distilled pointer prompt")
        return None
    branch = str(s.data.get("branch") or "")
    payload = (
        _DISTILL_INSTRUCTION
        + "\n--- SESSION METADATA ---\n"
        + f"Title: {s.title}\nBranch: {branch or '(none)'}\nCwd: {s.cwd}\n"
        + "\n--- CONVERSATION EXTRACTION ---\n"
        + extraction
    )
    import subprocess
    eecho(f"distilling handover brief via `claude -p --model {model}` "
          f"({len(extraction)} chars in, ~{DISTILL_TIMEOUT_S}s timeout)…")
    try:
        r = subprocess.run(
            [claude_bin, "-p", "--model", model, "--permission-mode", "dontAsk"],
            input=payload.encode("utf-8"),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=DISTILL_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        eecho(f"warning: distillation timed out after {DISTILL_TIMEOUT_S}s — "
              "emitting non-distilled pointer prompt")
        return None
    except OSError as e:
        eecho(f"warning: could not run `claude`: {e} — emitting non-distilled pointer prompt")
        return None
    if r.returncode != 0:
        tail = r.stderr.decode("utf-8", "replace").strip()[-200:]
        eecho(f"warning: `claude -p` exited {r.returncode}"
              + (f" ({tail})" if tail else "")
              + " — emitting non-distilled pointer prompt")
        return None
    brief = r.stdout.decode("utf-8", "replace").strip()
    if not brief:
        eecho("warning: distillation produced no output — emitting non-distilled pointer prompt")
        return None
    return brief


def _pointer_clause(s: Session, transcript: Path) -> str:
    branch = str(s.data.get("branch") or "")
    ident = s.sid.removeprefix("local_") or s.cli_id
    branch_part = f", branch {branch}" if branch else ""
    return (f"Full transcript at {transcript} (session {ident}{branch_part}); "
            "consult it only if something specific is missing.")


def emit_recovery_prompt(s: Session, args) -> int:
    """Print a paste-ready recovery prompt for a new session (stdout = the prompt).

    Default flow: extract conversation -> distill via `claude -p` -> cache the
    brief at <transcript>.handover.md -> emit brief + pointer clause. Falls
    back to the plain pointer prompt when distillation is unavailable/disabled.
    """
    transcript, how = resolve_transcript(s)

    sep = Term.g("·", "|")
    eecho(panel_open(f"summon {Term.g('·', '|')} recover", indicator=s.account.short))
    eecho(panel_blank())
    eecho(summary_line(f"{s.title!r}   {s.turns}t {sep} {_ago(s.last_activity_ms)}"))
    if how == "scanned":
        eecho(summary_line("transcript found by scan — wrapper cwd does not derive its location"))
    eecho(panel_blank())
    eecho(panel_close(healths=[("ok", "prompt on stdout")] if transcript
                      else [("alarm", "no transcript")]))

    if not transcript:
        eecho(f"no transcript found for cliSessionId {s.cli_id or '(none)'} — cannot recover")
        return 3

    branch = str(s.data.get("branch") or "")

    # --- Distilled handover path ---
    if not getattr(args, "no_distill", False):
        brief = load_cached_brief(transcript, refresh=getattr(args, "refresh", False))
        if brief:
            eecho(f"reusing cached handover brief: {handover_cache_path(transcript)} "
                  "(--refresh to re-distill)")
        else:
            extraction = extract_conversation(
                transcript, getattr(args, "budget", EXTRACT_BUDGET_DEFAULT))
            if extraction:
                brief = distill_brief(extraction, s,
                                      getattr(args, "model", DISTILL_MODEL_DEFAULT))
                if brief:
                    store_brief(transcript, brief)
            else:
                eecho("warning: transcript has no conversational text — "
                      "emitting non-distilled pointer prompt")
        if brief:
            lines = [f"Continue a previous Claude session: {s.title!r}."]
            if branch:
                lines.append(f"Branch: {branch}")
            lines += ["", brief, "", _pointer_clause(s, transcript)]
            for line in lines:
                _print_safe(line)
            return 0

    # --- Fallback: non-distilled pointer prompt ---
    cwd_note = ""
    if s.cwd and not s.cwd.startswith("/sessions/") and not Path(s.cwd).exists():
        cwd_note = "  (missing on disk — folder moved?)"

    lines = [
        "Continue a previous Claude session.",
        "",
        f"Title:      {s.title}",
    ]
    if branch:
        lines.append(f"Branch:     {branch}")
    lines.append(f"Orig cwd:   {s.cwd}{cwd_note}")
    lines.append(f"Transcript: {transcript}")
    lines += ["", _RECOVERY_INSTRUCTION]
    for line in lines:
        _print_safe(line)
    return 0


def mode_recover(args, accounts: list[Account]) -> int:
    if not args.target:
        eecho("usage: summon recover <id>   (sessionId or cliSessionId, prefix ok)")
        return 2
    matches, ambiguous = find_wrappers_by_id(args.target, accounts)
    if not matches:
        eecho(f"no session matching: {args.target}")
        return 3
    if ambiguous:
        eecho(f"'{args.target}' matches {len({m.sid for m in matches})} different sessions — be more specific:")
        for m in matches[:8]:
            eecho(f"  {m.sid}  {m.title!r}  {m.cwd}")
        return 2
    return emit_recovery_prompt(matches[0], args)


def _is_live(s: Session, now_ms: int) -> bool:
    """Heuristic 'running state': wrapper touched within the last 10 minutes."""
    recent = now_ms - 10 * 60_000
    if s.last_activity_ms >= recent:
        return True
    try:
        return int(s.path.stat().st_mtime * 1000) >= recent
    except OSError:
        return False


def _cwd_broken(s: Session) -> bool:
    """Doctor's broken-binding check: recorded cwd no longer exists on disk."""
    return not (bool(s.cwd) and Path(s.cwd).exists())


def _iso_utc(ms: int) -> str:
    """Epoch-ms -> ISO-8601 Z, '' for the unset 0."""
    if not ms:
        return ""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ms / 1000))


def pick_json(candidates: list[Session], now_ms: int, rich: bool = False) -> int:
    """`pick --json` — the session inventory as a claude-mods.summon.pick
    envelope on stdout (JSON only; panels never touch stdout on this path).

    Feeds the in-chat visual card picker (assets/picker-widget.html) and any
    other scripted caller. An empty inventory is valid data, not an error:
    exit 0.

    With ``rich`` (``--rich``), each row gains transcript-derived display
    metrics — context occupancy (donut), activity density (sparkline), event /
    tool-call counts, on-disk size, duration, and the opening ask — and the
    schema advances to pick/v2. Costs one linear transcript read per session,
    so it's opt-in; the default v1 inventory stays metadata-only and instant.
    """
    rows = []
    for s in candidates:
        transcript = resolve_transcript(s)[0]
        row = {
            "id": s.sid.removeprefix("local_")[:8],
            "sessionId": s.sid,
            "cliSessionId": s.cli_id,
            "title": s.title,
            "cwd": s.cwd,
            "projectRoot": project_root(s.cwd),
            "worktree": worktree_name(s.cwd),
            "branch": str(s.data.get("branch") or ""),
            "model": str(s.data.get("model") or ""),
            "effort": str(s.data.get("effort") or ""),
            "turns": s.turns,
            "isArchived": bool(s.data.get("isArchived")),
            "isRunning": _is_live(s, now_ms),
            "brokenCwd": _cwd_broken(s),
            "lastActivityAt": _iso_utc(s.last_activity_ms),
            "account": s.account.short,
            "accountEmail": s.account.email,
            "transcriptPath": str(transcript) if transcript else None,
        }
        if rich:
            m = analyze_transcript(transcript)
            window = 1_000_000 if m["ctxPeak"] > 200_000 else 200_000
            row.update({
                "events": m["events"],
                "toolCalls": m["toolCalls"],
                "densityBuckets": m["buckets"],
                "durationMin": m["durationMin"],
                "sizeKB": m["sizeKB"],
                "ctxTokens": m["ctxTokens"],
                "ctxPeak": m["ctxPeak"],
                "ctxWindow": window,
                "ctxPct": round(min(100, m["ctxTokens"] / window * 100)) if window else 0,
                "ctxPeakPct": round(min(100, m["ctxPeak"] / window * 100)) if window else 0,
                "firstAsk": m["firstAsk"],
            })
        rows.append(row)
    print(json.dumps({
        "data": rows,
        "meta": {"count": len(rows),
                 "schema": "claude-mods.summon.pick/v2" if rich else
                           "claude-mods.summon.pick/v1"},
    }, indent=2))
    return 0


def mode_pick(args, accounts: list[Account]) -> int:
    """Interactive picker over the whole session store -> recovery prompt."""
    sessions: list[Session] = []
    for acct in accounts:
        sessions.extend(load_sessions(acct))

    days = None if args.all else (args.days if args.days is not None else 30)
    candidates = filter_sessions(sessions, days=days,
                                 cwd_pattern=args.cwd, title_pattern=args.title)

    if args.json:
        return pick_json(candidates, int(time.time() * 1000), rich=args.rich)

    if not candidates:
        eecho(f"no sessions match ({_window_label(days)})")
        return 3

    now_ms = int(time.time() * 1000)

    # fzf path — only when genuinely interactive and not answered via --select
    use_fzf = (not args.select and shutil.which("fzf")
               and sys.stdin.isatty() and sys.stdout.isatty())
    if use_fzf:
        rows = []
        for i, s in enumerate(candidates, 1):
            live = "● " if _is_live(s, now_ms) else "  "
            rows.append(f"{i}\t{live}{s.title}\t{s.cwd}\t{_ago(s.last_activity_ms)}\t{s.turns}t")
        import subprocess
        r = subprocess.run(
            ["fzf", "--delimiter", "\t", "--with-nth", "2,3,4,5",
             "--height", "60%", "--reverse",
             "--prompt", "recover> ",
             "--header", "● = active in last 10m — pick a session to build a recovery prompt"],
            input="\n".join(rows).encode("utf-8"), stdout=subprocess.PIPE)
        if r.returncode != 0 or not r.stdout.strip():
            eecho("cancelled.")
            return 0
        idx = int(r.stdout.decode("utf-8", "replace").split("\t", 1)[0])
        return emit_recovery_prompt(candidates[idx - 1], args)

    # Fallback: numbered list (stderr), selection via --select or stdin
    eecho(panel_open(f"summon {Term.g('·', '|')} pick",
                     indicator=_window_label(days)))
    eecho(panel_blank())
    for i, s in enumerate(candidates, 1):
        live = Term.g("●", "*") + " " if _is_live(s, now_ms) else "  "
        eecho(leaf(i, f"{live}{s.title}", meta=f"{s.turns}t",
                   age=_ago(s.last_activity_ms),
                   last=(i == len(candidates)), depth=1))
    eecho(panel_blank())
    eecho(panel_close(hotkeys=[("#", "select"), ("blank", "cancel")]))

    raw = args.select
    if not raw:
        try:
            # Prompt on stderr — stdout stays clean for the recovery prompt.
            print("recover> (number, blank to cancel): ", end="", file=sys.stderr, flush=True)
            raw = input().strip()
        except EOFError:
            raw = ""
    if not raw:
        eecho("cancelled.")
        return 0
    try:
        idx = int(raw.split(",")[0].strip())
    except ValueError:
        eecho(f"not a session number: {raw!r}")
        return 2
    if not (1 <= idx <= len(candidates)):
        eecho(f"out of range: {idx}")
        return 2
    return emit_recovery_prompt(candidates[idx - 1], args)


def mode_doctor(args, accounts: list[Account]) -> int:
    """Scan every wrapper for broken cwd bindings + transcript resolution."""
    broken: "OrderedDict[str, dict]" = OrderedDict()  # sessionId -> finding
    transcript_missing = 0
    transcript_scanned = 0
    checked = 0
    remote = 0

    for acct in accounts:
        for s in load_sessions(acct):
            if s.is_remote:
                remote += 1
                continue
            checked += 1
            cwd_ok = not _cwd_broken(s)
            transcript, how = resolve_transcript(s)
            if how == "scanned":
                transcript_scanned += 1
            if transcript is None:
                transcript_missing += 1
            if not cwd_ok:
                f = broken.setdefault(s.sid, {
                    "sessionId": s.sid,
                    "cliSessionId": s.cli_id,
                    "title": s.title,
                    "cwd": s.cwd,
                    "accounts": [],
                    "archived": bool(s.data.get("isArchived")),
                    "transcript": str(transcript) if transcript else None,
                    "lastActivityAt": s.last_activity_ms,
                })
                if s.account.short not in f["accounts"]:
                    f["accounts"].append(s.account.short)

    findings = list(broken.values())

    if args.json:
        print(json.dumps({
            "data": findings,
            "meta": {"count": len(findings), "checked": checked,
                     "remoteSkipped": remote,
                     "transcriptMissing": transcript_missing,
                     "transcriptFoundByScan": transcript_scanned,
                     "schema": "claude-mods.summon.doctor/v1"},
        }, indent=2))
        return 10 if findings else 0

    sep = Term.g("·", "|")
    echo(panel_open(f"summon {Term.g('·', '|')} doctor",
                    indicator=f"{checked} sessions"))
    echo(panel_blank())
    echo(summary_line(f"{checked} local {sep} {remote} remote skipped {sep} "
                      f"{transcript_missing} transcript-missing {sep} "
                      f"{transcript_scanned} found-by-scan"))
    echo(panel_blank())

    if not findings:
        echo(section("all cwd bindings resolve", color_token="ok"))
        echo(panel_blank())
        echo(panel_close(healths=[("ok", "healthy")]))
        return 0

    echo(section("broken cwd bindings — recorded folder no longer exists",
                 len(findings), color_token="alarm"))
    findings.sort(key=lambda f: -f["lastActivityAt"])
    for i, f in enumerate(findings):
        is_last = i == len(findings) - 1
        tag = "arch" if f["archived"] else ",".join(f["accounts"])
        echo(leaf(0, f["title"], meta=Term.color("warn", tag),
                  age=_ago(f["lastActivityAt"]), last=is_last, depth=1))
        pipe = Term.g("│", "|")
        echo(f"{pipe}        {Term.color('meta', f['cwd'])}")
        short = f["sessionId"].removeprefix("local_")[:8]
        echo(f"{pipe}        {Term.color('meta', f'summon rebind {short} --cwd <new-location>')}")

    echo(panel_blank())
    echo(panel_close(healths=[("alarm", f"{len(findings)} broken")]))
    return 10


# ============================================================
#  Main
# ============================================================

def main():
    p = argparse.ArgumentParser(
        description="Claude Desktop session toolbox — cross-account transfer, "
                    "recovery picker, cwd rebind, store doctor.",
        epilog="examples:\n"
               "  summon --to mknv74              push sessions to the next account\n"
               "  summon pick                     picker -> distilled handover brief\n"
               "  summon recover 6577b24c         distilled handover brief for one session\n"
               "  summon recover 6577b24c --no-distill   plain pointer prompt, no LLM call\n"
               "  summon recover 6577b24c --refresh      ignore cached brief, re-distill\n"
               "  summon rebind 6577b24c --cwd X:\\Maplab\\LCMap   fix cwd after folder move\n"
               "  summon doctor                   scan for broken cwd bindings\n",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("mode", nargs="?", choices=["rebind", "pick", "recover", "doctor"],
                   help="Toolbox mode; omit for cross-account transfer")
    p.add_argument("target", nargs="?",
                   help="Session id for rebind/recover (sessionId or cliSessionId, prefix ok)")
    p.add_argument("--to", help="Destination account (UUID prefix or email substring)")
    p.add_argument("--from", dest="from_",
                   help="Restrict source to one account (default: all non-destination accounts)")
    # Time-window filter: --days N (custom) or one of the convenience aliases.
    # Transfer defaults to 3 days, pick to 30; --all disables.
    p.add_argument("--days", type=int, default=None,
                   help="Time window in days (default: 3 for transfer, 30 for pick)")
    p.add_argument("--all", action="store_true", help="Disable time filter (any age)")
    p.add_argument("--1d", dest="window_1d", action="store_true", help="Last 24h (alias)")
    p.add_argument("--3d", dest="window_3d", action="store_true", help="Last 3 days (alias)")
    p.add_argument("--7d", dest="window_7d", action="store_true", help="Last 7 days (alias)")
    p.add_argument("--30d", dest="window_30d", action="store_true", help="Last 30 days (alias)")
    p.add_argument("--cwd", default="",
                   help="Transfer/pick: substring match against cwd. "
                        "Rebind: the folder's NEW location (full path)")
    p.add_argument("--title", default="", help="Substring match against title")
    p.add_argument("--pick", action="store_true", help=argparse.SUPPRESS)  # legacy flag — default behavior now
    p.add_argument("--move", action="store_true",
                   help="Move semantics — delete source after copying (lean cleanup)")
    p.add_argument("--dry-run", action="store_true", help="Preview without touching files")
    p.add_argument("--list-accounts", action="store_true", help="List all accounts and exit")
    p.add_argument("--peek", metavar="ID", help="Preview a session's last messages and exit (id prefix or full)")
    p.add_argument("--flat", action="store_true", help="Flat list instead of grouped hierarchy")
    p.add_argument("--select", metavar="PICKS", default="",
                   help="Non-interactive selection: numbers like '1,2,4', or 'a'/'all' for all")
    p.add_argument("--yes", action="store_true",
                   help="Skip the final confirmation prompt only — selection is still "
                        "required (interactively, via piped stdin, or via --select)")
    p.add_argument("--no-transcript", action="store_true",
                   help="Rebind: skip copying the transcript into the new munged project dir")
    p.add_argument("--force", action="store_true",
                   help="Rebind: allow --cwd paths that don't exist on disk yet")
    p.add_argument("--json", action="store_true",
                   help="Doctor: emit findings as a JSON envelope on stdout. "
                        "Pick: emit the session inventory as a JSON envelope "
                        "(no picker; stdout is JSON only)")
    p.add_argument("--rich", action="store_true",
                   help="Pick --json: add transcript-derived display metrics per "
                        "session (context occupancy, activity density, tool/event "
                        "counts, size, duration, opening ask) — schema pick/v2. "
                        "One transcript read per session; powers the card picker")
    p.add_argument("--no-distill", action="store_true",
                   help="Recover/pick: skip the LLM handover distillation and emit "
                        "the plain pointer prompt")
    p.add_argument("--refresh", action="store_true",
                   help="Recover/pick: ignore a cached handover brief and re-distill")
    p.add_argument("--model", default=DISTILL_MODEL_DEFAULT,
                   help=f"Recover/pick: model for the distillation call "
                        f"(default: {DISTILL_MODEL_DEFAULT})")
    p.add_argument("--budget", type=int, default=EXTRACT_BUDGET_DEFAULT,
                   help=f"Recover/pick: char budget for the transcript extraction "
                        f"fed to the distiller (default: {EXTRACT_BUDGET_DEFAULT})")
    args = p.parse_args()

    claude_dir = appdata_claude()
    if not claude_dir.is_dir():
        sys.exit(f"Claude dir not found: {claude_dir}")

    accounts = discover_accounts(claude_dir)
    if not accounts:
        sys.exit(f"No accounts with sessions under {claude_dir}/claude-code-sessions/")

    # --- Toolbox modes ---

    if args.mode == "rebind":
        sys.exit(mode_rebind(args, accounts))
    if args.mode == "recover":
        sys.exit(mode_recover(args, accounts))
    if args.mode == "pick":
        sys.exit(mode_pick(args, accounts))
    if args.mode == "doctor":
        sys.exit(mode_doctor(args, accounts))
    if args.target:
        p.error("unexpected positional argument — transfer mode takes flags only")

    # --- Modes that exit early ---

    if args.list_accounts:
        echo(panel_open(f"summon {Term.g('·', '|')} accounts"))
        echo(panel_blank())
        echo(section("accounts", len(accounts), color_token="accent"))
        for i, a in enumerate(accounts):
            is_last = (i == len(accounts) - 1)
            ago = _ago(int(a.last_activity * 1000))
            echo(leaf(0, a.email or "(unknown)",
                      meta=f"{a.short} {Term.g('·', '|')} {a.session_count}",
                      age=ago, last=is_last, depth=1))
        echo(panel_blank())
        echo(panel_close(healths=[("ok", f"{len(accounts)} active")]))
        return

    if args.peek:
        sys.exit(peek_session(args.peek, accounts))

    # --- Pull mode ---

    # Resolve destination
    if not args.to:
        dest = detect_destination(accounts)
    else:
        dest = resolve_account(args.to, accounts)
    if not dest:
        sys.exit(f"Cannot resolve destination account: {args.to}")

    # Resolve source(s)
    if args.from_:
        src = resolve_account(args.from_, accounts)
        if not src:
            sys.exit(f"Cannot resolve source account: {args.from_}")
        if src.uuid == dest.uuid:
            sys.exit("Source and destination are the same; remove --from or pick another --to")
        source_accounts = [src]
    else:
        source_accounts = [a for a in accounts if a.uuid != dest.uuid]
    if not source_accounts:
        sys.exit("No source accounts available (only one account exists)")

    # Load + filter sessions
    all_sessions: list[Session] = []
    for src in source_accounts:
        all_sessions.extend(load_sessions(src))

    # Resolve recency window: --all > convenience alias > --days
    if args.all:
        days = None
    elif args.window_1d:
        days = 1
    elif args.window_3d:
        days = 3
    elif args.window_7d:
        days = 7
    elif args.window_30d:
        days = 30
    else:
        days = args.days if args.days is not None else 3

    candidates = filter_sessions(all_sessions, days=days,
                                 cwd_pattern=args.cwd, title_pattern=args.title)

    # Header: short destination tag (just the email's local part or UUID short).
    # Source detail goes into the summary line — header stays clean.
    arrow = Term.g("→", "->")
    dest_short = (dest.email.split("@")[0] if dest.email else dest.short)
    indicator = f"{arrow} {dest_short}"
    echo(panel_open("summon", indicator=indicator))

    if not candidates:
        echo(panel_blank())
        echo(summary_line(f"no matching sessions  ({_window_label(days)})"))
        echo(panel_blank())
        echo(panel_close())
        return

    # Summary line at the TOP per TERMINAL-DESIGN.md.
    sep = Term.g("·", "|")
    if len(source_accounts) == 1:
        src_email = source_accounts[0].email or source_accounts[0].short
        src_label = f"from {src_email}"
    else:
        src_label = f"from {len(source_accounts)} accounts"
    summary_text = f"{len(candidates)} sessions {sep} {src_label} {sep} {_window_label(days)}"

    echo(panel_blank())
    echo(summary_line(summary_text))

    # Render hierarchy + capture index_map
    index_map = _render_grouped(candidates) if not args.flat else render_hierarchy(candidates, grouped=False)

    # Pick a hint — conditional ones win when relevant, otherwise rotate background tips
    generic_titles = {"dev", "general", "untitled", "(untitled)", ""}
    generic_count = sum(1 for s in candidates if s.title.lower() in generic_titles)
    remote_count = sum(1 for sess in all_sessions if sess.is_remote)

    hint_ctx = {
        "count": len(candidates),
        "generic_count": generic_count,
        "remote_count": remote_count,
        "window_days": days if days is not None else 0,
        "source_count": len(source_accounts),
    }
    hint_text = _pick_hint(hint_ctx)
    if hint_text:
        echo(hint(hint_text))
        echo(panel_blank())

    echo(panel_close(hotkeys=[("#", "select"), ("a", "all"), ("blank", "cancel")]))

    # Selection — --select answers the picker non-interactively; otherwise
    # prompt for picks (piped stdin honoured too). --yes does NOT bypass
    # selection; it only suppresses the final confirmation below.
    def _parse_picks(raw: str) -> list[Session]:
        if raw.lower() in ("a", "all"):
            return list(candidates)
        picks: list[Session] = []
        for tok in raw.split(","):
            tok = tok.strip()
            if not tok:
                continue
            try:
                i = int(tok)
            except ValueError:
                continue
            if i in index_map:
                picks.append(index_map[i])
        return picks

    if args.select:
        chosen = _parse_picks(args.select)
        if not chosen:
            sys.exit(f"--select {args.select!r} matched none of the listed sessions")
    else:
        print()
        prompt = Term.color("accent", "select> ") + \
                 "(numbers like '3,5,7', 'a' for all, blank to cancel): "
        try:
            raw = input(prompt).strip()
        except EOFError:
            raw = ""
        if not raw:
            echo(Term.color("meta", "cancelled."))
            return
        chosen = _parse_picks(raw)
        if not chosen:
            echo(Term.color("meta", "nothing selected — cancelled."))
            return
    candidates = chosen

    # Final are-you-sure — the only prompt --yes suppresses. Dry-run touches
    # nothing, so it skips the confirmation too.
    if not args.yes and not args.dry_run:
        verb = "move" if args.move else "copy"
        confirm = Term.color("accent", "confirm> ") + \
                  f"{verb} {len(candidates)} session(s) to {dest_short}? (y/N): "
        try:
            resp = input(confirm).strip().lower()
        except EOFError:
            resp = ""
        if resp not in ("y", "yes"):
            echo(Term.color("meta", "cancelled."))
            return

    dest_ws = pick_destination_workspace(dest)

    # Operate + render results in a fresh stacked panel (DESIGN: 2 blank lines)
    print()
    print()
    echo(panel_open(f"summon {Term.g('·', '|')} results", indicator=dest_ws.name[:8]))
    echo(panel_blank())

    success_states = {"copied", "moved", "would copy", "would move"}
    skip_re = re.compile(r"^skip")
    moved = 0
    skipped = 0
    moved_files: list[Path] = []
    for i, s in enumerate(candidates):
        is_last = i == len(candidates) - 1
        status = summon_session(s, dest_ws, move=args.move, dry_run=args.dry_run)
        if status in success_states:
            moved += 1
            color = "ok"
            target = dest_ws / s.path.name
            if not args.dry_run and target.exists():
                moved_files.append(target)
        elif skip_re.match(status):
            skipped += 1
            color = "warn"
        else:
            color = "alarm"
        echo(leaf(0, s.title, meta=Term.color(color, status),
                  age=s.account.short, last=is_last, depth=1))

    echo(panel_blank())

    # Nudge fs.watch — sentinel + rename ping-pong on each moved file
    if moved and not args.dry_run:
        nudge_watcher(dest_ws, moved_files=moved_files)

    healths = []
    if moved:
        if args.dry_run:
            verb = "would " + ("move" if args.move else "copy")
        else:
            verb = "moved" if args.move else "copied"
        healths.append(("ok", f"{moved} {verb}"))
    if skipped:
        healths.append(("warn", f"{skipped} skipped"))

    echo(panel_close(healths=healths))

    if moved and not args.dry_run:
        echo()
        echo(Term.color("warn",
             "next: switch accounts in Desktop. Logout from current, login to destination."))
        echo(Term.color("meta",
             "  the new sessions appear when destination's sidebar populates on login."))
        echo(Term.color("meta",
             "  (Desktop caches session list at login; tab toggles and Ctrl+R won't rescan.)"))


if __name__ == "__main__":
    main()
