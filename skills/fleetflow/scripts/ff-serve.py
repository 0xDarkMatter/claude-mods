#!/usr/bin/env python3
"""ff-serve.py - serve the machine-wide fleetflow dashboard.

One process does both jobs: it serves assets/ff-dashboard.html and it builds the
aggregate. There is deliberately no second moving part - the predecessor of this
service was a static file server plus a detached `ff-status --watch` writing
status.json beside it, and its dominant failure was the watcher dying while the
server stayed up, so the page rendered a perfectly healthy-looking grid of
frozen numbers. Nothing on screen said anything was wrong.

Rebuilds are REQUEST-DRIVEN and NON-BLOCKING:
  * a request is answered from the last good aggregate, immediately, always;
  * if that aggregate is older than --ttl, the request also kicks off a
    background rebuild - so nothing runs when nobody is looking, and a rebuild
    that dies is simply restarted by the next request (a standing watcher, by
    contrast, stays dead until a human notices);
  * one rebuild at a time, with a watchdog so a wedged build cannot block
    refreshes forever.
A cold build over 50+ runs takes minutes; every response carries `age_s`, and
the page shows its own staleness rather than implying freshness it does not have.

Exit codes: 0 clean shutdown | 2 usage | 3 no roots resolved
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ASSETS = SCRIPT_DIR.parent / "assets"


def _load_aggregator():
    """Import ff-aggregate.py by path.

    The skill's scripts are named `ff-<verb>` for consistency with its shell
    tools, and a hyphen is not a legal Python identifier - so the aggregator
    cannot be a plain `import`. Loading it by path keeps ONE implementation of
    discovery and roll-up shared between the CLI and this server; duplicating it
    here is exactly how the two would drift apart.
    """
    path = SCRIPT_DIR / "ff-aggregate.py"
    spec = importlib.util.spec_from_file_location("ff_aggregate", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["ff_aggregate"] = mod
    spec.loader.exec_module(mod)
    return mod


agg = _load_aggregator()
FF_VERSION = "1.2.0"


def err(msg: str) -> None:
    print(f"ff-serve: {msg}", file=sys.stderr, flush=True)


class State:
    """Everything the request thread and the builder thread share."""

    def __init__(self, roots, source, opts):
        self.roots = roots
        self.source = source
        self.opts = opts
        self.lock = threading.Lock()
        self.doc: dict | None = None
        self.built_at = 0.0
        self.building_since = 0.0
        self.builds = 0
        self.last_error: str | None = None
        self.cache: dict = {}
        self._load_cache()

    # The on-disk cache is what makes a service restart cheap: a finished run
    # already read once is never read again, so only genuinely live runs cost
    # anything after the first ever build on this machine.
    def _cache_path(self) -> Path:
        return agg.FF_HOME / "cache" / "aggregate-cache.json"

    def _load_cache(self) -> None:
        p = self._cache_path()
        if p.is_file():
            try:
                self.cache = json.loads(p.read_text(encoding="utf-8"))
                err(f"loaded run cache ({len(self.cache)} entries) from {p}")
            except (OSError, json.JSONDecodeError):
                self.cache = {}

    def _save_cache(self) -> None:
        try:
            p = self._cache_path()
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp = p.with_suffix(".tmp")
            tmp.write_text(json.dumps(self.cache), encoding="utf-8")
            os.replace(tmp, p)
        except OSError as e:
            err(f"cache not persisted: {e}")

    def maybe_build(self) -> None:
        """Start a rebuild if one is due and none is running. Never blocks."""
        with self.lock:
            now = time.time()
            running = self.building_since > 0
            if running and now - self.building_since < self.opts.build_timeout:
                return
            if running:
                # A build that has outlived the watchdog is presumed wedged (a
                # hung git call in some repo, a drive that went away mid-scan).
                # Let a fresh one start rather than freezing the dashboard on
                # whatever the last good document happened to be.
                err(f"build watchdog: previous build exceeded "
                    f"{self.opts.build_timeout}s - starting another")
            if not running and self.doc and now - self.built_at < self.opts.ttl:
                return
            self.building_since = now
        threading.Thread(target=self._build, daemon=True).start()

    def _build(self) -> None:
        t0 = time.time()
        try:
            doc, cache = agg.aggregate(
                self.roots, self.source,
                max_depth=self.opts.max_depth, cache=self.cache,
                live_ttl=self.opts.live_ttl, discover_ttl=self.opts.discover_ttl,
                timeout=self.opts.timeout, workers=self.opts.workers)
            with self.lock:
                self.doc = doc
                self.cache = cache
                self.built_at = time.time()
                self.builds += 1
                self.last_error = None
            self._save_cache()
            t = doc.get("totals", {})
            err(f"build #{self.builds}: {t.get('runs')} runs / {t.get('live_runs')} live "
                f"/ {doc.get('runs_refreshed')} refreshed in {int((time.time()-t0)*1000)}ms")
        except Exception as e:  # a builder crash must never take the server down
            with self.lock:
                self.last_error = f"{type(e).__name__}: {e}"
            err(f"build FAILED: {self.last_error}")
        finally:
            with self.lock:
                self.building_since = 0.0

    def snapshot(self) -> tuple[dict | None, dict]:
        with self.lock:
            meta = {
                "served_at": int(time.time()),
                "age_s": int(time.time() - self.built_at) if self.built_at else None,
                "building": self.building_since > 0,
                "builds": self.builds,
                "ttl_s": self.opts.ttl,
                "server_version": FF_VERSION,
                "build_error": self.last_error,
            }
            return self.doc, meta


class Handler(BaseHTTPRequestHandler):
    state: State = None  # type: ignore[assignment]
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 - signature is the base class's
        pass  # quiet by design: the page polls every 3s and would flood the log

    def handle(self) -> None:
        """Swallow client-side disconnects for the WHOLE exchange, not just the
        write. The process manager's readiness probe opens a keep-alive socket
        and resets it once it has what it wants, which raises inside the base
        class's own `readline` - outside any handler code. Left alone it prints
        a full traceback per probe: this service's log was pure connection-reset
        noise every 10 seconds, which is how a real error goes unnoticed."""
        try:
            super().handle()
        except OSError:
            pass

    def _send(self, code: int, body: bytes, ctype: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            # Every way a client can leave mid-write lands here, and none of them
            # are this server's problem: a closed tab (BrokenPipe/ConnectionReset)
            # or the process manager's readiness probe hanging up the moment it
            # has its status line (ConnectionAborted / WinError 10053, which is
            # what Windows raises and what filled this service's log on day one).
            # Catching the specific subclasses missed that third case.
            pass

    def _json(self, code: int, obj: dict) -> None:
        self._send(code, json.dumps(obj).encode("utf-8"), "application/json; charset=utf-8")

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0].rstrip("/") or "/"

        if path in ("/", "/index.html"):
            f = ASSETS / "ff-dashboard.html"
            try:
                self._send(200, f.read_bytes(), "text/html; charset=utf-8")
            except OSError as e:
                self._send(500, f"cannot read {f}: {e}".encode(), "text/plain; charset=utf-8")
            return

        if path == "/api/aggregate.json":
            self.state.maybe_build()
            doc, meta = self.state.snapshot()
            if doc is None:
                # 200, not an error status: "building" is a normal state the page
                # renders as a message. A 5xx here would be indistinguishable to
                # the page from the server being gone, which is the one thing it
                # must be able to tell apart.
                self._json(200, {"schema": "fleetflow/aggregate/1", "runs": [], "history": [],
                                 "errors": [], "totals": {}, "roots": [str(r) for r in self.state.roots],
                                 "generated_at": int(time.time()),
                                 "error": "building the first aggregate — a cold scan of every "
                                          "root can take a few minutes; this page will fill in",
                                 **meta})
                return
            self._json(200, {**doc, **meta})
            return

        if path == "/api/refresh":
            with self.state.lock:
                self.state.built_at = 0.0  # force the next maybe_build
            self.state.maybe_build()
            self._json(200, {"ok": True, "forced": True})
            return

        if path in ("/api/health", "/health"):
            doc, meta = self.state.snapshot()
            self._json(200, {"ok": True, "has_aggregate": doc is not None,
                             "runs": (doc or {}).get("totals", {}).get("runs"), **meta})
            return

        self._send(404, b"not found", "text/plain; charset=utf-8")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        prog="ff-serve.py", add_help=False,
        description="Serve the machine-wide fleetflow dashboard and build its aggregate.",
        epilog="""ROUTES
  /                     the dashboard (assets/ff-dashboard.html)
  /api/aggregate.json   last good aggregate + freshness meta; triggers a
                        background rebuild when older than --ttl
  /api/refresh          force a rebuild on the next poll
  /api/health           liveness + whether an aggregate exists yet

EXAMPLES
  ff-serve.py --port 8161
  ff-serve.py --port 8161 --root X:/Forma --root X:/Roam
  curl -s localhost:8161/api/health | jq .
""",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8161)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--root", action="append", default=[], metavar="PATH")
    ap.add_argument("--ttl", type=int, default=10, metavar="SECONDS",
                    help="max aggregate age before a request triggers a rebuild")
    ap.add_argument("--live-ttl", type=int, default=15, metavar="SECONDS")
    ap.add_argument("--discover-ttl", type=int, default=120, metavar="SECONDS")
    ap.add_argument("--max-depth", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=60, metavar="SECONDS")
    ap.add_argument("--build-timeout", type=int, default=600, metavar="SECONDS")
    ap.add_argument("--workers", type=int, default=12)
    ap.add_argument("-h", "--help", action="help")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code not in (0, None) else 0

    roots, source = agg.resolve_roots(a.root)
    if not roots:
        err("no roots resolved - pass --root, set $FLEETFLOW_ROOTS, "
            "or run: ff-aggregate.py --init-roots <PATH>...")
        return 3

    state = State(roots, source, a)
    Handler.state = state
    err(f"fleetflow {FF_VERSION} - roots from {source}: "
        f"{', '.join(str(r) for r in roots)}")

    # Warm up straight away so the first visitor is not the one paying for a
    # cold scan. Backgrounded: the socket must be listening immediately or the
    # process manager's readiness probe fails while we scan the disk.
    state.maybe_build()

    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    srv.daemon_threads = True
    err(f"listening on http://{a.bind}:{a.port}/")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        err("shutting down")
    finally:
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
