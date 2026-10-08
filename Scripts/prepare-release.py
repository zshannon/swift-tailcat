#!/usr/bin/env python3
"""Prepare source-only distribution and a separately built Apple release asset."""
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


def git(root, *arguments, environment=None, input_text=None):
    return subprocess.check_output(["git", *arguments], cwd=root, env=environment, input=input_text, text=True).strip()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")


def validate_version(version):
    match = SEMVER.fullmatch(version) if isinstance(version, str) else None
    if not match or (match[4] and any(part.isdigit() and len(part) > 1 and part[0] == "0" for part in match[4].split("."))):
        raise RuntimeError("An explicit semantic version is required (for example 0.0.1)")
    return version


def prepare(root, output, expected_commit=None, version=None):
    version = validate_version(version)
    root, output = root.resolve(), output.resolve()
    commit = git(root, "rev-parse", "HEAD")
    if expected_commit is not None and commit != expected_commit:
        raise RuntimeError("Checkout commit differs from the triggering commit")
    if git(root, "rev-parse", "--is-shallow-repository") != "false":
        raise RuntimeError("Full history is required to check source artifact ancestry")
    if git(root, "status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError("Release packaging requires a clean tracked checkout")
    if git(root, "log", "--format=", "--name-only", commit, "--", "Artifacts"):
        raise RuntimeError("Generated artifacts exist in source history; remove them before publishing")
    if output == root or root in output.parents:
        raise RuntimeError("Release output must be outside the source checkout")
    manifest = json.loads((root / "Artifacts/manifest.json").read_text())
    if manifest["archive"] != "TailcatCore.xcframework.zip":
        raise RuntimeError("Unexpected binary archive path")
    archive = root / "Artifacts" / manifest["archive"]
    if archive.stat().st_size != manifest["archive_bytes"] or sha256(archive) != manifest["archive_sha256"]:
        raise RuntimeError("Built archive differs from its measured manifest")
    digest = hashlib.sha256()
    files = list((root / "Bridge/mobile").glob("*.go")) + [root / "Bridge/build-tags.txt", root / "Bridge/go.mod", root / "Bridge/go.sum", root / "Bridge/internal/upstreamperf/perf.go"]
    for path in sorted(p for p in files if not p.name.endswith("_test.go")):
        digest.update(path.relative_to(root).as_posix().encode() + b"\0" + path.read_bytes())
    if digest.hexdigest() != manifest["bridge_source_sha256"]:
        raise RuntimeError("Built archive predates the current bridge source; rebuild it first")
    tag = "v" + version
    source_archive = "swift-tailcat-" + tag + ".zip"
    output.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(archive, output / archive.name)
    shutil.copyfile(root / "Artifacts/manifest.json", output / "manifest.json")
    release = {"artifact_manifest": manifest, "commit": commit, "source_tree": git(root, "rev-parse", commit + "^{tree}"), "version": version, "repository": "zshannon/swift-tailcat", "source_archive": source_archive, "tag": tag}
    (output / "release.json").write_text(json.dumps(release))
    distribution(root, output)
    return json.loads((output / "release.json").read_text())


def write_payloads(root, output, release):
    commit = release.get("package_commit", release["commit"])
    source_archive = release["source_archive"]
    subprocess.run(["git", "archive", "-0", "--format=zip", "--prefix=swift-tailcat/", "--output=" + str(output / source_archive), commit], cwd=root, check=True)
    (output / "release.json").write_text(json.dumps(release, indent=2, sort_keys=True) + "\n")
    names = sorted(["TailcatCore.xcframework.zip", "manifest.json", "release.json", source_archive])
    (output / "SHA256SUMS").write_text("".join(sha256(output / name) + "  " + name + "\n" for name in names))
    (output / "release-notes.md").write_text(
        "Swift Tailcat " + release["tag"] + "\n\n"
        "Source commit: `" + release["commit"] + "`.\n\n"
        "Package commit: `" + commit + "`.\n\n"
        "Official Tailcat: `" + release["artifact_manifest"]["tailcat_commit"] + "`.\n\n"
        "The Apple XCFramework is built from pinned source and uploaded as a Release asset; no binary is stored in Git. "
        "Build inputs and architecture metadata are in `manifest.json`; wrapper provenance is in `release.json`. "
        "Use `SHA256SUMS` to verify the four payload files. "
        "The source ZIP includes the remote SwiftPM manifest, source, documentation and license notices. "
        "Public tag download URLs require no private asset credentials.\n\n"
        "Runtime tests cover macOS arm64 with owned loopback services. iOS device/simulator, macOS Intel and internet NAT traversal remain unverified.\n"
    )


def distribution(root, output):
    release = json.loads((output / "release.json").read_text())
    validate_version(release["tag"][1:])
    source = release["commit"]
    url = "https://github.com/zshannon/swift-tailcat/releases/download/" + release["tag"] + "/TailcatCore.xcframework.zip"
    checksum = release["artifact_manifest"]["archive_sha256"]
    original = subprocess.check_output(["git", "show", source + ":Package.swift"], cwd=root, text=True)
    pattern = r'\.binaryTarget\(name: "TailcatCore", url: "[^"]+", checksum: "[0-9a-f]{64}"\)'
    if len(re.findall(pattern, original)) != 1:
        raise RuntimeError("Cannot locate the public distribution binary target")
    manifest = re.sub(pattern, '.binaryTarget(name: "TailcatCore", url: "' + url + '", checksum: "' + checksum + '")', original)
    if original == manifest:
        release.update({"binary_url": url, "package_commit": source})
        write_payloads(root, output, release)
        return {"commit": source, "parent": None, "tree": git(root, "rev-parse", source + "^{tree}"), "manifest": manifest}
    date = datetime.datetime.fromtimestamp(int(git(root, "show", "-s", "--format=%ct", source)), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    author = {"date": date, "email": "41898282+github-actions[bot]@users.noreply.github.com", "name": "github-actions[bot]"}
    message = "Release " + release["tag"] + "\n\nSource: " + source + "\n"
    environment = dict(os.environ, GIT_AUTHOR_DATE=date, GIT_AUTHOR_EMAIL=author["email"], GIT_AUTHOR_NAME=author["name"], GIT_COMMITTER_DATE=date, GIT_COMMITTER_EMAIL=author["email"], GIT_COMMITTER_NAME=author["name"])
    with tempfile.TemporaryDirectory(prefix="swift-tailcat-release-index-") as temporary:
        environment["GIT_INDEX_FILE"] = str(pathlib.Path(temporary) / "index")
        git(root, "read-tree", source, environment=environment)
        blob = git(root, "hash-object", "-w", "--stdin", input_text=manifest)
        git(root, "update-index", "--cacheinfo", "100644," + blob + ",Package.swift", environment=environment)
        tree = git(root, "write-tree", environment=environment)
        package_commit = git(root, "commit-tree", tree, "-p", source, environment=environment, input_text=message)
    release.update({"binary_url": url, "package_commit": package_commit})
    write_payloads(root, output, release)
    return {"author": author, "base_tree": git(root, "rev-parse", source + "^{tree}"), "commit": package_commit, "manifest": manifest, "message": message, "parent": source, "tree": tree}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit")
    parser.add_argument("--version", required=True, help="explicit semantic version, e.g. 0.0.1")
    parser.add_argument("--output", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    try:
        release = prepare(pathlib.Path(__file__).resolve().parent.parent, arguments.output, arguments.commit, arguments.version)
    except (KeyError, OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print("Release packaging failed: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps({"commit": release["commit"], "tag": release["tag"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
