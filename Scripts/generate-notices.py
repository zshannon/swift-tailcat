#!/usr/bin/env python3
"""Collect retained notices from package directories actually selected by Apple builds."""
import json
import os
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
bridge = root / "Bridge"
tags = (bridge / "build-tags.txt").read_text().strip()
modules = {}
packages = {}
decoder = json.JSONDecoder()
goroot = pathlib.Path(subprocess.check_output(["go", "env", "GOROOT"], cwd=bridge, text=True).strip())
modules["Go toolchain"] = {"Dir": str(goroot), "Path": "Go standard library and runtime", "Version": "go1.27.1"}
packages["Go toolchain"] = set()

for goos, arch in [("darwin", "amd64"), ("darwin", "arm64"), ("ios", "amd64"), ("ios", "arm64")]:
    env = dict(os.environ, CGO_ENABLED="1", GOARCH=arch, GOOS=goos)
    output = subprocess.check_output(["go", "list", "-deps", "-json", "-tags=" + tags, "./mobile"], cwd=bridge, env=env, text=True)
    offset = 0
    while offset < len(output):
        while offset < len(output) and output[offset].isspace():
            offset += 1
        if offset == len(output):
            break
        package, offset = decoder.raw_decode(output, offset)
        module = package.get("Module")
        if package.get("Standard"):
            packages["Go toolchain"].add(package["Dir"])
        if not module or module.get("Main"):
            continue
        module = module.get("Replace", module)
        identity = module["Path"] + "@" + module.get("Version", "")
        modules[identity] = module
        packages.setdefault(identity, set()).add(package["Dir"])

# gomobile adds its generated binding runtime outside the selected package graph.
mobile = json.loads(subprocess.check_output(["go", "mod", "download", "-json", "golang.org/x/mobile"], cwd=bridge, text=True))
modules[mobile["Path"] + "@" + mobile["Version"]] = mobile
packages.setdefault(mobile["Path"] + "@" + mobile["Version"], set())

def is_notice(path):
    name = path.name.upper()
    return path.is_file() and (name in ["AUTHORS", "COPYING", "COPYRIGHT", "LICENSE", "NOTICE", "PATENTS"] or
                              name.startswith("LICENSE.") or name.startswith("NOTICE."))

notice = ["# Third-party notices", "", "Generated from the union of the pinned macOS/iOS package graphs, plus gomobile and Go runtimes.",
          "The official Tailcat perf source is retained under Bridge/internal/upstreamperf with provenance and its BSD-3-Clause notice.", ""]
inventory = []
for identity, module in sorted(modules.items()):
    directory = pathlib.Path(module["Dir"])
    files = set(p for p in directory.iterdir() if is_notice(p))
    for package in packages[identity]:
        current = pathlib.Path(package)
        while current != directory and directory in current.parents:
            files.update(p for p in current.iterdir() if is_notice(p))
            current = current.parent
    license_directory = directory / "LICENSES"
    if license_directory.is_dir():
        files.update(p for p in license_directory.rglob("*") if p.is_file())
    if not files:
        raise SystemExit("No retained license found for " + identity)
    notice += ["## " + module["Path"] + " " + module.get("Version", ""), ""]
    relative_files = []
    for path in sorted(files):
        relative = str(path.relative_to(directory))
        relative_files.append(relative)
        text = path.read_text(encoding="utf-8")
        notice += ["### " + relative, "", "```text", text.rstrip(), "```", ""]
    inventory.append({"module": module["Path"], "notices": relative_files,
                      "packages": sorted(str(pathlib.Path(p).relative_to(directory)) for p in packages[identity]),
                      "version": module.get("Version", "")})

(root / "THIRD_PARTY_NOTICES.md").write_text("\n".join(notice), encoding="utf-8")
(root / "Docs" / "DependencyInventory.json").write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n")
print(json.dumps({"modules": len(modules), "notice_bytes": (root / "THIRD_PARTY_NOTICES.md").stat().st_size}))
