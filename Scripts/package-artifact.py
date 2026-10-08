#!/usr/bin/env python3
"""Normalize the ZIP and emit measured provenance; never upload it."""
import hashlib
import json
import os
import pathlib
import plistlib
import re
import stat
import subprocess
import zipfile

root = pathlib.Path(__file__).resolve().parent.parent
artifact = root / "Artifacts" / "TailcatCore.xcframework"
archive = root / "Artifacts" / "TailcatCore.xcframework.zip"
if not artifact.is_dir():
    raise SystemExit("Build TailcatCore.xcframework first.")
info = plistlib.loads((artifact / "Info.plist").read_bytes())
actual = {(v["SupportedPlatform"], v.get("SupportedPlatformVariant", ""), tuple(sorted(v["SupportedArchitectures"]))) for v in info["AvailableLibraries"]}
expected = {("ios", "", ("arm64",)), ("ios", "simulator", ("arm64", "x86_64")), ("macos", "", ("arm64", "x86_64"))}
if actual != expected:
    raise SystemExit("Unexpected XCFramework slices: " + repr(actual))
mach_o = []
for variant in info["AvailableLibraries"]:
    binary = artifact / variant["LibraryIdentifier"] / variant["BinaryPath"]
    arches = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True).strip().split()
    if sorted(arches) != sorted(variant["SupportedArchitectures"]):
        raise SystemExit("Binary architectures disagree with XCFramework metadata")
    for arch in arches:
        commands = subprocess.check_output(["xcrun", "otool", "-arch", arch, "-l", str(binary)], text=True)
        versions = re.findall(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\d+)\s+minos ([\d.]+)\s+sdk ([\d.]+)", commands)
        wanted_platform = "1" if variant["SupportedPlatform"] == "macos" else ("7" if variant.get("SupportedPlatformVariant") == "simulator" else "2")
        wanted_minimum = "13.0" if wanted_platform == "1" else "16.0"
        if not versions or any(platform != wanted_platform or minimum != wanted_minimum for platform, minimum, sdk in versions):
            raise SystemExit("Mach-O deployment target mismatch: " + repr(versions))
        mach_o.append({"architecture": arch, "minimum_os": wanted_minimum,
                       "objects_verified": len(versions), "platform": wanted_platform,
                       "sdk_versions": sorted({sdk for platform, minimum, sdk in versions}),
                       "variant": variant["LibraryIdentifier"]})

with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for path in sorted(artifact.rglob("*")):
        rel = path.relative_to(artifact.parent).as_posix()
        zi = zipfile.ZipInfo(rel + ("/" if path.is_dir() and not path.is_symlink() else ""), (2026, 1, 1, 0, 0, 0))
        zi.create_system = 3
        if path.is_symlink():
            zi.external_attr = (stat.S_IFLNK | 0o777) << 16
            z.writestr(zi, os.readlink(path).encode())
        elif path.is_dir():
            zi.external_attr = (stat.S_IFDIR | 0o755) << 16
            z.writestr(zi, b"")
        else:
            zi.external_attr = (stat.S_IFREG | 0o644) << 16
            zi.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(zi, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)

size = archive.stat().st_size
sha = hashlib.sha256(archive.read_bytes()).hexdigest()
source_hash = hashlib.sha256()
source_files = list((root / "Bridge/mobile").glob("*.go"))
source_files += [root / "Bridge/build-tags.txt", root / "Bridge/go.mod", root / "Bridge/go.sum",
                 root / "Bridge/internal/upstreamperf/perf.go"]
for path in sorted(p for p in source_files if not p.name.endswith("_test.go")):
    source_hash.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes())
manifest = {
    "archive": archive.name,
    "archive_bytes": size,
    "archive_sha256": sha,
    "build_go": subprocess.check_output(["go", "version"], text=True).strip(),
    "bridge_source_sha256": source_hash.hexdigest(),
    "build_xcode": subprocess.check_output(["xcodebuild", "-version"], text=True).strip(),
    "deployment_targets": {"ios": "16.0", "macos": "13.0"},
    "mobile": "v0.0.0-20260908204917-8b95e45f8d3e",
    "mach_o": mach_o,
    "slices": info["AvailableLibraries"],
    "tailcat_commit": "b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f",
    "tailcat_version": "v0.7.1-0.20260929145319-b4dc28e8aa89",
    "upstream_perf_sha256": hashlib.sha256((root / "Bridge/internal/upstreamperf/perf.go").read_bytes()).hexdigest(),
}
(archive.parent / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
print(json.dumps({"archive_bytes": size, "archive_sha256": sha}, sort_keys=True))
# Generated artifacts stay ignored and are uploaded directly to GitHub Releases.
