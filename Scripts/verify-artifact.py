#!/usr/bin/env python3
"""Verify the generated ZIP against source, architecture metadata and notices."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import tempfile
import zipfile

def verify(root, artifacts):
    manifest = json.loads((artifacts / "manifest.json").read_text())
    assert manifest["archive"] == "TailcatCore.xcframework.zip", "Unexpected archive path"
    archive = artifacts / manifest["archive"]
    assert archive.stat().st_size == manifest["archive_bytes"]
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == manifest["archive_sha256"]
    source_hash = hashlib.sha256()
    files = list((root / "Bridge/mobile").glob("*.go")) + [root / "Bridge/build-tags.txt", root / "Bridge/go.mod", root / "Bridge/go.sum", root / "Bridge/internal/upstreamperf/perf.go"]
    for path in sorted(p for p in files if not p.name.endswith("_test.go")):
        source_hash.update(str(path.relative_to(root)).encode() + b"\0" + path.read_bytes())
    assert source_hash.hexdigest() == manifest["bridge_source_sha256"], "Archive predates bridge source changes"
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert z.read("TailcatCore.xcframework/LICENSE") == (root / "LICENSE").read_bytes()
        assert z.read("TailcatCore.xcframework/THIRD_PARTY_NOTICES.md") == (root / "THIRD_PARTY_NOTICES.md").read_bytes()
        info = plistlib.loads(z.read("TailcatCore.xcframework/Info.plist"))
    assert info["AvailableLibraries"] == manifest["slices"]
    assert {(v["SupportedPlatform"], v.get("SupportedPlatformVariant", ""), tuple(sorted(v["SupportedArchitectures"]))) for v in info["AvailableLibraries"]} == {("ios", "", ("arm64",)), ("ios", "simulator", ("arm64", "x86_64")), ("macos", "", ("arm64", "x86_64"))}
    with tempfile.TemporaryDirectory(prefix="swift-tailcat-artifact-") as temporary:
        subprocess.run(["ditto", "-x", "-k", str(archive), temporary], check=True)
        for variant in info["AvailableLibraries"]:
            binary = pathlib.Path(temporary) / "TailcatCore.xcframework" / variant["LibraryIdentifier"] / variant["BinaryPath"]
            arches = subprocess.check_output(["xcrun", "lipo", "-archs", str(binary)], text=True).split()
            assert sorted(arches) == sorted(variant["SupportedArchitectures"])
            platform = "1" if variant["SupportedPlatform"] == "macos" else ("7" if variant.get("SupportedPlatformVariant") == "simulator" else "2")
            minimum = "13.0" if platform == "1" else "16.0"
            for arch in arches:
                commands = subprocess.check_output(["xcrun", "otool", "-arch", arch, "-l", str(binary)], text=True)
                versions = re.findall(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\d+)\s+minos ([\d.]+)\s+sdk ([\d.]+)", commands)
                assert versions and all(p == platform and m == minimum for p, m, sdk in versions)
    print(json.dumps({"archive_bytes": manifest["archive_bytes"], "archive_sha256": manifest["archive_sha256"], "verified_architectures": 5}, sort_keys=True))


if __name__ == "__main__":
    root = pathlib.Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", default=root / "Artifacts", type=pathlib.Path)
    arguments = parser.parse_args()
    verify(root, arguments.artifacts)
