#!/usr/bin/env python3
import hashlib
import json
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
module = json.loads(subprocess.check_output(["go", "mod", "download", "-json", "github.com/tailscale/tailcat"], cwd=root / "Bridge", text=True))
expected = "v0.7.1-0.20260929145319-b4dc28e8aa89"
if module["Version"] != expected:
    raise SystemExit("Tailcat module pin changed without updating the coverage contract")
original = pathlib.Path(module["Dir"]) / "internal" / "perf" / "perf.go"
retained = root / "Bridge" / "internal" / "upstreamperf" / "perf.go"
if original.read_bytes() != retained.read_bytes():
    raise SystemExit("Official internal/perf copy differs from the pinned source")
print("Verified official perf source: " + hashlib.sha256(retained.read_bytes()).hexdigest())
