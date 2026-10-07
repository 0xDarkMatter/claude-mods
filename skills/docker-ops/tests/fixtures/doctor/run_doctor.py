"""Build one docker-doctor.py test scenario in a temp dir and run the doctor inside it.

Usage: run_doctor.py SCENARIO DOCTOR [doctor args...]
Every scenario gets its own HOME / USERPROFILE / LOCALAPPDATA / APPDATA / PROGRAMDATA and
DOCKER_CONFIG, the stub docker CLI (docker_stub.py) and a fake host description, so nothing
on the real machine leaks in. Prints the doctor's stdout and stderr; exits with its code.
STUB_LOG, when set, collects every docker invocation the doctor made.
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GIB = 1024 ** 3


def build(name: str, base: Path) -> dict:
    home, cfgdir = base / "home", base / "dockercfg"
    for d in (home, cfgdir, base / "local", base / "roaming", base / "programdata"):
        d.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if k not in ("DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG")}
    env.update(HOME=str(home), USERPROFILE=str(home), LOCALAPPDATA=str(base / "local"),
               APPDATA=str(base / "roaming"), PROGRAMDATA=str(base / "programdata"), DOCKER_CONFIG=str(cfgdir),
               DOCKER_DOCTOR_DOCKER=str(HERE / "docker_stub.py"), STUB_MODE="up")
    fake = {"os": "linux", "processes": [], "wsl_running": [], "lxss": {}, "listeners": {},
            "excluded_ports": [], "disk_sizes": {}, "wsl_ss": ""}
    cfg: dict = {}

    def colima_context():
        sock = home / ".colima" / "default" / "docker.sock"
        sock.parent.mkdir(parents=True, exist_ok=True)
        sock.write_text("")
        meta = cfgdir / "contexts" / "meta" / hashlib.sha256(b"colima").hexdigest()
        meta.mkdir(parents=True, exist_ok=True)
        (meta / "meta.json").write_text(json.dumps(
            {"Name": "colima", "Endpoints": {"docker": {"Host": "unix://" + sock.as_posix()}}}))
        cfg["currentContext"] = "colima"
        fake["processes"] = ["colima", "limactl"]

    if name in ("healthy", "bloat", "down", "multi", "creds", "missing-socket", "hang"):
        colima_context()
    if name == "bloat":
        disk = home / ".colima" / "_lima" / "colima" / "diffdisk"
        disk.parent.mkdir(parents=True, exist_ok=True)
        disk.write_text("")
        fake["disk_sizes"][disk.as_posix()] = 30 * GIB
    if name == "down":
        env["STUB_MODE"] = "down"
    if name == "hang":
        env["STUB_MODE"] = "hang"
    if name == "multi":
        fake["processes"] = ["Docker Desktop", "colima", "limactl"]
    if name == "creds":
        cfg["credsStore"] = "nosuchhelper-fixture"
        cfg["auths"] = {"registry.example.com": {"auth": "c2VjcmV0LWZpeHR1cmU="}}
    if name == "missing-socket":
        env["DOCKER_HOST"] = "unix://" + (base / "gone" / "docker.sock").as_posix()
        env["STUB_MODE"] = "down"
    if name in ("windows-ports", "admin", "winctr"):
        fake["os"] = "windows"
    if name == "windows-ports":
        fake["excluded_ports"] = [[50000, 50059]]
        fake["listeners"] = {"5432": "postgres.exe (pid 11)", "8080": "com.docker.backend.exe (pid 12)"}
        fake["wsl_running"] = ["Ubuntu"]
        fake["wsl_ss"] = "LISTEN 0      4096         0.0.0.0:3000      0.0.0.0:*\n"
    if name == "admin":
        p = base / "programdata" / "DockerDesktop"
        p.mkdir(parents=True, exist_ok=True)
        (p / "admin-settings.json").write_text(json.dumps(
            {"configurationFileVersion": 2, "exposeDockerAPIOnTCP2375": {"locked": True, "value": False},
             "proxy": {"locked": False}}))
    if name == "winctr":
        env["STUB_OSTYPE"] = "windows"
    if name == "none":
        env["DOCKER_DOCTOR_DOCKER"] = str(base / "no-docker-here")
    if name == "badcfg":
        (cfgdir / "config.json").write_text("{not json")
    elif cfg:
        (cfgdir / "config.json").write_text(json.dumps(cfg))
    (base / "fake-host.json").write_text(json.dumps(fake))
    env["DOCKER_DOCTOR_FAKE_HOST"] = str(base / "fake-host.json")
    return env


def main() -> int:
    name, doctor, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
    with tempfile.TemporaryDirectory() as d:
        env = build(name, Path(d))
        p = subprocess.run([sys.executable, doctor, *rest], env=env, capture_output=True, text=True)
        sys.stdout.write(p.stdout)
        sys.stderr.write(p.stderr)
        return p.returncode


if __name__ == "__main__":
    sys.exit(main())
