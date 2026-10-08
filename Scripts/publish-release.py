#!/usr/bin/env python3
"""Publish a built asset and a source-only URL/checksum package tag."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import runpy
import shutil
import subprocess
import sys
import tempfile

REPOSITORY = "zshannon/swift-tailcat"


def gh(*arguments, allow_missing=False, payload=None):
    result = subprocess.run(["gh", *arguments], capture_output=True, input=None if payload is None else json.dumps(payload), text=True)
    if result.returncode:
        if allow_missing and "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError("GitHub command failed: " + result.stderr.strip())
    result = json.loads(result.stdout) if arguments[0] == "api" and result.stdout.strip() else None
    if isinstance(result, dict) and result.get("errors"):
        raise RuntimeError("GitHub GraphQL returned errors; refusing to treat this as a missing release")
    return result


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def inventory(directory):
    release = json.loads((directory / "release.json").read_text())
    if not re.fullmatch(r"[0-9a-f]{40}", release["commit"]) or not release["tag"].startswith("v"):
        raise RuntimeError("Invalid release commit or tag")
    try:
        runpy.run_path(str(pathlib.Path(__file__).with_name("prepare-release.py")))["validate_version"](release["tag"][1:])
    except RuntimeError as error:
        raise RuntimeError("Invalid release tag") from error
    source_archive = "swift-tailcat-" + release["tag"] + ".zip"
    if release["source_archive"] != source_archive:
        raise RuntimeError("Unexpected source archive name")
    names = {"TailcatCore.xcframework.zip", "manifest.json", "release.json", source_archive}
    expected = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.+-]+)", line)
        if not match or match[2] not in names or match[2] in expected:
            raise RuntimeError("Invalid release checksum inventory")
        expected[match[2]] = match[1]
    if set(expected) != names:
        raise RuntimeError("Incomplete release checksum inventory")
    for name, digest in expected.items():
        if file_digest(directory / name) != digest:
            raise RuntimeError("Local asset checksum mismatch: " + name)
    expected["SHA256SUMS"] = file_digest(directory / "SHA256SUMS")
    return release, expected


def build_distribution(directory):
    script = pathlib.Path(__file__).with_name("prepare-release.py")
    return runpy.run_path(str(script))["distribution"](script.parent.parent, directory)


def verify_built_asset(directory):
    script = pathlib.Path(__file__).with_name("verify-artifact.py")
    subprocess.run([sys.executable, "-B", str(script), "--artifacts", str(directory)], check=True)


def adopt_build(directory, release, manifest):
    release["artifact_manifest"] = manifest
    (directory / "release.json").write_text(json.dumps(release, indent=2, sort_keys=True) + "\n")
    names = sorted(["TailcatCore.xcframework.zip", "manifest.json", "release.json", release["source_archive"]])
    (directory / "SHA256SUMS").write_text("".join(file_digest(directory / name) + "  " + name + "\n" for name in names))


def publish(directory, initial=False):
    release, expected = inventory(directory)
    source, tag = release["commit"], release["tag"]
    prefix = "repos/" + REPOSITORY
    if initial:
        ref = gh("api", prefix + "/git/ref/heads/main")
        if ref["object"]["type"] != "commit" or ref["object"]["sha"] != source:
            raise RuntimeError("Remote main differs from the reviewed initial source")
        remote_tree = gh("api", prefix + "/git/commits/" + source)["tree"]["sha"]
        if remote_tree != release["source_tree"]:
            raise RuntimeError("Remote main tree differs from the reviewed initial source")

    def check_tag(package_commit=None, required=False):
        ref = gh("api", prefix + "/git/ref/tags/" + tag, allow_missing=True)
        if ref is None:
            if required:
                raise RuntimeError("Published release tag is missing")
            return None
        if ref["object"]["type"] != "commit":
            raise RuntimeError("Existing tag is not the expected generated package commit")
        actual = ref["object"]["sha"]
        if package_commit is not None:
            if actual != package_commit:
                raise RuntimeError("Existing tag belongs to another package commit; refusing to replace it")
        elif actual != source:
            parents = gh("api", prefix + "/git/commits/" + actual)["parents"]
            if len(parents) != 1 or parents[0]["sha"] != source:
                raise RuntimeError("Existing tag does not derive from this source commit; refusing to replace it")
        return actual

    def find_release():
        remote = gh("api", prefix + "/releases/tags/" + tag, allow_missing=True)
        if remote is not None:
            return remote
        query = 'query($tag: String!) { repository(owner: "zshannon", name: "swift-tailcat") { release(tagName: $tag) { databaseId } } }'
        result = gh("api", "graphql", "-f", "query=" + query, "-f", "tag=" + tag)
        repository = result["data"]["repository"]
        if repository is None:
            raise RuntimeError("GitHub repository is inaccessible during draft lookup")
        pending = repository["release"]
        return None if pending is None else gh("api", prefix + "/releases/" + str(pending["databaseId"]))

    def verify_asset(asset, name):
        if asset["state"] != "uploaded" or asset["size"] != (directory / name).stat().st_size:
            raise RuntimeError("Remote asset is incomplete or has the wrong size: " + name)
        if asset.get("digest"):
            if asset["digest"] != "sha256:" + expected[name]:
                raise RuntimeError("Remote asset checksum mismatch: " + name)
        else:
            with tempfile.TemporaryDirectory(prefix="swift-tailcat-release-check-") as temporary:
                gh("release", "download", tag, "--dir", temporary, "--pattern", name, "--repo", REPOSITORY)
                if file_digest(pathlib.Path(temporary) / name) != expected[name]:
                    raise RuntimeError("Downloaded asset checksum mismatch: " + name)

    def ensure_asset(remote, name):
        asset = next((a for a in remote["assets"] if a["name"] == name), None)
        if asset is not None and asset["state"] == "starter" and remote["draft"]:
            gh("api", prefix + "/releases/assets/" + str(asset["id"]), "--method", "DELETE")
            asset = None
        if asset is not None:
            verify_asset(asset, name)
        elif remote["draft"]:
            gh("release", "upload", tag, str(directory / name), "--repo", REPOSITORY)
        else:
            raise RuntimeError("Published release is missing a required asset: " + name)

    tag_commit = check_tag(package_commit=source if initial else None, required=initial)
    remote = find_release()
    if remote is None:
        gh("release", "create", tag, "--draft", "--latest=false", "--notes-file", str(directory / "release-notes.md"), "--repo", REPOSITORY, "--target", source, "--title", "Swift Tailcat " + tag)
        remote = find_release()
    if remote is None:
        raise RuntimeError("Created draft is not yet visible; rerun to resume publication")
    target = remote["target_commitish"]
    if remote["tag_name"] != tag or (target != source and target != tag_commit):
        raise RuntimeError("Existing release belongs to another commit")
    assets = {asset["name"]: asset for asset in remote["assets"]}
    binary = assets.get("TailcatCore.xcframework.zip")
    provenance = assets.get("manifest.json")
    if binary is not None and binary["state"] == "uploaded":
        if provenance is None or provenance["state"] != "uploaded":
            raise RuntimeError("Uploaded binary has no complete provenance; refusing to replace or guess it")
        with tempfile.TemporaryDirectory(prefix="swift-tailcat-release-build-") as temporary:
            accepted = pathlib.Path(temporary)
            for name in ["manifest.json", "TailcatCore.xcframework.zip"]:
                gh("release", "download", tag, "--dir", temporary, "--pattern", name, "--repo", REPOSITORY)
                asset = assets[name]
                if asset["size"] != (accepted / name).stat().st_size or (asset.get("digest") and asset["digest"] != "sha256:" + file_digest(accepted / name)):
                    raise RuntimeError("Remote asset checksum or size mismatch: " + name)
            manifest = json.loads((accepted / "manifest.json").read_text())
            if initial and manifest != release["artifact_manifest"]:
                raise RuntimeError("Uploaded binary differs from the exact initial prepared payload")
            fields = set(release["artifact_manifest"]) - {"archive_bytes", "archive_sha256"}
            if {key: manifest.get(key) for key in fields} != {key: release["artifact_manifest"][key] for key in fields}:
                raise RuntimeError("Uploaded build provenance differs from the current pinned source/toolchain")
            if manifest["archive"] != "TailcatCore.xcframework.zip" or manifest["archive_bytes"] != (accepted / manifest["archive"]).stat().st_size or manifest["archive_sha256"] != file_digest(accepted / manifest["archive"]):
                raise RuntimeError("Uploaded binary differs from its provenance checksum")
            verify_built_asset(accepted)
            for name in ["manifest.json", "TailcatCore.xcframework.zip"]:
                shutil.copyfile(accepted / name, directory / name)
        adopt_build(directory, release, manifest)
        release, expected = inventory(directory)
    else:
        if not remote["draft"] or tag_commit not in {None, source}:
            raise RuntimeError("Published or tagged release is missing its complete binary/provenance pair")
        if binary is not None and binary["state"] != "starter":
            raise RuntimeError("Unexpected incomplete binary upload state")
        if binary is not None or provenance is not None:
            # Recheck before deleting draft-only metadata or an interrupted upload.
            current = find_release()
            if current is None or not current["draft"] or check_tag(required=initial) not in {None, source}:
                raise RuntimeError("Release became published or tagged; refusing to replace draft metadata")
            current_assets = {asset["name"]: asset for asset in current["assets"]}
            if current_assets.get("TailcatCore.xcframework.zip", {}).get("state") == "uploaded":
                raise RuntimeError("Binary completed concurrently; rerun to verify its provenance")
            for name in ["TailcatCore.xcframework.zip", "manifest.json"]:
                if name in current_assets:
                    gh("api", prefix + "/releases/assets/" + str(current_assets[name]["id"]), "--method", "DELETE")
            remote = find_release()
            if remote is None:
                raise RuntimeError("Draft is no longer visible; rerun to resume")
        # Provenance must be durable before accepting the binary on a later retry.
        ensure_asset(remote, "manifest.json")
    ensure_asset(remote, "TailcatCore.xcframework.zip")
    remote = find_release()
    if remote is None:
        raise RuntimeError("Release is no longer visible after binary upload")
    binary = next((a for a in remote["assets"] if a["name"] == "TailcatCore.xcframework.zip"), None)
    if binary is None or binary["state"] != "uploaded":
        raise RuntimeError("Binary asset is missing after upload")
    metadata = build_distribution(directory)
    package_commit = metadata["commit"]
    release, expected = inventory(directory)
    check_tag(package_commit=package_commit, required=initial or not remote["draft"])
    if remote["draft"] and tag_commit is None and package_commit != source:
        tree_payload = {"base_tree": metadata["base_tree"], "tree": [{"content": metadata["manifest"], "mode": "100644", "path": "Package.swift", "type": "blob"}]}
        tree = gh("api", prefix + "/git/trees", "--method", "POST", "--input", "-", payload=tree_payload)
        if tree["sha"] != metadata["tree"]:
            raise RuntimeError("GitHub distribution tree differs from the verified local tree")
        commit_payload = {"author": metadata["author"], "committer": metadata["author"], "message": metadata["message"], "parents": [source], "tree": tree["sha"]}
        created = gh("api", prefix + "/git/commits", "--method", "POST", "--input", "-", payload=commit_payload)
        if created["sha"] != package_commit:
            raise RuntimeError("GitHub distribution commit differs from the verified local commit")
    for name in sorted(expected):
        if name != "TailcatCore.xcframework.zip":
            ensure_asset(remote, name)
    if not remote["draft"]:
        return release
    remote = find_release()
    if remote is None:
        raise RuntimeError("Release is no longer visible before publication")
    assets = {asset["name"]: asset for asset in remote["assets"]}
    for name in sorted(expected):
        if name not in assets:
            raise RuntimeError("Release is missing a required asset: " + name)
        verify_asset(assets[name], name)
    check_tag(package_commit=package_commit, required=initial)
    gh("release", "edit", tag, "--draft=false", "--latest=false", "--notes-file", str(directory / "release-notes.md"), "--repo", REPOSITORY, "--target", package_commit)
    check_tag(package_commit=package_commit, required=True)
    return release


def validate_initial(directory):
    """Validate the reviewed first payload locally before any GitHub request."""
    release, expected = inventory(directory)
    root = pathlib.Path(__file__).resolve().parents[1]
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    tree = subprocess.check_output(["git", "rev-parse", "HEAD^{tree}"], cwd=root, text=True).strip()
    if (release["tag"] != "v0.0.1" or release.get("package_commit") != source or
            release["commit"] != source or release.get("source_tree") != tree):
        raise RuntimeError("Prepared initial release must be v0.0.1 at the exact reviewed source commit/tree")
    if subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"], cwd=root, text=True).strip():
        raise RuntimeError("Prepared initial release requires clean tracked source")
    verify_built_asset(directory)
    metadata = build_distribution(directory)
    if metadata["commit"] != source or inventory(directory)[1] != expected:
        raise RuntimeError("Prepared initial distribution differs from the reviewed source payload")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=pathlib.Path)
    parser.add_argument("--prepared-initial", action="store_true", help="publish the exact reviewed v0.0.1 payload after the coordinated main/tag reset")
    arguments = parser.parse_args()
    try:
        release = json.loads((arguments.directory / "release.json").read_text())
        if arguments.prepared_initial:
            validate_initial(arguments.directory)
        elif not (os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch" and os.environ.get("GITHUB_REF") == "refs/heads/main" and os.environ.get("GITHUB_REPOSITORY") == REPOSITORY and release["tag"] != "v0.0.1" and os.environ.get("GITHUB_SHA") == release["commit"] and "v" + os.environ.get("TAILCAT_RELEASE_VERSION", "") == release["tag"]):
            raise RuntimeError("Publishing is restricted to the exact trusted manual main release in " + REPOSITORY)
        release = publish(arguments.directory, initial=arguments.prepared_initial)
    except (KeyError, OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print("Release publication failed: " + str(error), file=sys.stderr)
        return 1
    print("Release verified: " + release["tag"] + " from " + release["commit"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
