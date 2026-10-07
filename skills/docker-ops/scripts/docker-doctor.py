#!/usr/bin/env python3
"""Read-only check of the container engine on this machine: what the docker CLI talks to,
whether it is up, and what is quietly wrong around it.

Detection is endpoint-first: DOCKER_HOST, then DOCKER_CONTEXT, then the context that
`docker context use` stored (that is docker's own precedence). The endpoint's socket or pipe
path names the provider (Docker Desktop, Colima, OrbStack, Rancher Desktop, Podman, Lima, a
native engine). `docker info` adds the kernel and OS strings, but these are reported, not
trusted for classification: only the `-linuxkit` kernel suffix is documented. Then it looks
around the engine. It checks for a second provider running alongside (they fight over ports
and /var/run/docker.sock), credential helpers missing from PATH, a VM disk image far larger
than what the engine holds, and on Windows, WSL settings and ports Windows has reserved.

Decision rules (from docker/skills' Desktop preflight): an engine that is not running is
reported, never started; a setting that would help is proposed, never applied; a setting an
admin has locked is named and left to the admin.

Usage:   docker-doctor.py [--json] [--ports PORT[,PORT...]] [--timeout S] [-q]
Input:   argv only. Reads DOCKER_HOST, DOCKER_CONTEXT and DOCKER_CONFIG. From
         ~/.docker/config.json it reads only currentContext, credsStore and credHelpers,
         never auths. Also reads Docker Desktop's settings and admin-settings files (key
         names only) and ~/.wslconfig. Read-only probes, each with a timeout:
         `docker context inspect`, `docker version`, `docker info`, `docker system df`; the
         process list; and on Windows `netsh ... excludedportrange`, `netstat -ano`, `reg
         query` of the Lxss key, and `wsl -l --running`. A WSL distro is probed only when it
         is already running.
Output:  stdout = `fact<TAB>key<TAB>value` rows, then `severity<TAB>check<TAB>detail` rows; or
         the --json envelope (schema claude-mods.docker-ops.doctor/v1: data = findings,
         meta.facts = the facts). Data only.
Stderr:  the verdict line, notices.
Exit:    0 nothing to act on (info lines may still print), 2 usage, 3 no container runtime
         found (no docker CLI, no endpoint, no provider), 4 ~/.docker/config.json unreadable,
         7 the docker CLI hung on every probe, 10 findings at low or above (including
         "engine not running")
Never:   starts, stops or restarts an engine, VM or WSL distro; runs, removes or prunes
         containers, images, volumes or build cache; compacts, resizes or sparsifies a disk;
         edits any setting or file; runs `docker desktop diagnose` (it uploads); reads or
         prints a credential.
Hooks:   for tests only. DOCKER_DOCTOR_DOCKER=<path> selects the docker CLI (a .py path runs
         under this Python). DOCKER_DOCTOR_FAKE_HOST=<json file> replaces the host probes:
         os, processes, listeners, excluded_ports, wsl_running, lxss, disk_sizes, wsl_ss.

Examples:
  docker-doctor.py                         # what am I talking to, and is anything off?
  docker-doctor.py --ports 80,443,5432     # also: can these ports be published here?
  docker-doctor.py --json | jq '.meta.facts.provider, .data[].check'
"""
# === SECTION MAP ===
#   PROBES     subprocess wrapper with timeouts, fake-host hook, docker CLI resolution
#   ENDPOINT   config.json, context resolution, provider classification
#   ENGINE     version / info / system df
#   HOST       processes, disk images, WSL, credential helpers, admin settings, ports
#   MAIN       findings, output, exit codes
from __future__ import annotations

import argparse
import configparser
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
from pathlib import Path

EX_OK = 0
EX_USAGE = 2
EX_NORUNTIME = 3
EX_CONFIG = 4
EX_UNAVAILABLE = 7
EX_FINDINGS = 10
SCHEMA = "claude-mods.docker-ops.doctor/v1"
GIB = 1024 ** 3
SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2, "info": 3}

# Subcommands this script may pass to docker. Anything else is a bug, and tests/run.sh
# proves no other subcommand is ever invoked.
ALLOWED_DOCKER = {("context", "inspect"), ("version",), ("info",), ("system", "df")}

# === PROBES ===


class Probe:
    def __init__(self, timeout: float):
        self.timeout = timeout
        fake = os.environ.get("DOCKER_DOCTOR_FAKE_HOST")
        self.fake = json.loads(Path(fake).read_text(encoding="utf-8")) if fake else None
        override = os.environ.get("DOCKER_DOCTOR_DOCKER")
        self.docker = override if override else shutil.which("docker")
        if override and not Path(override).is_file():
            self.docker = None
        self.docker_calls = 0
        self.docker_timeouts = 0

    @property
    def os(self) -> str:
        if self.fake and self.fake.get("os"):
            return self.fake["os"]
        return "windows" if sys.platform.startswith("win") else "darwin" if sys.platform == "darwin" else "linux"

    def run(self, argv, env_extra=None):
        """-> (rc, stdout, stderr); rc None when the binary is missing, 'timeout' on a hang."""
        env = dict(os.environ, **(env_extra or {}))
        try:
            p = subprocess.run(argv, capture_output=True, timeout=self.timeout, env=env, stdin=subprocess.DEVNULL)
        except FileNotFoundError:
            return None, "", ""
        except subprocess.TimeoutExpired:
            return "timeout", "", ""
        except OSError as exc:
            return None, "", str(exc)
        return p.returncode, _decode(p.stdout), _decode(p.stderr)

    def docker_cmd(self, *args):
        if not self.docker:
            return None, "", ""
        if tuple(args[:2]) not in ALLOWED_DOCKER and tuple(args[:1]) not in ALLOWED_DOCKER:
            raise RuntimeError(f"refusing docker {' '.join(args)}: not a read-only probe")
        argv = ([sys.executable, self.docker] if self.docker.endswith(".py") else [self.docker]) + list(args)
        self.docker_calls += 1
        rc, out, err = self.run(argv)
        if rc == "timeout":
            self.docker_timeouts += 1
        return rc, out, err


def _decode(b: bytes) -> str:
    # wsl.exe writes UTF-16LE unless WSL_UTF8=1 took effect; NULs between ASCII give it away.
    if b[:2] in (b"\xff\xfe", b"\xfe\xff") or (len(b) > 3 and b[1:2] == b"\x00" and b[3:4] == b"\x00"):
        return b.decode("utf-16-le", errors="replace").lstrip("\ufeff")
    return b.decode("utf-8", errors="replace")


# === ENDPOINT ===

def docker_config_dir() -> Path:
    return Path(os.environ["DOCKER_CONFIG"]) if os.environ.get("DOCKER_CONFIG") else Path.home() / ".docker"


def read_config(cfg_dir: Path) -> dict:
    """The three keys this script may read. auths (and everything else) is never touched."""
    path = cfg_dir / "config.json"
    if not path.is_file():
        return {}
    data = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(data, dict):
        raise ValueError("top level is not an object")
    helpers = data.get("credHelpers") if isinstance(data.get("credHelpers"), dict) else {}
    return {"currentContext": data.get("currentContext") or "", "credsStore": data.get("credsStore") or "",
            "credHelpers": {str(k): str(v) for k, v in helpers.items()}}


def default_host(host_os: str) -> str:
    return "npipe:////./pipe/docker_engine" if host_os == "windows" else "unix:///var/run/docker.sock"


def resolve_endpoint(probe: Probe, cfg: dict, cfg_dir: Path):
    """-> (host, source, context name)."""
    if os.environ.get("DOCKER_HOST"):
        return os.environ["DOCKER_HOST"], "DOCKER_HOST", ""
    if os.environ.get("DOCKER_CONTEXT"):
        ctx, source = os.environ["DOCKER_CONTEXT"], "DOCKER_CONTEXT"
    elif cfg.get("currentContext"):
        ctx, source = cfg["currentContext"], "docker context use"
    else:
        return default_host(probe.os), "default", "default"
    if ctx == "default":
        return default_host(probe.os), source, ctx
    # The context store is on disk, so this needs no daemon (and no CLI).
    meta = cfg_dir / "contexts" / "meta" / hashlib.sha256(ctx.encode()).hexdigest() / "meta.json"
    try:
        host = json.loads(meta.read_text(encoding="utf-8"))["Endpoints"]["docker"]["Host"]
        return host, source, ctx
    except (OSError, ValueError, KeyError, TypeError):
        pass
    rc, out, _ = probe.docker_cmd("context", "inspect", ctx, "--format", "{{json .Endpoints.docker.Host}}")
    if rc == 0 and out.strip():
        try:
            return json.loads(out.strip()), source, ctx
        except ValueError:
            pass
    return "", source, ctx


PROVIDER_PATHS = [
    ("dockerdesktoplinuxengine", "docker-desktop"),
    ("dockerdesktopwindowsengine", "docker-desktop (Windows containers)"),
    ("/.docker/run/docker.sock", "docker-desktop"),
    ("/.docker/desktop/docker.sock", "docker-desktop"),
    ("/.colima/", "colima"),
    ("/.orbstack/", "orbstack"),
    ("/.rd/", "rancher-desktop"),
    ("podman", "podman"),
    ("/.lima/", "lima"),
]


def unix_path(host: str) -> str:
    return host[len("unix://"):] if host.startswith("unix://") else ""


def classify(host: str, ctx: str, host_os: str):
    """-> (provider, note). Endpoint path first; the context name only breaks ties."""
    h = host.lower().replace("\\", "/")
    if h.startswith(("tcp://", "ssh://", "http://", "https://")):
        return "remote", f"a remote engine at {host}"
    for needle, prov in PROVIDER_PATHS:
        if needle in h:
            return prov, ""
    if h.endswith("pipe/docker_engine"):
        return "ambiguous", ("the legacy docker_engine pipe: Docker Desktop answers on it, and so can a "
                             "native Windows engine, Rancher Desktop or Podman")
    path = unix_path(host)
    if path == "/var/run/docker.sock":
        target = path
        if os.path.islink(path):
            try:
                target = os.path.realpath(path)
            except OSError:
                pass
        if target != path:
            for needle, prov in PROVIDER_PATHS:
                if needle in target.lower():
                    return prov, f"/var/run/docker.sock links to {target}"
            return "unknown", f"/var/run/docker.sock links to {target}"
        return ("native-engine" if host_os == "linux" else "unknown"), ""
    c = ctx.lower()
    for hint, prov in (("desktop", "docker-desktop"), ("colima", "colima"), ("orbstack", "orbstack"),
                       ("rancher", "rancher-desktop"), ("podman", "podman")):
        if hint in c:
            return prov, f"guessed from the context name {ctx!r}"
    return "unknown", ""


# === ENGINE ===

SIZE_RE = re.compile(r"^\s*([\d.]+)\s*([kKMGTP]?i?B)\s*$")
UNITS = {"B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15,
         "KiB": 1024, "MiB": 1024 ** 2, "GiB": GIB, "TiB": 1024 ** 4}


def parse_size(s: str) -> float:
    m = SIZE_RE.match(str(s).split("(")[0])
    return float(m.group(1)) * UNITS.get(m.group(2), 1) if m else 0.0


def engine_probe(probe: Probe):
    """-> (state, info dict, df_total_bytes or None). state: up | down | hung | no-cli."""
    if not probe.docker:
        return "no-cli", {}, None
    rc, out, err = probe.docker_cmd("version", "--format", "{{json .Server}}")
    if rc == "timeout":
        return "hung", {}, None
    server = None
    if rc == 0:
        try:
            server = json.loads(out.strip() or "null")
        except ValueError:
            server = None
    if not server:
        return "down", {"error": (err.strip().splitlines() or [""])[-1][:200]}, None
    info = {"ServerVersion": server.get("Version", "")}
    rc, out, _ = probe.docker_cmd("info", "--format", "{{json .}}")
    if rc == 0:
        try:
            full = json.loads(out.strip())
            for k in ("ServerVersion", "OperatingSystem", "OSType", "KernelVersion", "Architecture", "NCPU",
                      "MemTotal", "DockerRootDir", "Driver", "Name"):
                if full.get(k) not in (None, ""):
                    info[k] = full[k]
        except ValueError:
            pass
    total = None
    rc, out, _ = probe.docker_cmd("system", "df", "--format", "{{json .}}")
    if rc == 0:
        total = 0.0
        for line in out.splitlines():
            try:
                total += parse_size(json.loads(line).get("Size", "0B"))
            except ValueError:
                continue
    return "up", info, total


# === HOST ===

PROCESS_PROVIDERS = [
    (re.compile(r"^(docker desktop(\.exe)?|com\.docker\.backend(\.exe)?)$", re.I), "docker-desktop"),
    (re.compile(r"^colima$", re.I), "colima"),
    (re.compile(r"^orbstack( helper)?$", re.I), "orbstack"),
    (re.compile(r"^rancher[ -]desktop(\.exe)?$", re.I), "rancher-desktop"),
    (re.compile(r"^(vfkit|krunkit|podman-machine|gvproxy(\.exe)?)$", re.I), "podman"),
]
WSL_PROVIDERS = [("docker-desktop", "docker-desktop"), ("rancher-desktop", "rancher-desktop"),
                 ("podman-machine", "podman")]


def processes(probe: Probe):
    if probe.fake is not None:
        return list(probe.fake.get("processes", []))
    if probe.os == "windows":
        rc, out, _ = probe.run(["tasklist", "/fo", "csv", "/nh"])
        return [row.split('","')[0].strip('"') for row in out.splitlines() if row.startswith('"')] if rc == 0 else []
    rc, out, _ = probe.run(["ps", "-axo", "comm="] if probe.os == "darwin" else ["ps", "-eo", "comm="])
    return [Path(line.strip()).name for line in out.splitlines() if line.strip()] if rc == 0 else []


def wsl_running(probe: Probe):
    if probe.fake is not None:
        return list(probe.fake.get("wsl_running", []))
    if probe.os != "windows":
        return []
    rc, out, _ = probe.run(["wsl.exe", "-l", "--running", "-q"], {"WSL_UTF8": "1"})
    return [line.strip() for line in out.splitlines() if line.strip()] if rc == 0 else []


def lxss_distros(probe: Probe):
    """{name: BasePath} from the per-user WSL registry key (read-only `reg query`)."""
    if probe.fake is not None:
        return dict(probe.fake.get("lxss", {}))
    if probe.os != "windows":
        return {}
    rc, out, _ = probe.run(["reg", "query", r"HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss", "/s"])
    if rc != 0:
        return {}
    out_map, name, base = {}, None, None
    for line in out.splitlines():
        if line.startswith("HKEY_"):
            if name and base:
                out_map[name] = base
            name = base = None
        m = re.match(r"\s+(DistributionName|BasePath)\s+REG_\w+\s+(.*)$", line)
        if m:
            if m.group(1) == "DistributionName":
                name = m.group(2).strip()
            else:
                base = m.group(2).strip().removeprefix("\\\\?\\")
    if name and base:
        out_map[name] = base
    return out_map


def running_providers(procs, wsl):
    found = set()
    for p in procs:
        for rx, prov in PROCESS_PROVIDERS:
            if rx.match(p.strip()):
                found.add(prov)
    for d in wsl:
        for prefix, prov in WSL_PROVIDERS:
            if d.lower().startswith(prefix):
                found.add(prov)
    return found


def file_size(probe: Probe, path: Path):
    if probe.fake is not None and "disk_sizes" in probe.fake:
        v = probe.fake["disk_sizes"].get(path.as_posix())
        return int(v) if v is not None else None
    try:
        st = path.stat()
    except OSError:
        return None
    # Docker.raw and data.img are sparse: the blocks actually allocated are what fills the disk.
    blocks = getattr(st, "st_blocks", None)
    return min(st.st_size, blocks * 512) if blocks else st.st_size


def disk_images(probe: Probe, lxss: dict):
    """Known VM disk images -> [(provider, path, bytes)]."""
    home = Path.home()
    cands = []
    if probe.os == "windows":
        local = Path(os.environ.get("LOCALAPPDATA", home / "AppData" / "Local"))
        cands += [("docker-desktop", local / "Docker" / "wsl" / "disk" / "docker_data.vhdx"),
                  ("docker-desktop", local / "Docker" / "wsl" / "main" / "ext4.vhdx")]
        custom = desktop_settings(probe).get("disk_dir")
        if custom:
            cands.append(("docker-desktop", Path(custom) / "disk" / "docker_data.vhdx"))
        for name, base in lxss.items():
            for prefix, prov in WSL_PROVIDERS:
                if name.lower().startswith(prefix):
                    cands.append((prov, Path(base) / "ext4.vhdx"))
    elif probe.os == "darwin":
        cands += [("docker-desktop", home / "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"),
                  ("orbstack", home / "Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img"),
                  ("rancher-desktop", home / "Library/Application Support/rancher-desktop/lima/0/diffdisk")]
        cands += [("colima", p) for p in sorted((home / ".colima" / "_lima").glob("*/diffdisk"))]
        cands += [("podman", p) for p in sorted((home / ".local/share/containers/podman/machine").glob("*/*.raw"))]
    else:
        cands += [("docker-desktop", home / ".docker/desktop/vms/0/data/Docker.raw")]
        cands += [("colima", p) for p in sorted((home / ".colima" / "_lima").glob("*/diffdisk"))]
    out, seen = [], set()
    for prov, path in cands:
        key = path.as_posix().lower()
        if key in seen:
            continue
        seen.add(key)
        size = file_size(probe, path)
        if size is not None:
            out.append((prov, path, size))
    return out


def desktop_settings(probe: Probe) -> dict:
    """The custom disk-image folder from Docker Desktop's settings, if one is set (key names vary by version)."""
    if probe.os == "windows":
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming")) / "Docker"
    elif probe.os == "darwin":
        base = Path.home() / "Library/Group Containers/group.com.docker"
    else:
        base = Path.home() / ".docker/desktop"
    for name in ("settings-store.json", "settings.json"):
        try:
            data = json.loads((base / name).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            continue
        for k, v in (data.items() if isinstance(data, dict) else []):
            if isinstance(v, str) and re.search(r"(DistroDir|DiskImage|DataFolder)", k, re.I) and v:
                return {"disk_dir": v, "source": f"{name}:{k}"}
    return {}


def admin_locked(probe: Probe):
    if probe.os == "windows":
        path = Path(os.environ.get("PROGRAMDATA", "C:/ProgramData")) / "DockerDesktop" / "admin-settings.json"
    elif probe.os == "darwin":
        path = Path("/Library/Application Support/com.docker.docker/admin-settings.json")
    else:
        path = Path("/usr/share/docker-desktop/admin-settings.json")
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return sorted(k for k, v in data.items() if isinstance(v, dict) and v.get("locked") is True)


def wslconfig(probe: Probe) -> dict:
    if probe.os != "windows":
        return {}
    path = Path(os.environ.get("USERPROFILE", Path.home())) / ".wslconfig"
    cp = configparser.ConfigParser()
    try:
        cp.read_string(path.read_text(encoding="utf-8-sig"))
    except (OSError, configparser.Error, UnicodeDecodeError):
        return {}
    out = {}
    for section, key in (("wsl2", "networkingMode"), ("wsl2", "memory"), ("wsl2", "processors"),
                         ("experimental", "sparseVhd"), ("experimental", "autoMemoryReclaim")):
        if cp.has_option(section, key):
            out[f"{section}.{key}"] = cp.get(section, key)
    return out


def excluded_ranges(probe: Probe):
    if probe.fake is not None:
        return [tuple(r) for r in probe.fake.get("excluded_ports", [])]
    if probe.os != "windows":
        return []
    rc, out, _ = probe.run(["netsh", "interface", "ipv4", "show", "excludedportrange", "protocol=tcp"])
    return [(int(a), int(b)) for a, b in re.findall(r"^\s*(\d+)\s+(\d+)", out, re.M)] if rc == 0 else []


def listeners(probe: Probe, ports):
    """{port: holder} for the ports asked about, on this side of any VM boundary."""
    if probe.fake is not None:
        return {int(k): v for k, v in probe.fake.get("listeners", {}).items() if int(k) in ports}
    found = {}
    if probe.os == "windows":
        rc, out, _ = probe.run(["netstat", "-ano", "-p", "tcp"])
        names = {}
        rc2, tl, _ = probe.run(["tasklist", "/fo", "csv", "/nh"])
        for row in tl.splitlines() if rc2 == 0 else []:
            cells = row.strip('"').split('","')
            if len(cells) > 1:
                names[cells[1]] = cells[0]
        for m in re.finditer(r"TCP\s+\S+:(\d+)\s+\S+\s+LISTENING\s+(\d+)", out if rc == 0 else ""):
            p = int(m.group(1))
            if p in ports:
                found[p] = f"{names.get(m.group(2), 'pid')} (pid {m.group(2)})"
        return found
    for p in ports:
        rc, out, _ = probe.run(["lsof", "-nP", f"-iTCP:{p}", "-sTCP:LISTEN", "-Fc"])
        if rc == 0 and out.strip():
            name = next((line[1:] for line in out.splitlines() if line.startswith("c")), "a process")
            found[p] = name
            continue
        if rc is None:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(0.3)
                if s.connect_ex(("127.0.0.1", p)) == 0:
                    found[p] = "a process"
    return found


def wsl_listeners(probe: Probe, ports, running):
    """Ports held inside the default WSL distro - only when one is already running."""
    if not running or probe.os != "windows":
        return {}
    if probe.fake is not None:
        out = probe.fake.get("wsl_ss", "")
    else:
        rc, out, _ = probe.run(["wsl.exe", "-e", "ss", "-ltnH"], {"WSL_UTF8": "1"})
        if rc != 0:
            return {}
    held = {}
    for m in re.finditer(r"LISTEN\s+\d+\s+\d+\s+\S*:(\d+)\s", out):
        if int(m.group(1)) in ports:
            held[int(m.group(1))] = "a process inside WSL"
    return held


def cred_helpers(cfg: dict):
    """-> [(helper, [registries], on_path)] for credsStore and every credHelpers entry."""
    want: dict = {}
    if cfg.get("credsStore"):
        want.setdefault(cfg["credsStore"], []).append("(default for every registry)")
    for reg, helper in cfg.get("credHelpers", {}).items():
        want.setdefault(helper, []).append(reg)
    return [(h, regs, bool(shutil.which(f"docker-credential-{h}"))) for h, regs in want.items()]


# === MAIN ===

DOCKER_OWN_PORT_HOLDERS = re.compile(r"(com\.docker|vpnkit|wslrelay|docker-proxy|dockerd|gvproxy|orbstack|limactl|rancher)", re.I)


def gib(n) -> str:
    return f"{n / GIB:.1f} GiB"


def start_hint(provider: str) -> str:
    return {
        "docker-desktop": "start Docker Desktop yourself (the app, or `docker desktop start`)",
        "colima": "run `colima start` yourself",
        "orbstack": "open OrbStack (or `orb start`) yourself",
        "rancher-desktop": "open Rancher Desktop yourself",
        "podman": "run `podman machine start` yourself",
        "lima": "run `limactl start <instance>` yourself",
        "native-engine": "start the daemon yourself (`sudo systemctl start docker`)",
    }.get(provider, "start the engine yourself")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="docker-doctor.py", description=(__doc__ or "").split("\n\n", 1)[0],
        epilog="EXAMPLES:\n  docker-doctor.py\n  docker-doctor.py --ports 80,443,5432\n"
               "  docker-doctor.py --json | jq '.meta.facts.provider'",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--json", action="store_true", help="emit the JSON envelope on stdout")
    ap.add_argument("--ports", default="", help="comma-separated host ports to check (in use, or reserved by Windows)")
    ap.add_argument("--timeout", type=float, default=10.0, help="seconds per probe (default 10)")
    ap.add_argument("-q", "--quiet", action="store_true", help="no verdict line on stderr")
    opts = ap.parse_args(argv)
    try:
        ports = sorted({int(p) for p in opts.ports.split(",") if p.strip()})
        if any(not 0 < p < 65536 for p in ports):
            raise ValueError
    except ValueError:
        print(f"error: --ports {opts.ports!r}: want comma-separated port numbers 1-65535", file=sys.stderr)
        return EX_USAGE
    if opts.timeout <= 0:
        print("error: --timeout must be positive", file=sys.stderr)
        return EX_USAGE

    probe = Probe(opts.timeout)
    cfg_dir = docker_config_dir()
    try:
        cfg = read_config(cfg_dir)
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        print(f"error: {cfg_dir / 'config.json'} is unreadable ({exc}); docker itself will fail on it too",
              file=sys.stderr)
        return EX_CONFIG

    findings, facts = [], {"os": probe.os, "docker_cli": probe.docker or "not found"}

    def add(sev, check, detail):
        findings.append({"severity": sev, "check": check, "detail": detail})

    host, source, ctx = resolve_endpoint(probe, cfg, cfg_dir)
    provider, note = classify(host, ctx, probe.os) if host else ("unknown", "the context has no docker endpoint")
    facts.update({"endpoint": host or "unresolved", "endpoint_source": source, "context": ctx or "-",
                  "provider": provider})
    if note:
        facts["provider_note"] = note
    if os.environ.get("DOCKER_HOST") and (os.environ.get("DOCKER_CONTEXT") or cfg.get("currentContext") not in ("", "default")):
        add("low", "docker-host-overrides-context",
            f"DOCKER_HOST={host} is set, so it silently wins over the context "
            f"{os.environ.get('DOCKER_CONTEXT') or cfg.get('currentContext')!r}; unset it if that context is the one you meant")
    path = unix_path(host)
    socket_missing = bool(path) and probe.os != "windows" and not Path(path).exists()

    state, info, df_total = engine_probe(probe)
    facts["engine"] = state if state != "up" else f"up ({info.get('ServerVersion', '?')})"
    for k in ("OperatingSystem", "OSType", "KernelVersion", "Architecture", "NCPU", "DockerRootDir", "Driver"):
        if k in info:
            facts[f"engine_{k}"] = str(info[k])
    if "MemTotal" in info:
        facts["engine_MemTotal"] = gib(int(info["MemTotal"]))
    if df_total is not None:
        facts["engine_data"] = gib(df_total)

    procs = processes(probe)
    wsl = wsl_running(probe)
    running = running_providers(procs, wsl)
    facts["providers_running"] = ",".join(sorted(running)) or "none detected"
    if len(running) > 1:
        add("medium", "multiple-providers",
            f"{' and '.join(sorted(running))} are all running: they compete for published ports and for "
            "/var/run/docker.sock, and tools that ignore contexts (IDEs, testcontainers) may reach a different "
            "engine than your CLI; quit the ones you are not using")

    if state == "no-cli":
        if running or host and not socket_missing:
            add("medium", "cli-missing", "a container provider is present but no `docker` CLI is on PATH"
                + (f" (running: {', '.join(sorted(running))})" if running else ""))
    elif state == "hung":
        add("high", "engine-hung", f"`docker version` did not answer within {opts.timeout:g}s; the engine or its VM "
            "is wedged. Restart it yourself; the doctor never does")
    elif state == "down":
        where = "the endpoint does not exist" if socket_missing else "nothing answered"
        named = "the engine" if provider in ("unknown", "ambiguous") else f"the {provider} engine"
        add("high", "engine-down", f"{named} at {host or 'the default endpoint'} is not reachable "
            f"({where}): {start_hint(provider)}; the doctor never starts engines"
            + (f". docker said: {info['error']}" if info.get("error") else ""))
    if socket_missing and state != "up":
        add("high", "endpoint-missing", f"{source} points at {path}, which does not exist: the engine it names is "
            "stopped or uninstalled. `docker context ls` shows the alternatives; a DOCKER_HOST in your shell profile "
            "beats every context")
    if provider == "ambiguous":
        add("info", "endpoint-ambiguous", note)
    if info.get("OSType") == "windows":
        add("low", "windows-containers", "the engine is in Windows-containers mode, so Linux images will not run; "
            "switch with Docker Desktop's tray menu (Switch to Linux containers)")

    lx = lxss_distros(probe)
    images = disk_images(probe, lx)
    for prov, p, size in images:
        facts[f"disk:{prov}:{p.name}"] = f"{gib(size)} at {p}"
    if df_total is not None:
        for prov, p, size in images:
            if prov == provider and size >= 20 * GIB and size - df_total >= 10 * GIB:
                add("medium", "disk-bloat",
                    f"{p.name} uses {gib(size)} on disk but the engine holds only {gib(df_total)}; the difference "
                    "is freed space the VM disk never gave back. See references/disk-reclaim.md (Docker Desktop "
                    "4.59+ no longer compacts its WSL disk); the doctor never compacts")

    for helper, regs, on_path in cred_helpers(cfg):
        facts[f"cred_helper:{helper}"] = "on PATH" if on_path else "missing"
        if not on_path:
            add("medium", "cred-helper-missing",
                f"config.json names credential helper {helper!r} for {', '.join(regs)}, but docker-credential-{helper} "
                "is not on PATH: logins and private pulls fail with 'error getting credentials'")

    locked = admin_locked(probe)
    if locked is not None:
        facts["admin_settings"] = f"{len(locked)} locked"
        if locked:
            add("info", "admin-locked", f"your organisation locks these Docker Desktop settings: {', '.join(locked)}. "
                "Changing them is your admin's call; there is no local workaround")

    for k, v in wslconfig(probe).items():
        facts[f"wslconfig:{k}"] = v
    if probe.os == "windows":
        facts["wsl_running"] = ",".join(wsl) or "none"

    if ports:
        ranges = excluded_ranges(probe)
        held = listeners(probe, ports)
        held_wsl = wsl_listeners(probe, ports, wsl)
        for p in ports:
            r = next(((a, b) for a, b in ranges if a <= p <= b), None)
            if r:
                add("high", "port-reserved",
                    f"port {p} is inside a range Windows has reserved ({r[0]}-{r[1]}, usually Hyper-V or WinNAT): "
                    "publishing it fails with 'forbidden by its access permissions'. Pick another port; changing "
                    "the reservation is an admin step the doctor does not take")
            if p in held:
                if DOCKER_OWN_PORT_HOLDERS.search(held[p]):
                    add("info", "port-published", f"port {p} is held by {held[p]}: a container already publishes it")
                else:
                    add("medium", "port-in-use", f"port {p} is held by {held[p]}; a container cannot publish it")
            if p in held_wsl:
                add("medium", "port-in-use-wsl",
                    f"port {p} is held inside the running WSL distro, where Windows-side checks cannot see it")
            if not r and p not in held and p not in held_wsl:
                facts[f"port:{p}"] = "free"

    if probe.docker and probe.docker_calls and probe.docker_timeouts == probe.docker_calls:
        exit_hung = True
    else:
        exit_hung = False
    no_runtime = (state == "no-cli" and not running and not images and (not host or socket_missing or probe.os == "windows")
                  and not cfg)
    if no_runtime:
        findings = []   # with nothing installed, "the endpoint is missing" is noise, not a finding

    findings.sort(key=lambda f: SEVERITY_RANK[f["severity"]])
    actionable = [f for f in findings if f["severity"] != "info"]
    if opts.json:
        print(json.dumps({"data": findings, "meta": {"count": len(findings), "schema": SCHEMA, "facts": facts}},
                         indent=2))
    else:
        for k, v in facts.items():
            print(f"fact\t{k}\t{v}")
        for f in findings:
            print(f"{f['severity']}\t{f['check']}\t{f['detail']}")
    if not opts.quiet:
        if no_runtime:
            print("docker-doctor: no container runtime found (no docker CLI, endpoint or provider)", file=sys.stderr)
        else:
            print(f"docker-doctor: {provider} via {source}, engine {facts['engine']}; "
                  f"{len(findings)} finding(s)" if findings else
                  f"docker-doctor: {provider} via {source}, engine {facts['engine']}; nothing to report", file=sys.stderr)
    if no_runtime:
        return EX_NORUNTIME
    if exit_hung:
        return EX_UNAVAILABLE
    return EX_FINDINGS if actionable else EX_OK


if __name__ == "__main__":
    sys.exit(main())
