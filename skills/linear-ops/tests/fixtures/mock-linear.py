#!/usr/bin/env python3
"""Loopback stand-in for Linear, for this skill's offline suite only. Not a dev server: tests/run.sh
starts it, reads the port from stdout, and kills it before exiting.

POST bodies pick a behaviour from a `# scenario: NAME` comment in the GraphQL document. GET paths
pick one for the facts verifier. The `whoami` scenario echoes the Authorization header back so a
test can assert exactly what the client sent.

watch-comments.py sends no scenario comment, so it is recognised by shape: `viewer` answers as the
agent, and the NewComments query answers from COMMENTS only for $me == AGENT_ID. That proves the
script's plumbing (viewer id -> $me, $since filtering, state), NOT Linear's own filter semantics.
A `since` in the 1999/2001/2002 band forces a full page, a server error and a rejected token.
"""
from __future__ import annotations

import json
import re
from http.server import BaseHTTPRequestHandler, HTTPServer


AGENT_ID = "agent-id-0001"
URL = "https://linear.app/team/issue/"
NL, ESC = chr(10), chr(27)  # built with chr(): the body must hold a real newline and a real ESC
COMMENTS = [  # oldest first here; the mock sends them newest first, as the script must not rely on order
    {"createdAt": "2026-11-05T10:00:01.000Z", "body": "first line" + NL + "second line", "user": {"name": "Alice"},
     "issue": {"identifier": "ENG-1", "title": "Card one", "url": URL + "ENG-1"}},
    {"createdAt": "2026-11-05T10:00:02.000Z", "body": "esc " + ESC + "[31mred" + ESC + "[0m " + "a" * 300,
     "user": None, "issue": None},
    {"createdAt": "2026-11-05T10:00:03.000Z", "body": "please FILTERED me", "user": {"name": "Bob"},
     "issue": {"identifier": "ENG-2", "title": "Card two", "url": URL + "ENG-2"}},
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, status: int, body: str, headers: dict | None = None) -> None:
        data = body.encode("utf-8")
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if "/gone" in self.path:
            self.reply(404, "gone")
        elif "/down" in self.path:
            self.reply(503, "down")
        elif "/auth" in self.path:
            self.reply(401, "auth")
        elif self.path.endswith("/latest"):
            self.reply(200, json.dumps({"version": "9.9.9"}))
        else:
            self.reply(200, "alpha beta")

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        doc = payload.get("query", "")
        match = re.search(r"# scenario: (\S+)", doc)
        scenario = match.group(1) if match else "default"
        auth = self.headers.get("Authorization")

        if doc.lstrip().startswith("query T("):
            name = payload["variables"]["n"]
            if name == "Nope":
                self.reply(200, json.dumps({"data": {"__type": None}}))
            else:
                self.reply(200, json.dumps({"data": {"__type": {"name": name, "kind": "INPUT_OBJECT",
                                                                 "inputFields": [{"name": "issueId"}]}}}))
        elif scenario == "validate":
            # A credential reaching this path is exactly what --validate must never do.
            if auth is not None:
                self.reply(200, json.dumps({"data": {"leak": True}}))
            elif "nope" in doc:
                self.reply(400, json.dumps({"errors": [{"message": "Cannot query field",
                                                        "extensions": {"code": "GRAPHQL_VALIDATION_FAILED"}}]}))
            else:
                self.reply(401, json.dumps({"errors": [{"message": "auth required",
                                                        "extensions": {"code": "AUTHENTICATION_ERROR"}}]}))
        elif scenario == "whoami":
            self.reply(200, json.dumps({"data": {"auth": auth}}), {"X-Complexity": "2"})
        elif scenario == "partial":
            self.reply(200, json.dumps({"data": {"a": 1}, "errors": [{"message": "half failed"}]}))
        elif scenario == "limited429":
            self.reply(429, json.dumps({"errors": [{"message": "slow", "extensions": {"code": "RATELIMITED"}}]}),
                       {"Retry-After": "42"})
        elif scenario == "limited400":
            self.reply(400, json.dumps({"errors": [{"message": "slow", "extensions": {"code": "RATELIMITED"}}]}),
                       {"Retry-After": "7"})
        elif scenario == "badtoken":
            self.reply(401, json.dumps({"errors": [{"message": "no"}]}))
        elif scenario == "pages":
            after = (payload.get("variables") or {}).get("after")
            page = {None: ("c1", True, ["a"]), "c1": ("c2", True, ["b"]), "c2": ("c3", False, ["c"])}[after]
            self.reply(200, json.dumps({"data": {"issues": {
                "nodes": page[2], "pageInfo": {"endCursor": page[0], "hasNextPage": page[1]}}}}))
        elif "comments(" in doc:
            since = (payload.get("variables") or {}).get("since", "")
            if auth is None:
                self.reply(401, json.dumps({"errors": [{"message": "no"}]}))
            elif since.startswith("2002"):
                self.reply(401, json.dumps({"errors": [{"message": "revoked"}]}))
            elif since.startswith("2001"):
                self.reply(500, "boom")
            elif (payload.get("variables") or {}).get("me") != AGENT_ID:
                self.reply(200, json.dumps({"data": {"comments": {"nodes": []}}}))
            elif since.startswith("1999"):
                nodes = [{"createdAt": f"2000-01-01T00:00:{i:02d}.000Z", "body": f"n{i}", "user": {"name": "Zed"},
                          "issue": None} for i in range(50)]
                self.reply(200, json.dumps({"data": {"comments": {"nodes": nodes}}}))
            else:
                nodes = [c for c in COMMENTS if c["createdAt"] > since]
                self.reply(200, json.dumps({"data": {"comments": {"nodes": list(reversed(nodes))}}}))
        elif "viewer" in doc:
            self.reply(200, json.dumps({"data": {"viewer": {"id": AGENT_ID, "name": "Agent"}}}))
        else:
            self.reply(200, json.dumps({"data": {"ok": True}}))


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
