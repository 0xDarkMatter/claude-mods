#!/usr/bin/env bash
# Behavioural tests for scripts/check-pm-facts.py: the C1 data tables (--offline) and the
# live parsers (--live), with no network.
#
# Offline cases mutate the real facts file and run the verifier CLI; each malformed C1 field
# must be reported (exit 10) or rejected (exit 4), never pass. Live cases import the verifier,
# replace its fetch() with a table of saved responses under tests/fixtures/facts/ (every file
# there ends in .fx so no scanner reads it as a real manifest) and call the live_* functions.
# Each test is named for the bug it prevents. Run by hand or from tests/run.sh.
#
# Usage:   bash tests/facts.sh
#          FACTS_V=/path/to/older/check-pm-facts.py bash tests/facts.sh   # prove the tests fail on unfixed code
# Input:   none
# Output:  PASS/FAIL rows on stderr; final tally line.
# Exit:    0 all pass, 1 any failure
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${SKILL_DIR:-$(dirname "$HERE")}"
V="${FACTS_V:-$SKILL/scripts/check-pm-facts.py}"
FACTS="$SKILL/assets/package-manager-facts.json"
FX="$HERE/fixtures/facts"

PASS=0; FAIL=0
echo "=== check-pm-facts behaviour ($V) ===" >&2
PY="$(bash "$SKILL/scripts/run-python.sh" --which 2>/dev/null)" || { echo "  FAIL  no Python 3.8+" >&2; exit 1; }

while IFS='|' read -r verdict msg; do
  if [[ "$verdict" == PASS ]]; then PASS=$((PASS+1)); printf '  PASS  %s\n' "$msg" >&2
  else FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$msg" >&2; fi
done < <("$PY" - "$V" "$SKILL" "$FACTS" "$FX" <<'PY'
import copy, importlib.util, json, os, subprocess, sys, tempfile, traceback, urllib.error
from pathlib import Path

verifier, skill, facts_path, fx = (Path(a) for a in sys.argv[1:5])
facts = json.loads(facts_path.read_text(encoding="utf-8"))
tmp = Path(tempfile.mkdtemp())


def row(ok, msg):
    print(f"{'PASS' if ok else 'FAIL'}|{msg}")


def _crash(kind, exc, tb):
    # WHY: an uncaught error mid-harness would silently drop every later row and the run
    # would still tally green. A crash is a failure row, and the final row below is the
    # proof the harness reached its end.
    print(f"FAIL|harness crashed: {''.join(traceback.format_exception_only(kind, exc)).strip()}")


sys.excepthook = _crash


def load():
    spec = importlib.util.spec_from_file_location("v", str(verifier))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def fixture(name):
    return json.loads((fx / name).read_text(encoding="utf-8"))


def cli(name, edit):
    d = copy.deepcopy(facts)
    edit(d)
    f = tmp / f"{name}.json"
    f.write_text(json.dumps(d), encoding="utf-8")
    p = subprocess.run([sys.executable, str(verifier), "--offline", "--skill", str(skill), "--facts", str(f)],
                       capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def expect(name, edit, code, why, needle=None):
    rc, out = cli(name, edit)
    row(rc == code and b"Traceback" not in out.encode() and (needle is None or needle in out),
        f"{why} (exit {rc}, want {code})")


# ---- offline: the real catalogue is clean, so every failure below is the mutation's -------
rc, out = cli("real", lambda d: None)
row(rc == 0, f"the shipped facts file passes --offline (exit {rc}) {out.strip()[:200] if rc else ''}")

lp = lambda d: d["legacy_packages"]
expect("legacy-no-reason", lambda d: lp(d)[2].pop("reason"), 10, "legacy entry without a reason is reported, not shipped as an unexplained finding", "reason")
expect("legacy-empty-replacement", lambda d: lp(d)[2].__setitem__("replacement", " "), 10, "legacy entry with a blank replacement is reported", "replacement")
expect("legacy-ecosystem", lambda d: lp(d)[2].__setitem__("ecosystem", "pip"), 10, "legacy ecosystem outside npm/composer is reported", "ecosystem")
expect("legacy-id-prefix", lambda d: lp(d)[2].__setitem__("id", "deprecated.package"), 10, "legacy id outside the legacy.* namespace is reported", "legacy.")
expect("legacy-range", lambda d: lp(d)[3].__setitem__("versions", "older than three"), 10, "legacy versions that is not an npm range is reported", "versions")
expect("legacy-see-anchor", lambda d: lp(d)[0].__setitem__("see", "references/legacy-exits.md#no-such-heading"), 10, "legacy see pointing at a missing heading anchor is reported", "anchor")
expect("legacy-see-file", lambda d: lp(d)[0].__setitem__("see", "references/nope.md#bower-to-npm"), 10, "legacy see pointing at a missing reference file is reported", "does not exist")
expect("legacy-dupe", lambda d: lp(d).append(copy.deepcopy(lp(d)[2])), 10, "a duplicated legacy entry is reported", "duplicate")
expect("legacy-not-object", lambda d: lp(d).append("bower"), 10, "a legacy entry that is a bare string is reported, not a TypeError", "not an object")
expect("legacy-not-list", lambda d: d.__setitem__("legacy_packages", {}), 4, "legacy_packages that is an object is exit 4 (unparseable catalogue)")
expect("legacy-missing", lambda d: d.pop("legacy_packages"), 10, "a catalogue without legacy_packages is reported (pm-audit would raise nothing)", "legacy_packages")

cl = lambda d: d["composer"]["lines"]
expect("lines-end-not-iso", lambda d: cl(d)["2.9"].__setitem__("end", "May 2026"), 10, "composer line end that is not ISO is reported", "ISO")
expect("lines-lts-not-bool", lambda d: cl(d)["2.2"].__setitem__("lts", "yes"), 10, "composer line lts that is not a bool is reported", "lts")
expect("lines-order", lambda d: cl(d)["2.9"].__setitem__("end", "2025-01-01"), 10, "composer line ending before the previous one is reported", "not after")
expect("lines-open-end-mid", lambda d: cl(d)["2.5"].__setitem__("end", None), 10, "a null end on a line that is not the newest is reported", "newer line exists")
expect("lines-key", lambda d: cl(d).__setitem__("3.0", {"end": None, "lts": False}), 10, "a composer line key outside 2.<minor> is reported", "2.<minor>")
expect("lines-missing", lambda d: d["composer"].pop("lines"), 10, "a catalogue without composer.lines is reported", "composer.lines")
expect("lines-not-object", lambda d: d["composer"].__setitem__("lines", []), 4, "composer.lines that is a list is exit 4")
expect("floor-unknown-line", lambda d: d["composer"]["feature_floors"].__setitem__("security_blocking", "2.99"), 10, "a feature floor naming a line that is not listed is reported", "not a line")
expect("floor-order", lambda d: d["composer"]["feature_floors"].__setitem__("malware_blocking", "2.8"), 10, "malware blocking floor older than security blocking is reported", "predates")
expect("floor-missing", lambda d: d["composer"].pop("feature_floors"), 10, "a catalogue without composer.feature_floors is reported", "feature_floors")

expect("craft-end-not-iso", lambda d: d["craft"]["majors"]["4"].__setitem__("security_end", "April 2026"), 10, "craft security_end that is not ISO is reported", "ISO")
expect("craft-order", lambda d: d["craft"]["majors"]["4"].__setitem__("security_end", "2023-01-01"), 10, "craft 4 ending before craft 3 is reported", "not after")
expect("craft-major-missing", lambda d: d["craft"]["majors"].pop("4"), 10, "a catalogue missing Craft 4 is reported", "craft.majors 4")
expect("craft-missing", lambda d: d.pop("craft"), 10, "a catalogue without craft is reported", "craft.majors")
expect("craft-not-object", lambda d: d.__setitem__("craft", []), 4, "craft that is a list is exit 4")

expect("eol-days-string", lambda d: d.__setitem__("eol_soon_days", "90"), 10, "eol_soon_days as a string is reported", "eol_soon_days")
expect("eol-days-bool", lambda d: d.__setitem__("eol_soon_days", True), 10, "eol_soon_days as a bool is reported (True is an int in Python)", "eol_soon_days")
expect("eol-days-zero", lambda d: d.__setitem__("eol_soon_days", 0), 10, "eol_soon_days of 0 is reported", "eol_soon_days")
expect("eol-days-missing", lambda d: d.pop("eol_soon_days"), 10, "a catalogue without eol_soon_days is reported", "eol_soon_days")

# ---- live: parsers against saved responses ---------------------------------------------
v = load()
BRANCHES = fixture("php-branches.json.fx")
SCHEDULE = fixture("node-schedule.json.fx")
EOL_PHP, EOL_NODE = fixture("endoflife-php.json.fx"), fixture("endoflife-nodejs.json.fx")
COMPOSER = fixture("composer-versions.json.fx")


def serve(table, calls=None):
    """Replace fetch(): url -> ('ok', json) | ('notfound', 404) | ('unavailable', 503). A URL
    absent from the table fails the test loudly rather than reaching the network."""
    def fetch(url, timeout, accept="application/json"):
        if calls is not None:
            calls.append(url)
        if url not in table:
            raise AssertionError(f"unexpected fetch {url}")
        got = table[url]
        if isinstance(got, tuple):
            return got
        return "ok", json.dumps(got)
    v.fetch = fetch


def php_check(branches, extra=None, calls=None):
    t = {v.PHP_BRANCHES: branches}
    t.update(extra or {})
    serve(t, calls)
    return v.live_php(facts, 1.0)


d, u = php_check(BRANCHES)
row(not d and not u, f"live: the saved php.net branches.php feed matches the facts table (drift={d} unreach={u})")

moved = copy.deepcopy(BRANCHES)
for r in moved:
    if r["branch"] == "8.4":
        r["security_support_end"] = "2029-12-31T00:00:00+00:00"
d, u = php_check(moved)
row(any("php 8.4" in x["subject"] and "security_end" in x["issue"] for x in d) and not u,
    "live: a php.net security_end that moved is drift naming the branch")

d, u = php_check(("notfound", 404))
row(len(d) == 1 and "gone" in d[0]["issue"] and not u,
    "live: php.net answering 404 is DRIFT, not unreachable (a 404 once read as 'unreachable' and hid the move)")

calls = []
d, u = php_check(("unavailable", 503), {v.PHP_SUPPORTED: ("unavailable", 503), v.PHP_EOL: ("unavailable", 503)}, calls)
row(v.PHP_SUPPORTED in calls and len(u) == 1 and not d,
    "live: branches.php unavailable falls back to the HTML pages, and both failing is unreachable")

calls = []
php_check(("notfound", 404), {}, calls)
row(calls == [v.PHP_BRANCHES], "live: a gone branches.php does NOT fall back to scraping HTML (the fallback would mask the break)")

for label, shape in (("an object", {"branches": []}), ("a list of strings", ["8.4", "8.3"]), ("an empty list", [])):
    try:
        d, u = php_check(shape)
        row(len(d) == 1 and any(k in d[0]["issue"] for k in ("format changed", "no longer answers a list")) and not u,
            f"live: branches.php reshaped to {label} is drift, not a traceback")
    except Exception as exc:  # noqa: BLE001 - the point is that nothing escapes
        row(False, f"live: branches.php reshaped to {label} raised {exc!r}")

# Node: an upstream key this verifier has never seen must not crash or drift the check.
sched = copy.deepcopy(SCHEDULE)
sched["v26"]["alpha"] = "2026-03-03"
sched["v26"]["unknown-future-key"] = {"nested": True}
serve({v.NODE_SCHEDULE: sched})
try:
    d, u = v.live_node(facts, 1.0, v.dt.date(2026, 10, 7))
    row(not d and not u, f"live: Node schedule.json gaining `alpha` and unknown keys is tolerated (drift={d})")
except Exception as exc:  # noqa: BLE001
    row(False, f"live: unknown keys in schedule.json raised {exc!r}")

serve({v.NODE_SCHEDULE: ("notfound", 404)})
d, u = v.live_node(facts, 1.0, v.dt.date(2026, 10, 7))
row(len(d) == 1 and not u, "live: Node schedule.json 404 is drift, not unreachable")

# endoflife.date cross-check
today = v.dt.date(2026, 10, 7)
EOL = f"{v.EOL_DATE}/php/", f"{v.EOL_DATE}/nodejs/"
serve({EOL[0]: EOL_PHP, EOL[1]: EOL_NODE})
d, u = v.live_endoflife(facts, 1.0, today)
row(not d and not u, f"live: the saved endoflife.date answers match the facts (drift={d} unreach={u})")

off = copy.deepcopy(EOL_PHP)
for r in off["result"]["releases"]:
    if r["name"] == "8.3":
        r["eolFrom"] = "2027-11-30"
serve({EOL[0]: off, EOL[1]: EOL_NODE})
d, u = v.live_endoflife(facts, 1.0, today)
row(any("php 8.3" in x["subject"] and "endoflife.date" in x["issue"] for x in d),
    "live: endoflife.date disagreeing on a PHP end-of-life date is drift")

off = copy.deepcopy(EOL_NODE)
for r in off["result"]["releases"]:
    if r["name"] == "22":
        r["eolFrom"] = "2027-06-30"
serve({EOL[0]: EOL_PHP, EOL[1]: off})
d, u = v.live_endoflife(facts, 1.0, today)
row(any("nodejs 22" in x["subject"] for x in d), "live: endoflife.date disagreeing on a Node end-of-life date is drift")

old = copy.deepcopy(EOL_NODE)
for r in old["result"]["releases"]:
    if r["name"] == "11":
        r["eolFrom"] = "2019-06-30"  # the real disagreement: schedule.json says 2019-06-01
serve({EOL[0]: EOL_PHP, EOL[1]: old})
d, u = v.live_endoflife(facts, 1.0, today)
row(not d, "live: a years-dead line the two sources round differently is not a permanent red (Node 11)")

serve({EOL[0]: ("notfound", 404), EOL[1]: EOL_NODE})
d, u = v.live_endoflife(facts, 1.0, today)
row(len(d) == 1 and "gone" in d[0]["issue"] and not u, "live: endoflife.date 404 is drift, not unreachable")

serve({EOL[0]: {"result": {"releases": "oops"}}, EOL[1]: EOL_NODE})
d, u = v.live_endoflife(facts, 1.0, today)
row(len(d) == 1 and "format changed" in d[0]["issue"], "live: endoflife.date reshaped is drift, not a traceback")

# Composer lines
serve({v.COMPOSER_VERSIONS: COMPOSER})
d, u = v.live_composer_lines(facts, 1.0)
row(not d and not u, f"live: the saved getcomposer.org/versions matches composer.lines (drift={d} unreach={u})")

moved = copy.deepcopy(COMPOSER)
moved["2.2"][0]["maintenance-until"] = "2027-06-30"
serve({v.COMPOSER_VERSIONS: moved})
d, u = v.live_composer_lines(facts, 1.0)
row(any("composer 2.2" in x["subject"] for x in d), "live: the Composer LTS end date moving is drift")

newer = copy.deepcopy(COMPOSER)
newer["stable"][0]["version"] = "2.11.0"
serve({v.COMPOSER_VERSIONS: newer})
d, u = v.live_composer_lines(facts, 1.0)
row(any("2.11" in x["subject"] and "missing" in x["issue"] for x in d),
    "live: a new Composer minor shipping without a composer.lines entry is drift")

serve({v.COMPOSER_VERSIONS: ("notfound", 404)})
d, u = v.live_composer_lines(facts, 1.0)
row(len(d) == 1 and not u, "live: getcomposer.org/versions 404 is drift, not unreachable")

# ---- fetch(): 304 and 404 handling, with urlopen faked ---------------------------------
real_urlopen = v.urllib.request.urlopen


class Resp:
    def __init__(self, body, last_modified):
        self._b, self.headers = body, {"Last-Modified": last_modified}

    def read(self):
        return self._b

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


seen = {}


def fake(req, timeout=None):
    seen["ims"] = req.get_header("If-modified-since")
    if seen.get("mode") == "304":
        raise urllib.error.HTTPError(req.full_url, 304, "Not Modified", {}, None)
    if seen.get("mode") == "410":
        raise urllib.error.HTTPError(req.full_url, 410, "Gone", {}, None)
    return Resp(b'{"a": 1}', "Wed, 07 Oct 2026 00:00:00 GMT")


try:
    importlib_v = load()  # a fresh module: the serve() stubs above replaced fetch on `v`
    importlib_v.urllib.request.urlopen = fake
    importlib_v.CACHE_DIR = tmp / "cache"
    seen["mode"] = "200"
    s1 = importlib_v.fetch("https://example.invalid/x", 1.0)
    seen["mode"] = "304"
    s2 = importlib_v.fetch("https://example.invalid/x", 1.0)
    row(s1 == ("ok", '{"a": 1}') and s2 == ("ok", '{"a": 1}') and seen["ims"] == "Wed, 07 Oct 2026 00:00:00 GMT",
        "fetch: a 304 answers from the cached body and the request carried If-Modified-Since")
    importlib_v.CACHE_DIR = None
    seen["mode"] = "304"
    row(importlib_v.fetch("https://example.invalid/x", 1.0) == ("unavailable", 304),
        "fetch: a 304 with no cache is not mistaken for a good answer")
    seen["mode"] = "410"
    row(importlib_v.fetch("https://example.invalid/x", 1.0)[0] == "notfound", "fetch: 410 is notfound (drift), like 404")
finally:
    v.urllib.request.urlopen = real_urlopen

# ---- CLI: --help documents the contract --------------------------------------------------
p = subprocess.run([sys.executable, str(verifier), "--help"], capture_output=True, text=True)
row(p.returncode == 0 and "--cache-dir" in p.stdout and "Exit:" in p.stdout, "--help lists --cache-dir and the exit codes")
row(True, "harness ran to its end")
PY
)

[[ "$FAIL" -gt 0 || "$PASS" -gt 0 ]] || { echo "  FAIL  harness produced no rows" >&2; exit 1; }
echo "=== $PASS passed, $FAIL failed ===" >&2
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
