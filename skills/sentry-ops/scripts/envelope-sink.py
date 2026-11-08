#!/usr/bin/env python3
"""Prove a Sentry setup without sending anything to Sentry: record what an SDK
would send to a fake DSN, then read the bytes for leaks.

Point the app at a DSN whose host is this listener, for example
http://publickey@127.0.0.1:8191/1, and trigger real errors in the real build.
The SDK derives POST /api/1/envelope/ from that DSN, so no app code changes.

Why it binds loopback only and always exits by itself: it is a throwaway check
that receives whatever the app sends, which may be personal data while you are
finding that out. It must never be reachable from the network, and it must not
outlive the task as an orphan holding a port. Default port is in the reserved
throwaway range 8190-8199 (see rules/dev-servers.md).

Usage:   envelope-sink.py listen --out DIR [--port N] [--count N] [--timeout S] [--expect-none]
         envelope-sink.py inspect PATH [--forbid TEXT]... [--forbid-file F] [--strict] [--json]
Input:   argv only. `inspect` reads a file or a directory of *.envelope files.
Output:  stdout = data only: listen prints one saved path per request; inspect
         prints a table, or a --json envelope.
Stderr:  progress, the verdict line, errors.
Exit:    0 ok, 2 usage, 3 path missing or nothing recorded to inspect,
         4 envelope unparseable, 7 port busy,
         10 finding: a forbidden string or (with --strict) a personal-data field
            was present, or --expect-none received a request

Examples:
  envelope-sink.py listen --out ./envelopes --count 1 --timeout 60
  envelope-sink.py listen --out ./none --timeout 20 --expect-none
  envelope-sink.py inspect ./envelopes --forbid person@example.com --strict
  envelope-sink.py inspect ./envelopes --json | jq '.data[].event_id'
"""
from __future__ import annotations

import argparse
import gzip
import json
import socket
import sys
import time
import zlib
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NOTFOUND = 3
EX_UNPARSEABLE = 4
EX_UNAVAILABLE = 7
EX_FINDING = 10

SCHEMA = "claude-mods.sentry-ops.envelope/v1"
LOOPBACK = "127.0.0.1"  # never configurable: see the module docstring
MAX_BODY = 64 * 1024 * 1024

# Event fields that carry request or user data. Finding one is not always a bug,
# which is why these only fail under --strict: a project can choose to send them.
REQUEST_FIELDS = ("cookies", "headers", "data", "query_string", "env")


def decode_body(raw: bytes, encoding: str = "") -> bytes:
    """Undo Content-Encoding, trusting the magic bytes over the header."""
    if raw[:2] == b"\x1f\x8b" or encoding == "gzip":
        return gzip.decompress(raw)
    if encoding == "deflate":
        return zlib.decompress(raw)
    return raw


def parse_envelope(data: bytes) -> dict:
    """Parse Sentry's envelope format: a JSON header line, then items, each a JSON
    header line and a payload. An item header with `length` gives the payload's
    byte count, because payloads such as Replay recordings are binary and may
    contain newlines. Spec: develop.sentry.dev/sdk/data-model/envelopes/"""
    newline = data.find(b"\n")
    if newline < 0:
        header_line, pos = data, len(data)
    else:
        header_line, pos = data[:newline], newline + 1
    header = json.loads(header_line)
    if not isinstance(header, dict):
        raise ValueError("envelope header is not an object")
    items = []
    while pos < len(data):
        end = data.find(b"\n", pos)
        if end < 0:
            end = len(data)
        line = data[pos:end]
        pos = end + 1
        if not line.strip():
            continue
        item_header = json.loads(line)
        length = item_header.get("length")
        if length is not None:
            payload = data[pos:pos + int(length)]
            pos += int(length) + 1
        else:
            end = data.find(b"\n", pos)
            if end < 0:
                end = len(data)
            payload = data[pos:end]
            pos = end + 1
        items.append((item_header, payload))
    return {"header": header, "items": items}


def event_exposure(event: dict) -> list[str]:
    """Name each personal-data-bearing field this event actually carries."""
    found = []
    request = event.get("request") or {}
    for field in REQUEST_FIELDS:
        if request.get(field):
            found.append(f"request.{field}")
    url = str(request.get("url") or "")
    if "?" in url:
        found.append("request.url?query")
    if event.get("user"):
        found.append("user")
    if event.get("breadcrumbs"):
        found.append("breadcrumbs")
    for exc in (event.get("exception") or {}).get("values") or []:
        frames = (exc.get("stacktrace") or {}).get("frames") or []
        if any(frame.get("vars") for frame in frames):
            found.append("frame.vars")
            break
    return found


def summarise(path: Path, forbid: list[str]) -> dict:
    raw = path.read_bytes()
    data = decode_body(raw)
    envelope = parse_envelope(data)
    item_types, exposure, event_id = [], [], envelope["header"].get("event_id", "")
    for item_header, payload in envelope["items"]:
        kind = str(item_header.get("type", "?"))
        item_types.append(kind)
        if kind in ("event", "transaction"):
            exposure.extend(event_exposure(json.loads(payload)))
    lowered = data.lower()
    leaks = [text for text in forbid if text.lower().encode() in lowered]
    return {"file": str(path), "event_id": event_id, "items": item_types,
            "bytes": len(data), "exposed_fields": sorted(set(exposure)), "leaks": leaks}


def make_handler(out: Path, state: dict):
    class Handler(BaseHTTPRequestHandler):
        def _reply(self, code: int, body: bytes = b"{}") -> None:
            self.send_response(code)
            # The browser SDK posts cross-origin to the DSN host.
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "*")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self) -> None:  # noqa: N802 - http.server's dispatch name
            self._reply(204, b"")

        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                self._reply(413)
                return
            raw = self.rfile.read(length)
            state["count"] += 1
            path = out / f"{state['count']:03d}.envelope"
            try:
                body = decode_body(raw, self.headers.get("Content-Encoding", ""))
            except (OSError, EOFError, zlib.error):
                body = raw
            path.write_bytes(body)
            print(path, flush=True)
            self._reply(200)

        def log_message(self, *_args) -> None:
            return  # stderr stays reserved for progress and the verdict

    return Handler


def cmd_listen(args: argparse.Namespace) -> int:
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    state = {"count": 0}
    try:
        server = HTTPServer((LOOPBACK, args.port), make_handler(out, state))
    except OSError as exc:
        print(f"error: cannot bind {LOOPBACK}:{args.port}: {exc}", file=sys.stderr)
        return EX_UNAVAILABLE
    server.timeout = 0.25
    print(f"listening: use DSN http://publickey@{LOOPBACK}:{args.port}/1 "
          f"(stops after {args.timeout:g}s or {args.count or 'unlimited'} requests)",
          file=sys.stderr, flush=True)
    deadline = time.monotonic() + args.timeout
    try:
        while time.monotonic() < deadline:
            server.handle_request()
            if args.count and state["count"] >= args.count:
                break
            # One request already settles --expect-none, so don't wait out the timeout.
            if args.expect_none and state["count"]:
                break
    finally:
        server.server_close()
    print(f"envelope-sink: received {state['count']} request(s)", file=sys.stderr)
    if args.expect_none and state["count"]:
        return EX_FINDING
    return EX_OK


def cmd_inspect(args: argparse.Namespace) -> int:
    target = Path(args.path)
    if not target.exists():
        print(f"error: not found: {target}", file=sys.stderr)
        return EX_NOTFOUND
    files = sorted(target.glob("*.envelope")) if target.is_dir() else [target]
    if not files:
        print(f"error: no *.envelope files in {target}", file=sys.stderr)
        return EX_NOTFOUND
    forbid = list(args.forbid or [])
    if args.forbid_file:
        ff = Path(args.forbid_file)
        if not ff.is_file():
            print(f"error: forbid file not found: {ff}", file=sys.stderr)
            return EX_NOTFOUND
        forbid += [ln.strip() for ln in ff.read_text(encoding="utf-8").splitlines() if ln.strip()]
    rows = []
    for path in files:
        try:
            rows.append(summarise(path, forbid))
        except (ValueError, OSError, EOFError, zlib.error) as exc:
            print(f"error: could not parse {path}: {exc}", file=sys.stderr)
            return EX_UNPARSEABLE
    if args.json:
        print(json.dumps({"data": rows, "meta": {"count": len(rows), "schema": SCHEMA}}, indent=2))
    else:
        for row in rows:
            print("\t".join([row["file"], row["event_id"] or "-", ",".join(row["items"]) or "-",
                             ",".join(row["exposed_fields"]) or "-", ",".join(row["leaks"]) or "-"]))
    leaks = sum(len(r["leaks"]) for r in rows)
    exposed = sum(len(r["exposed_fields"]) for r in rows)
    failed = leaks or (args.strict and exposed)
    print(f"envelope-sink: {'FINDING' if failed else 'OK'} ({len(rows)} envelopes, "
          f"{leaks} forbidden strings, {exposed} personal-data fields)", file=sys.stderr)
    return EX_FINDING if failed else EX_OK


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="envelope-sink.py",
        description="Record what a Sentry SDK would send, on loopback, and read it for leaks.",
        epilog=("Examples:\n"
                "  envelope-sink.py listen --out ./envelopes --count 1 --timeout 60\n"
                "  envelope-sink.py listen --out ./none --timeout 20 --expect-none\n"
                "  envelope-sink.py inspect ./envelopes --forbid person@example.com --strict\n"),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command")
    listen = sub.add_parser("listen", help="record POST bodies from a fake DSN")
    listen.add_argument("--out", required=True, help="directory for NNN.envelope files")
    listen.add_argument("--port", type=int, default=8191, help="loopback port (default 8191)")
    listen.add_argument("--count", type=int, default=0, help="stop after N requests")
    listen.add_argument("--timeout", type=float, default=60.0, help="stop after S seconds (default 60)")
    listen.add_argument("--expect-none", action="store_true", help="exit 10 if any request arrives")
    inspect = sub.add_parser("inspect", help="parse recorded envelopes, look for leaks")
    inspect.add_argument("path", help="an .envelope file, or a directory of them")
    inspect.add_argument("--forbid", action="append", help="string that must not appear (repeatable)")
    inspect.add_argument("--forbid-file", help="file of such strings, one per line")
    inspect.add_argument("--strict", action="store_true", help="also fail on personal-data fields")
    inspect.add_argument("--json", action="store_true", help="emit a JSON envelope")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK
    if args.command == "listen":
        return cmd_listen(args)
    if args.command == "inspect":
        return cmd_inspect(args)
    parser.print_usage(sys.stderr)
    return EX_USAGE


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except socket.error as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(EX_UNAVAILABLE)
