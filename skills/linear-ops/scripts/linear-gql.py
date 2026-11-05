#!/usr/bin/env python3
"""Call Linear's GraphQL API with its traps handled. Stdlib only.

Handled: a personal key takes `Authorization: <key>` with no Bearer, OAuth takes Bearer; HTTP 200
with `errors` is a failure; a rate limit reports Retry-After; mutations are refused unless allowed;
the token can only go to a linear.app host (or loopback, for tests). Tokens come from the environment,
never argv, so they stay out of process listings and transcripts.

Never retries a mutation: Linear documents no idempotency key, so a retried create can duplicate.

No-token modes, sent with no credentials at all:
  --validate          checks an operation's shape against the live schema. Linear answers
                      AUTHENTICATION_ERROR once the shape is valid, GRAPHQL_VALIDATION_FAILED if not.
                      Data from a non-introspection operation means a credential got in: exit 1.
  --schema-type NAME  prints a type's fields through introspection.

Usage:   linear-gql.py (--query S | --query-file F | --schema-type NAME)
                       [--vars JSON | --vars-file F] [--paginate PATH] [--max-pages N]
                       [--allow-mutation] [--dry-run] [--validate] [--endpoint URL] [--timeout S]
Input:   LINEAR_API_KEY or LINEAR_OAUTH_TOKEN in the environment (exactly one), except no-token modes.
Output:  stdout = JSON only: {"data":...,"meta":{...}} or {"error":{"code","message","details"}}.
Stderr:  rate-limit budget, notices, errors.
Exit:    0 ok, 1 other HTTP failure, 2 usage (includes refused mutation or host), 3 file or type not
         found, 4 bad variables or bad JSON reply, 5 token missing or rejected, 6 timeout,
         7 rate limited or unreachable, 10 GraphQL errors returned (or an invalid shape)

Examples:
  linear-gql.py --query '{ viewer { id name } }'
  linear-gql.py --query-file team-issues.graphql --vars '{"teamKey":"ENG"}' --paginate issues
  linear-gql.py --allow-mutation --query-file issue-batch-update.graphql --vars-file vars.json
  linear-gql.py --validate --query-file create-issue.graphql
  linear-gql.py --schema-type IssueCreateInput
"""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

EX_OK = 0
EX_ERROR = 1
EX_USAGE = 2
EX_NOTFOUND = 3
EX_VALIDATION = 4
EX_PRECONDITION = 5
EX_TIMEOUT = 6
EX_UNAVAILABLE = 7
EX_GRAPHQL = 10

DEFAULT_ENDPOINT = "https://api.linear.app/graphql"
SCHEMA = "claude-mods.linear-ops.gql/v1"
BUDGET_HEADERS = ("X-Complexity", "X-RateLimit-Requests-Remaining", "X-RateLimit-Complexity-Remaining")


def fail(code: str, message: str, exit_code: int, details: dict | None = None) -> int:
    print(json.dumps({"error": {"code": code, "message": message, "details": details or {}}}, indent=2))
    print(f"linear-gql: {code}: {message}", file=sys.stderr)
    return exit_code


def operation_kinds(document: str) -> list[str]:
    """Return the kinds of top-level operations, ignoring comments, strings and fragments.

    A regex over the raw text would be fooled by the word `mutation` in a comment or an
    argument, and an anonymous `{ ... }` is a query. So walk depth 0 only.
    """
    text = re.sub(r'"""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"', '""', document)
    text = re.sub(r"#[^\n]*", "", text)
    kinds: list[str] = []
    depth = 0
    i = 0
    while i < len(text):
        ch = text[i]
        if ch in "{(":
            if depth == 0 and ch == "{":
                kinds.append("query")
            depth += 1
            i += 1
        elif ch in "})":
            depth -= 1
            i += 1
        elif depth == 0 and ch.isalpha():
            m = re.match(r"[A-Za-z_]\w*", text[i:])
            word = m.group()
            i += len(word)
            if word in ("query", "mutation", "subscription"):
                kinds.append(word)
                # Skip to the selection set, so its `{` is not counted as an anonymous query.
                depth_paren = 0
                while i < len(text):
                    c = text[i]
                    if c == "(":
                        depth_paren += 1
                    elif c == ")":
                        depth_paren -= 1
                    elif c == "{" and depth_paren == 0:
                        break
                    i += 1
                depth += 1
                i += 1
            elif word == "fragment":
                while i < len(text) and text[i] != "{":
                    i += 1
                depth += 1
                i += 1
        else:
            i += 1
    return kinds


def endpoint_allowed(url: str) -> bool:
    parts = urllib.parse.urlsplit(url)
    host = (parts.hostname or "").lower()
    if host in ("127.0.0.1", "localhost", "::1"):
        return parts.scheme in ("http", "https")
    return parts.scheme == "https" and (host == "linear.app" or host.endswith(".linear.app"))


def auth_header() -> tuple[str | None, str]:
    key = os.environ.get("LINEAR_API_KEY", "")
    oauth = os.environ.get("LINEAR_OAUTH_TOKEN", "")
    if key and oauth:
        return None, "both"
    if key:
        return key, "api-key (no Bearer)"
    if oauth:
        return f"Bearer {oauth}", "oauth (Bearer)"
    return None, "none"


def report_budget(headers) -> None:
    parts = [f"{h}={headers.get(h)}" for h in BUDGET_HEADERS if headers.get(h) is not None]
    if parts:
        print("linear-gql: " + " ".join(parts), file=sys.stderr)


def post(endpoint: str, auth: str, document: str, variables: dict, timeout: float):
    """Return (exit_or_None, reply_json). Exit is set when the call already failed and was reported."""
    body = json.dumps({"query": document, "variables": variables}).encode("utf-8")
    req = urllib.request.Request(endpoint, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": auth,
        "User-Agent": "claude-mods-linear-ops/1",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            report_budget(resp.headers)
            raw = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        report_budget(exc.headers)
        raw = exc.read().decode("utf-8", errors="replace")
        # Linear documents 429; a 400 with this code has also been reported, so read the code too.
        if exc.code == 429 or error_code(raw) == "RATELIMITED":
            retry = exc.headers.get("Retry-After")
            return fail("RATELIMITED", f"rate limited; Retry-After={retry}", EX_UNAVAILABLE,
                        {"retryAfter": retry, "status": exc.code}), None
        if exc.code in (401, 403):
            return fail("AUTH", f"token rejected (HTTP {exc.code})", EX_PRECONDITION, {"status": exc.code}), None
        if exc.code >= 500:
            return fail("UNAVAILABLE", f"server error (HTTP {exc.code})", EX_UNAVAILABLE, {"status": exc.code}), None
        # Linear sends validation failures as 400 with a normal GraphQL errors body.
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            return fail("HTTP", f"HTTP {exc.code}", EX_ERROR, {"status": exc.code}), None
        if not parsed.get("errors"):
            return fail("HTTP", f"HTTP {exc.code}", EX_ERROR, {"status": exc.code}), None
        return None, parsed
    except (TimeoutError, socket.timeout):
        return fail("TIMEOUT", f"no reply within {timeout}s", EX_TIMEOUT), None
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, (TimeoutError, socket.timeout)):
            return fail("TIMEOUT", f"no reply within {timeout}s", EX_TIMEOUT), None
        return fail("UNAVAILABLE", f"unreachable: {exc.reason}", EX_UNAVAILABLE), None
    except OSError as exc:
        return fail("UNAVAILABLE", f"unreachable: {exc}", EX_UNAVAILABLE), None
    try:
        return None, json.loads(raw)
    except json.JSONDecodeError:
        return fail("BAD_JSON", "reply was not JSON", EX_VALIDATION), None


def error_code(raw: str) -> str:
    try:
        return str(json.loads(raw)["errors"][0]["extensions"]["code"])
    except (json.JSONDecodeError, KeyError, IndexError, TypeError):
        return ""


def post_anonymous(endpoint: str, document: str, variables: dict, timeout: float):
    """POST with no Authorization header. Return (exit_or_None, http_status, parsed_reply)."""
    body = json.dumps({"query": document, "variables": variables}).encode("utf-8")
    req = urllib.request.Request(endpoint, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "User-Agent": "claude-mods-linear-ops/1",
    })
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status, raw = resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read().decode("utf-8", errors="replace")
    except (TimeoutError, socket.timeout):
        return fail("TIMEOUT", f"no reply within {timeout}s", EX_TIMEOUT), 0, None
    except (urllib.error.URLError, OSError) as exc:
        return fail("UNAVAILABLE", f"unreachable: {exc}", EX_UNAVAILABLE), 0, None
    try:
        return None, status, json.loads(raw)
    except json.JSONDecodeError:
        if status == 429 or status >= 500:
            return fail("UNAVAILABLE", f"HTTP {status}", EX_UNAVAILABLE), status, None
        return fail("BAD_JSON", f"reply was not JSON (HTTP {status})", EX_VALIDATION), status, None


def validate(endpoint: str, document: str, variables: dict, timeout: float) -> int:
    code, status, reply = post_anonymous(endpoint, document, variables, timeout)
    if code is not None:
        return code
    errors = reply.get("errors") or []
    codes = [str((e.get("extensions") or {}).get("code", "")) for e in errors]
    if "RATELIMITED" in codes or status == 429:
        return fail("RATELIMITED", "unauthenticated budget exhausted", EX_UNAVAILABLE, {"status": status})
    if "GRAPHQL_VALIDATION_FAILED" in codes:
        return fail("INVALID_SHAPE", str(errors[0].get("message", "invalid")), EX_GRAPHQL, {"errors": errors})
    if reply.get("data") and "__schema" not in document and "__type" not in document:
        return fail("CREDENTIAL_LEAK", "got data with no credentials sent; this check proves nothing here", EX_ERROR)
    if "AUTHENTICATION_ERROR" in codes:
        print(json.dumps({"data": {"valid": True}, "meta": {"schema": SCHEMA}}, indent=2))
        return EX_OK
    return fail("UNEXPECTED", f"neither valid nor invalid (HTTP {status})", EX_ERROR, {"errors": errors})


def schema_type(endpoint: str, name: str, timeout: float) -> int:
    if not re.fullmatch(r"[A-Za-z_]\w*", name):
        return fail("REFUSED", f"not a GraphQL type name: {name}", EX_USAGE)
    ref = "type { name kind ofType { name kind ofType { name kind ofType { name } } } }"
    document = ("query T($n: String!) { __type(name: $n) { name kind "
                f"fields {{ name {ref} }} inputFields {{ name {ref} }} enumValues {{ name }} }} }}")
    code, status, reply = post_anonymous(endpoint, document, {"n": name}, timeout)
    if code is not None:
        return code
    if reply.get("errors"):
        return fail("GRAPHQL", str(reply["errors"][0].get("message", "error")), EX_GRAPHQL, {"errors": reply["errors"]})
    found = (reply.get("data") or {}).get("__type")
    if not found:
        return fail("NOT_FOUND", f"no type named {name}", EX_NOTFOUND)
    print(json.dumps({"data": found, "meta": {"schema": SCHEMA}}, indent=2))
    return EX_OK


def dig(data, path: str):
    for part in path.split("."):
        if not isinstance(data, dict) or part not in data:
            return None
        data = data[part]
    return data


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        prog="linear-gql.py",
        description="Call Linear's GraphQL API with its traps handled.",
        epilog=(
            "Examples:\n"
            "  linear-gql.py --query '{ viewer { id name } }'\n"
            "  linear-gql.py --query-file team-issues.graphql --vars '{\"teamKey\":\"ENG\"}' --paginate issues\n"
            "  linear-gql.py --allow-mutation --query-file issue-batch-update.graphql --vars-file vars.json\n"
            "  linear-gql.py --validate --query-file create-issue.graphql\n"
            "  linear-gql.py --schema-type IssueCreateInput\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--query", help="GraphQL document")
    src.add_argument("--query-file", help="file holding the document")
    src.add_argument("--schema-type", metavar="NAME", help="print a type's fields; no token needed")
    p.add_argument("--validate", action="store_true", help="check the shape against the live schema; no token sent")
    var = p.add_mutually_exclusive_group()
    var.add_argument("--vars", help="variables as a JSON object")
    var.add_argument("--vars-file", help="file holding variables as a JSON object")
    p.add_argument("--paginate", metavar="PATH", help="dotted path to a connection, e.g. issues or team.issues")
    p.add_argument("--max-pages", type=int, default=20, help="page limit with --paginate (default 20)")
    p.add_argument("--allow-mutation", action="store_true", help="permit a mutation (writes real data)")
    p.add_argument("--dry-run", action="store_true", help="print the request shape; no token, no network")
    p.add_argument("--endpoint", default=DEFAULT_ENDPOINT, help="https on linear.app, or loopback for tests")
    p.add_argument("--timeout", type=float, default=30.0, help="per-request timeout seconds")
    try:
        args = p.parse_args(argv)
    except SystemExit as exc:
        return EX_USAGE if exc.code not in (0, None) else EX_OK

    if not endpoint_allowed(args.endpoint):
        return fail("REFUSED", f"endpoint not allowed, the token stays on linear.app: {args.endpoint}", EX_USAGE)
    if args.schema_type:
        return schema_type(args.endpoint, args.schema_type, args.timeout)

    if args.query_file:
        path = Path(args.query_file)
        if not path.is_file():
            return fail("NOT_FOUND", f"query file not found: {args.query_file}", EX_NOTFOUND)
        document = path.read_text(encoding="utf-8")
    else:
        document = args.query

    variables: dict = {}
    if args.vars or args.vars_file:
        if args.vars_file and not Path(args.vars_file).is_file():
            return fail("NOT_FOUND", f"vars file not found: {args.vars_file}", EX_NOTFOUND)
        raw_vars = args.vars if args.vars else Path(args.vars_file).read_text(encoding="utf-8")
        try:
            variables = json.loads(raw_vars)
        except json.JSONDecodeError as exc:
            return fail("BAD_VARS", f"variables are not JSON: {exc}", EX_VALIDATION)
        if not isinstance(variables, dict):
            return fail("BAD_VARS", "variables must be a JSON object", EX_VALIDATION)

    kinds = operation_kinds(document)
    if not kinds:
        return fail("REFUSED", "no operation found in the document", EX_USAGE)
    if "subscription" in kinds:
        return fail("REFUSED", "subscriptions are not supported", EX_USAGE)
    if args.validate:
        # Mutation guard does not apply: nothing executes without credentials.
        return validate(args.endpoint, document, variables, args.timeout)
    is_write = "mutation" in kinds
    if is_write and not args.allow_mutation:
        return fail("REFUSED", "document contains a mutation; pass --allow-mutation after the user's OK", EX_USAGE)

    if args.paginate:
        if is_write:
            return fail("REFUSED", "--paginate is for queries only", EX_USAGE)
        if "$after" not in document or "pageInfo" not in document or "endCursor" not in document:
            return fail("REFUSED", "--paginate needs a $after variable and pageInfo { hasNextPage endCursor }", EX_USAGE)
        if args.max_pages < 1:
            return fail("REFUSED", "--max-pages must be at least 1", EX_USAGE)

    auth, scheme = auth_header()
    if args.dry_run:
        print(json.dumps({"data": {"endpoint": args.endpoint, "auth": scheme, "operations": kinds,
                                   "variables": variables, "paginate": args.paginate},
                          "meta": {"dry_run": True, "schema": SCHEMA}}, indent=2))
        return EX_OK
    if scheme == "both":
        return fail("AUTH", "both LINEAR_API_KEY and LINEAR_OAUTH_TOKEN are set; unset one", EX_USAGE)
    if auth is None:
        return fail("AUTH", "set LINEAR_API_KEY or LINEAR_OAUTH_TOKEN", EX_PRECONDITION)

    if not args.paginate:
        code, reply = post(args.endpoint, auth, document, variables, args.timeout)
        if code is not None:
            return code
        if reply.get("errors"):
            # A 200 may carry partial data beside errors. Keep it, because the caller needs to see what happened.
            return fail("GRAPHQL", str(reply["errors"][0].get("message", "GraphQL error")), EX_GRAPHQL,
                        {"errors": reply["errors"], "data": reply.get("data")})
        print(json.dumps({"data": reply.get("data"), "meta": {"schema": SCHEMA}}, indent=2))
        return EX_OK

    nodes: list = []
    pages = 0
    truncated = False
    cursor = variables.get("after")
    while True:
        code, reply = post(args.endpoint, auth, document, {**variables, "after": cursor}, args.timeout)
        if code is not None:
            return code
        if reply.get("errors"):
            return fail("GRAPHQL", str(reply["errors"][0].get("message", "GraphQL error")), EX_GRAPHQL,
                        {"errors": reply["errors"], "pages_completed": pages, "nodes": nodes})
        conn = dig(reply.get("data"), args.paginate)
        if not isinstance(conn, dict) or "nodes" not in conn or "pageInfo" not in conn:
            return fail("REFUSED", f"{args.paginate} is not a connection with nodes and pageInfo in the reply", EX_USAGE)
        nodes.extend(conn["nodes"])
        pages += 1
        info = conn["pageInfo"]
        if not info.get("hasNextPage"):
            break
        if pages >= args.max_pages:
            truncated = True
            print(f"linear-gql: stopped at --max-pages {args.max_pages}; more remain", file=sys.stderr)
            break
        cursor = info.get("endCursor")
    print(json.dumps({"data": nodes, "meta": {"count": len(nodes), "pages": pages, "truncated": truncated,
                                              "schema": SCHEMA}}, indent=2))
    return EX_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
