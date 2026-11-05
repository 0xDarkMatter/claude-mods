#!/usr/bin/env python3
"""Loopback stand-in for Linear, for this skill's offline suite only. Not a dev server: tests/run.sh
starts it, reads the port from stdout, and kills it before exiting.

POST bodies pick a behaviour from a `# scenario: NAME` comment in the GraphQL document. GET paths
pick one for the facts verifier. The `whoami` scenario echoes the Authorization header back so a
test can assert exactly what the client sent.
"""
from __future__ import annotations

import json
import re
from http.server import BaseHTTPRequestHandler, HTTPServer


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
        else:
            self.reply(200, json.dumps({"data": {"ok": True}}))


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
