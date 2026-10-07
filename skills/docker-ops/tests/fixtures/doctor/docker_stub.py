"""Test stand-in for the docker CLI, used by tests/run.sh through DOCKER_DOCTOR_DOCKER.

It answers the four read-only probes docker-doctor.py makes, in the mode STUB_MODE names
(up | down | hang), and appends every invocation to STUB_LOG so the suite can prove the
doctor never asks docker for anything else. It never talks to a real engine.
"""
import json
import os
import sys
import time

args = sys.argv[1:]
log = os.environ.get("STUB_LOG")
if log:
    with open(log, "a", encoding="utf-8") as fh:
        fh.write(" ".join(args) + "\n")
mode = os.environ.get("STUB_MODE", "up")
GIB = 1024 ** 3

if args[:2] == ["context", "inspect"]:
    print(json.dumps(os.environ.get("STUB_CONTEXT_HOST", "unix:///nonexistent/docker.sock")))
elif args[:1] == ["version"]:
    if mode == "hang":
        time.sleep(30)
    if mode == "down":
        print("null")
        print("failed to connect to the docker API (stub)", file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"Version": "29.8.2", "ApiVersion": "1.52"}))
elif args[:1] == ["info"]:
    print(json.dumps({"ServerVersion": "29.8.2", "OperatingSystem": "Stub Linux", "OSType": os.environ.get("STUB_OSTYPE", "linux"),
                      "KernelVersion": "6.12.1-stub", "Architecture": "x86_64", "NCPU": 8, "MemTotal": 8 * GIB,
                      "DockerRootDir": "/var/lib/docker", "Driver": "overlayfs"}))
elif args[:2] == ["system", "df"]:
    print(json.dumps({"Type": "Images", "TotalCount": "3", "Size": "4GB", "Reclaimable": "1GB (25%)"}))
    print(json.dumps({"Type": "Local Volumes", "TotalCount": "1", "Size": "1GB", "Reclaimable": "0B (0%)"}))
else:
    print(f"stub: unexpected docker {' '.join(args)}", file=sys.stderr)
    sys.exit(99)
