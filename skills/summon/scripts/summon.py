#!/usr/bin/env python3
"""summon — pull Claude Desktop Code-tab sessions from another account into the active one.

See SKILL.md for full documentation.

Defaults:
  - move (not copy)
  - last 14 days only
  - skip remote-VM sessions (cwd starts with /sessions/)
  - prompt for confirmation
  - hierarchy display: Account -> Project -> Session

Auto-detects destination as the most-recently-active account.
Source defaults to "all other accounts" — narrow with --from.

Output rendering follows docs/DESIGN.md (Terminal Panel Design System).
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
from pathlib import Path
from typing import Iterable


# ============================================================
#  DESIGN: terminal panel rendering (per docs/DESIGN.md)
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


# Brand emoji for summon (not in DESIGN.md registry yet — registering here)
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


def echo(*lines):
    if not lines:
        print()
        return
    for line in lines:
        print(line)


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
#  Main
# ============================================================

def main():
    p = argparse.ArgumentParser(
        description="Summon Claude Desktop sessions from another account.",
    )
    p.add_argument("--to", help="Destination account (UUID prefix or email substring)")
    p.add_argument("--from", dest="from_",
                   help="Restrict source to one account (default: all non-destination accounts)")
    # Time-window filter: --days N (custom) or one of the convenience aliases.
    # Defaults to 14 days; --all disables.
    p.add_argument("--days", type=int, default=3, help="Time window in days (default 3)")
    p.add_argument("--all", action="store_true", help="Disable time filter (any age)")
    p.add_argument("--1d", dest="window_1d", action="store_true", help="Last 24h (alias)")
    p.add_argument("--3d", dest="window_3d", action="store_true", help="Last 3 days (alias)")
    p.add_argument("--7d", dest="window_7d", action="store_true", help="Last 7 days (alias)")
    p.add_argument("--30d", dest="window_30d", action="store_true", help="Last 30 days (alias)")
    p.add_argument("--cwd", default="", help="Substring match against cwd")
    p.add_argument("--title", default="", help="Substring match against title")
    p.add_argument("--pick", action="store_true", help=argparse.SUPPRESS)  # legacy flag — default behavior now
    p.add_argument("--move", action="store_true",
                   help="Move semantics — delete source after copying (lean cleanup)")
    p.add_argument("--dry-run", action="store_true", help="Preview without touching files")
    p.add_argument("--list-accounts", action="store_true", help="List all accounts and exit")
    p.add_argument("--peek", metavar="ID", help="Preview a session's last messages and exit (id prefix or full)")
    p.add_argument("--flat", action="store_true", help="Flat list instead of grouped hierarchy")
    p.add_argument("--yes", action="store_true",
                   help="Non-interactive: select ALL candidates and proceed without prompting")
    args = p.parse_args()

    claude_dir = appdata_claude()
    if not claude_dir.is_dir():
        sys.exit(f"Claude dir not found: {claude_dir}")

    accounts = discover_accounts(claude_dir)
    if not accounts:
        sys.exit(f"No accounts with sessions under {claude_dir}/claude-code-sessions/")

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
        days = args.days

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

    # Summary line at the TOP per DESIGN.md.
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

    # Selection (default) — prompt for picks unless --yes (auto-all).
    if args.yes:
        chosen = list(candidates)
    else:
        print()
        prompt = Term.color("accent", "select> ") + \
                 "(numbers like '3,5,7', 'a' for all, blank to cancel): "
        raw = input(prompt).strip()
        if not raw:
            print(Term.color("meta", "cancelled."))
            return
        chosen: list[Session] = []
        if raw.lower() == "a":
            chosen = list(candidates)
        else:
            for tok in raw.split(","):
                tok = tok.strip()
                if not tok:
                    continue
                try:
                    i = int(tok)
                    if i in index_map:
                        chosen.append(index_map[i])
                except ValueError:
                    continue
        if not chosen:
            print(Term.color("meta", "nothing selected — cancelled."))
            return
    candidates = chosen

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
