#!/usr/bin/env python3
"""Decide where and how a suite runs: offload targets, safe local workers, runner commands.

Usage:   run-plan.py targets [--repo DIR] [--probe] [--json]  where could this run, other than here?
         run-plan.py local   [--per-worker-mb M] [--json]   how many workers fit right now?
         run-plan.py stack   [--repo DIR] [--json]   which runner, and its parallel / changed /
                                                     shard / JUnit commands
Input:   argv only. `targets` reads ~/.ssh/config and asks local CLIs (docker, tailscale, gh,
         wsl) what they know; only --probe makes network calls (gh API, `ssh -o BatchMode=yes
         <host> getconf _NPROCESSORS_ONLN`), and it never runs anything else remotely.
Output:  TSV, or --json (schema claude-mods.test-engineering.run-plan/v1).
Stderr:  notes, the recommendation line, errors.
Test seam: TE_RUNPLAN_FAKE="cpus=8,busy=0,mem=64000" replaces the live numbers for `local`.
Exit:    0 ok; 2 usage; 3 --repo not found;
         10 targets: no offload target found (run locally, capped by `local`)
         10 local:   the machine is already busy (>80% CPU or <1 worker fits): offload.

Policy this encodes (references/speed.md "Where tests run"):
- Offload is the default. Few suites NEED the developer's machine; agents running full suites
  locally, in parallel sessions, is how a workstation ends up at 100% CPU.
- Locally, always parallel, but never all of it: a reserve of cores (a quarter, at least one)
  and 2 GiB of memory stays free, current CPU load is subtracted, and memory per worker caps
  the count. The default 1024 MB per worker is a guess; measure one worker's peak RSS and pass it.

Examples:
  run-plan.py targets                 # free, local knowledge only
  run-plan.py targets --probe --json  # also asks GitHub and each SSH host for its core count
  run-plan.py local --per-worker-mb 600
  run-plan.py stack --repo . --json | jq '.data[].commands'
"""
import argparse
import ctypes
import json
import os
import re
import shutil
import subprocess
import sys
import time

SCHEMA = "claude-mods.test-engineering.run-plan/v1"


def note(msg):
    print(f"run-plan: {msg}", file=sys.stderr)


def run(cmd, timeout=6):
    """List-form only; never a shell. Returns stdout, or None on any failure."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        return r.stdout if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


# === targets ==================================================================

def repo_slug(repo):
    """owner/name from the origin remote, so gh asks about the right repo."""
    url = run(["git", "-C", repo, "remote", "get-url", "origin"]) or ""
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?\s*$", url)
    return m.group(1) if m else None

def ssh_hosts():
    path = os.path.expanduser("~/.ssh/config")
    hosts = []
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = re.match(r"\s*Host\s+(.+)", line, re.I)
                if m:
                    hosts += [h for h in m.group(1).split() if not any(c in h for c in "*?!")]
    except OSError:
        pass
    return hosts


def targets(probe, repo="."):
    found = []
    for h in ssh_hosts():
        t = {"kind": "ssh", "name": h, "cost": "own hardware: no metered cost",
             "how": f"git archive HEAD | ssh {h} 'D=$(mktemp -d) && tar -x -C $D && cd $D && <test cmd>'"}
        if probe:
            cores = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=4", h,
                         "getconf", "_NPROCESSORS_ONLN"], timeout=8)
            t["reachable"] = cores is not None
            if cores and cores.strip().isdigit():
                t["cores"] = int(cores.strip())
        found.append(t)
    if shutil.which("tailscale"):
        out = run(["tailscale", "status", "--json"])
        try:
            peers = json.loads(out or "{}").get("Peer", {}) or {}
            for p in peers.values():
                if p.get("Online") and p.get("OS") in ("linux", "macOS", "windows"):
                    name = (p.get("DNSName") or p.get("HostName") or "").rstrip(".")
                    found.append({"kind": "tailnet", "name": name, "os": p.get("OS"),
                                  "cost": "own hardware: no metered cost",
                                  "how": "reach it over SSH (add it to ~/.ssh/config to probe it)"})
        except ValueError:
            pass
    if shutil.which("docker"):
        out = run(["docker", "context", "ls", "--format", "{{json .}}"])
        for line in (out or "").splitlines():
            try:
                c = json.loads(line)
            except ValueError:
                continue
            ep = c.get("DockerEndpoint", "")
            if ep and not ep.startswith(("unix://", "npipe://")):
                found.append({"kind": "docker-context", "name": c.get("Name"),
                              "cost": "the remote host's", "how": f"docker --context {c.get('Name')} run ..."})
    if shutil.which("gh") and os.path.isdir(os.path.join(repo, ".github", "workflows")):
        t = {"kind": "github-actions", "name": "this repo's CI",
             "cost": "public repos: free on standard runners; private: billed per job-minute "
                     "(ci-audit.py cost gives your numbers)",
             "how": "push the branch, or `gh workflow run` a workflow_dispatch test job"}
        if probe:
            vis = run(["gh", "-R", repo_slug(repo), "repo", "view", "--json", "visibility", "-q", ".visibility"], timeout=10) if repo_slug(repo) else None
            t["visibility"] = (vis or "").strip().lower() or "unknown"
        found.append(t)
        if probe and run(["gh", "codespace", "list", "--json", "name", "-q", "length"], timeout=10) not in (None, "0\n"):
            found.append({"kind": "codespace", "name": "gh codespace list",
                          "cost": "metered per core-hour beyond the free quota",
                          "how": "gh codespace ssh -c <name> -- <test cmd>"})
    for cli, kind in (("modal", "modal"), ("e2b", "e2b"), ("daytona", "daytona"), ("fly", "fly-machines")):
        if shutil.which(cli):
            found.append({"kind": kind, "name": cli, "cost": "metered per second of compute: check the provider's pricing",
                          "how": f"{cli} ... (sandboxed; send the code, not your credentials)"})
    order = {"ssh": 0, "tailnet": 1, "docker-context": 2, "github-actions": 3, "codespace": 4}
    found.sort(key=lambda t: (order.get(t["kind"], 5), str(t.get("name"))))
    return found


def cmd_targets(a):
    found = targets(a.probe, a.repo)
    if shutil.which("wsl") or shutil.which("wsl.exe"):
        note("WSL is present: it isolates a run (no fork limits, Linux-only tools) but shares this "
             "machine's CPU, so it is not an offload target")
    if a.json:
        print(json.dumps({"data": found, "meta": {"schema": SCHEMA, "count": len(found),
                                                  "probed": a.probe}}, indent=2))
    else:
        for t in found:
            print(f"{t['kind']}\t{t.get('name')}\t{t.get('cores', '')}\t{t['cost']}")
    if found:
        note(f"offload to: {found[0]['kind']} {found[0].get('name')} (ranked: own hardware, CI, metered)")
        return 0
    note("no offload target found: run locally with `run-plan.py local` workers")
    return 10


# === local ====================================================================

def mem_available_mb():
    if sys.platform == "win32":
        class MS(ctypes.Structure):
            _fields_ = [("len", ctypes.c_ulong), ("load", ctypes.c_ulong),
                        ("total", ctypes.c_ulonglong), ("avail", ctypes.c_ulonglong),
                        ("tpf", ctypes.c_ulonglong), ("apf", ctypes.c_ulonglong),
                        ("tv", ctypes.c_ulonglong), ("av", ctypes.c_ulonglong),
                        ("aev", ctypes.c_ulonglong)]
        m = MS()
        m.len = ctypes.sizeof(MS)
        if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m)):
            # Commit headroom matters too on Windows: runaway Node/Vite workers exhaust the
            # commit limit long before physical RAM (tests then segfault "randomly").
            return min(m.avail, m.apf) // 2**20
        return None
    try:
        with open("/proc/meminfo") as fh:
            info = dict(l.split(":", 1) for l in fh)
        avail = int(info["MemAvailable"].split()[0]) // 1024
        try:  # a container's cgroup limit beats the host's free memory
            with open("/sys/fs/cgroup/memory.max") as fh:
                lim = fh.read().strip()
            if lim.isdigit():
                avail = min(avail, int(lim) // 2**20)
        except OSError:
            pass
        return avail
    except (OSError, KeyError, ValueError):
        pass
    out = run(["vm_stat"])  # macOS
    if out:
        page = int(re.search(r"page size of (\d+)", out).group(1)) if "page size of" in out else 4096
        pages = sum(int(n) for k, n in re.findall(r"Pages (free|inactive|speculative):\s+(\d+)", out))
        return pages * page // 2**20
    return None


def cpu_busy_pct():
    if hasattr(os, "getloadavg"):
        return min(100.0, 100.0 * os.getloadavg()[0] / (os.cpu_count() or 1))
    if sys.platform == "win32":
        FT = ctypes.c_ulonglong
        def sample():
            i, k, u = FT(), FT(), FT()
            ctypes.windll.kernel32.GetSystemTimes(ctypes.byref(i), ctypes.byref(k), ctypes.byref(u))
            return i.value, k.value + u.value  # kernel time includes idle
        i0, t0 = sample(); time.sleep(0.5); i1, t1 = sample()
        return round(100.0 * (1 - (i1 - i0) / max(1, t1 - t0)), 1)
    return 0.0


def cpus():
    n = os.cpu_count() or 1
    if hasattr(os, "sched_getaffinity"):
        n = len(os.sched_getaffinity(0))
    try:  # cgroup v2 CPU quota, e.g. "200000 100000" = 2 CPUs
        with open("/sys/fs/cgroup/cpu.max") as fh:
            q, per = fh.read().split()
        if q != "max":
            n = min(n, max(1, int(int(q) / int(per))))
    except (OSError, ValueError):
        pass
    return n


def worker_flags(n):
    return {"pytest-xdist": f"-n {n}", "vitest": f"--maxWorkers={n}", "jest": f"--maxWorkers={n}",
            "go": f"-p {n}", "nextest": f"-j {n}", "paratest": f"--processes={n}",
            "pest": f"--parallel --processes={n}", "playwright": f"--workers={n}"}


def measured():
    """Live numbers, or TE_RUNPLAN_FAKE="cpus=8,busy=0,mem=64000" (the test seam: a live
    machine's load makes worker arithmetic untestable)."""
    fake = os.environ.get("TE_RUNPLAN_FAKE")
    if fake:
        try:
            kv = dict(x.split("=") for x in fake.split(","))
            return int(kv["cpus"]), float(kv["busy"]), int(kv["mem"])
        except (ValueError, KeyError):
            note("TE_RUNPLAN_FAKE must look like cpus=8,busy=0,mem=64000")
            sys.exit(2)
    return cpus(), cpu_busy_pct(), mem_available_mb()


def cmd_local(a):
    n, busy, mem = measured()
    reserve = max(1, n // 4)
    by_cpu = int((n - reserve) * (1 - busy / 100.0))
    by_mem = (mem - 2048) // a.per_worker_mb if mem is not None else by_cpu
    workers = max(0, min(by_cpu, by_mem))
    limited = "memory" if by_mem < by_cpu else "cpu"
    out = {"cpus": n, "reserved_cpus": reserve, "cpu_busy_pct": round(busy, 1),
           "mem_available_mb": mem, "per_worker_mb": a.per_worker_mb,
           "workers": max(1, workers), "limited_by": limited, "flags": worker_flags(max(1, workers))}
    if a.json:
        print(json.dumps({"data": out, "meta": {"schema": SCHEMA}}, indent=2))
    else:
        for k in ("cpus", "reserved_cpus", "cpu_busy_pct", "mem_available_mb", "workers", "limited_by"):
            print(f"{k}\t{out[k]}")
        for k, v in out["flags"].items():
            print(f"flag\t{k}\t{v}")
    if busy > 80 or workers < 1:
        note(f"machine busy ({busy:.0f}% CPU, {mem} MB free): offload instead (run-plan.py targets)")
        return 10
    note(f"{out['workers']} workers (limited by {limited}); {reserve} cores held back")
    return 0


# === stack ====================================================================

def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def stack(repo):
    j = lambda *p: os.path.join(repo, *p)
    py = read(j("pyproject.toml")) + read(j("requirements-dev.txt")) + read(j("uv.lock"))[:200000]
    pkg = read(j("package.json"))
    comp = read(j("composer.json"))
    out = []
    if "pytest" in py or os.path.exists(j("pytest.ini")) or os.path.exists(j("conftest.py")):
        has = lambda p: p in py
        out.append({"runner": "pytest", "commands": {
            "junit": "pytest --junitxml=<out>.xml -p no:cacheprovider",
            "parallel": "pytest -n <workers>" if has("pytest-xdist") else "add pytest-xdist, then pytest -n <workers>",
            "changed": "pytest --testmon" if has("pytest-testmon") else "add pytest-testmon (coverage-based selection)",
            "shard": "pytest --splits <N> --group <i>  (pytest-split, duration-balanced)" if has("pytest-split") else "add pytest-split for duration-balanced CI shards",
            "random_order": "pytest -p randomly" if has("pytest-randomly") else "add pytest-randomly before parallelising (exposes order dependence)"}})
    for r in ("vitest", "jest"):
        if f'"{r}"' in pkg:
            out.append({"runner": r, "commands": {
                "junit": f"{r} run --reporter=junit --outputFile=<out>.xml" if r == "vitest" else "jest --reporters=default --reporters=jest-junit",
                "parallel": f"{r} --maxWorkers=<workers>",
                "changed": "vitest run --changed origin/main" if r == "vitest" else "jest --changedSince=origin/main",
                "shard": f"{r} --shard=<i>/<N>"}})
    if '"@playwright/test"' in pkg:
        out.append({"runner": "playwright", "commands": {
            "junit": "PLAYWRIGHT_JUNIT_OUTPUT_NAME=<out>.xml playwright test --reporter=junit",
            "parallel": "playwright test --workers=<workers>", "changed": "playwright test --only-changed=origin/main",
            "shard": "playwright test --shard=<i>/<N>"}})
    for f, tool in (("nx.json", "nx affected -t test --base=origin/main"), ("turbo.json", "turbo run test --affected")):
        if os.path.exists(j(f)):
            out.append({"runner": f.split(".")[0], "commands": {"changed": tool}})
    if "pestphp/pest" in comp or "phpunit/phpunit" in comp:
        pest = "pestphp/pest" in comp
        exe = "vendor/bin/pest" if pest else "vendor/bin/phpunit"
        out.append({"runner": "pest" if pest else "phpunit", "commands": {
            "junit": f"{exe} --log-junit <out>.xml",
            "parallel": f"{exe} --parallel --processes=<workers>" if pest else (
                "vendor/bin/paratest --processes=<workers>" if "paratest" in comp else "add brianium/paratest"),
            "changed": "infection --git-diff-lines (mutation on changed lines only); phpunit has no native selection",
            "order": f"{exe} --order-by=defects --stop-on-defect (fail fast locally)"}})
    if os.path.exists(j("go.mod")):
        out.append({"runner": "go", "commands": {
            "junit": "gotestsum --junitfile <out>.xml -- ./...",
            "parallel": "go test -p <workers> ./...  (and t.Parallel() inside packages)",
            "changed": "go test ./<changed packages>/...  (the build cache already skips unchanged packages: never pass -count=1 in CI)",
            "shard": "split `go list ./...` across jobs"}})
    if os.path.exists(j("Cargo.toml")):
        out.append({"runner": "cargo-nextest", "commands": {
            "junit": "cargo nextest run --profile ci  (with [profile.ci.junit] path in .config/nextest.toml)",
            "parallel": "cargo nextest run -j <workers>", "shard": "cargo nextest run --partition hash:<i>/<N>",
            "changed": "cargo nextest run -p <changed crates>"}})
    return out


def cmd_stack(a):
    if not os.path.isdir(a.repo):
        note(f"not a directory: {a.repo}")
        return 3
    found = stack(a.repo)
    if a.json:
        print(json.dumps({"data": found, "meta": {"schema": SCHEMA, "count": len(found)}}, indent=2))
    else:
        for s in found:
            for k, v in s["commands"].items():
                print(f"{s['runner']}\t{k}\t{v}")
    if not found:
        note("no known runner detected (bash or custom harness?): see speed.md 'The harness is the cost'")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                epilog=__doc__[__doc__.index("Examples:"):],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    t = sub.add_parser("targets")
    t.add_argument("--probe", action="store_true")
    t.add_argument("--repo", default=".")
    t.add_argument("--json", action="store_true")
    l = sub.add_parser("local")
    l.add_argument("--per-worker-mb", type=int, default=1024)
    l.add_argument("--json", action="store_true")
    s = sub.add_parser("stack")
    s.add_argument("--repo", default=".")
    s.add_argument("--json", action="store_true")
    a = p.parse_args()
    if a.cmd == "local" and a.per_worker_mb <= 0:
        p.error("--per-worker-mb must be > 0")
    return {"targets": cmd_targets, "local": cmd_local, "stack": cmd_stack}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
