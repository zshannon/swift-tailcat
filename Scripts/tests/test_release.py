"""Offline release tests: real Git archives and a simulated GitHub CLI boundary."""
import hashlib
import importlib.util
import json
import os
import sys
import pathlib
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]


def load_script(name):
    path = ROOT / "Scripts" / name
    assert path.is_file(), "Missing release implementation: " + name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.module = load_script("prepare-release.py")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name) / "repo"
        self.root.mkdir()
        self.output = pathlib.Path(self.temporary.name) / "release"
        (self.root / ".gitignore").write_text("Artifacts/\n")
        for name in ["Artifacts", "Bridge/mobile", "Bridge/internal/upstreamperf", "Sources/Tailcat"]:
            (self.root / name).mkdir(parents=True)
        for name in ["Bridge/build-tags.txt", "Bridge/go.mod", "Bridge/go.sum", "Bridge/internal/upstreamperf/perf.go", "Bridge/mobile/api.go", "LICENSE", "THIRD_PARTY_NOTICES.md", "README.md", "Sources/Tailcat/API.swift"]:
            (self.root / name).write_text(name + "\n")
        (self.root / "Package.swift").write_text('.binaryTarget(name: "TailcatCore", url: "https://github.com/zshannon/swift-tailcat/releases/download/v9.9.9/TailcatCore.xcframework.zip", checksum: "' + "0" * 64 + '")\n')
        with zipfile.ZipFile(self.root / "Artifacts/TailcatCore.xcframework.zip", "w") as archive:
            archive.writestr("TailcatCore.xcframework/LICENSE", "license")
        digest = hashlib.sha256()
        names = ["Bridge/build-tags.txt", "Bridge/go.mod", "Bridge/go.sum", "Bridge/internal/upstreamperf/perf.go", "Bridge/mobile/api.go"]
        for name in sorted(names):
            digest.update(name.encode() + b"\0" + (self.root / name).read_bytes())
        binary = (self.root / "Artifacts/TailcatCore.xcframework.zip").read_bytes()
        manifest = {"archive": "TailcatCore.xcframework.zip", "archive_bytes": len(binary), "archive_sha256": hashlib.sha256(binary).hexdigest(), "bridge_source_sha256": digest.hexdigest(), "tailcat_commit": "b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f"}
        (self.root / "Artifacts/manifest.json").write_text(json.dumps(manifest))
        self.git("init", "--initial-branch=main")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "user.name", "Release fixture")
        self.git("add", ".")
        self.git("commit", "-m", "Fixture")
        self.commit = self.git("rev-parse", "HEAD").strip()

    def prepare(self, root, output, expected_commit=None, version="0.0.1"):
        return self.module.prepare(root, output, expected_commit, version=version)

    def git(self, *args):
        return subprocess.check_output(["git", *args], cwd=self.root, text=True, stderr=subprocess.DEVNULL)

    def test_archives_only_exact_committed_files_and_measures_every_asset(self):
        (self.root / "credentials.txt").write_text("excluded untracked sentinel")
        release = self.prepare(self.root, self.output, self.commit)
        self.assertEqual(release["commit"], self.commit)
        self.assertEqual(release["tag"], "v0.0.1")
        with zipfile.ZipFile(self.output / release["source_archive"]) as archive:
            names = set(archive.namelist())
            self.assertIn("swift-tailcat/Package.swift", names)
            self.assertIn("releases/download/v0.0.1/TailcatCore.xcframework.zip", archive.read("swift-tailcat/Package.swift").decode())
            self.assertIn(release["artifact_manifest"]["archive_sha256"], archive.read("swift-tailcat/Package.swift").decode())
            self.assertIn("swift-tailcat/LICENSE", names)
            self.assertIn("swift-tailcat/THIRD_PARTY_NOTICES.md", names)
            self.assertNotIn("swift-tailcat/Artifacts/TailcatCore.xcframework.zip", names)
            self.assertNotIn("swift-tailcat/credentials.txt", names)
            self.assertFalse(any("/.git/" in name for name in names))
        lines = (self.output / "SHA256SUMS").read_text().splitlines()
        self.assertEqual(len(lines), 4)
        for line in lines:
            digest, name = line.split("  ")
            self.assertEqual(digest, hashlib.sha256((self.output / name).read_bytes()).hexdigest())

    def test_repeat_packaging_is_byte_identical(self):
        self.prepare(self.root, self.output, self.commit)
        first = {p.name: p.read_bytes() for p in self.output.iterdir()}
        self.prepare(self.root, self.output, self.commit)
        self.assertEqual(first, {p.name: p.read_bytes() for p in self.output.iterdir()})

    def test_rejects_dirty_tracked_files(self):
        (self.root / "README.md").write_text("uncommitted")
        with self.assertRaisesRegex(RuntimeError, "clean"):
            self.prepare(self.root, self.output, self.commit)

    def test_rejects_wrong_checkout(self):
        with self.assertRaisesRegex(RuntimeError, "commit"):
            self.prepare(self.root, self.output, "0" * 40)

    def test_rejects_stale_manifest(self):
        (self.root / "Bridge/mobile/api.go").write_text("changed production source")
        self.git("add", ".")
        self.git("commit", "-m", "Source without rebuild")
        with self.assertRaisesRegex(RuntimeError, "bridge"):
            self.prepare(self.root, self.output)

    def test_rejects_corrupt_generated_binary(self):
        with (self.root / "Artifacts/TailcatCore.xcframework.zip").open("ab") as archive:
            archive.write(b"changed")
        with self.assertRaisesRegex(RuntimeError, "archive"):
            self.prepare(self.root, self.output)

    def test_rejects_any_generated_artifact_in_git_history(self):
        self.git("add", "--force", "Artifacts/TailcatCore.xcframework.zip")
        self.git("commit", "-m", "Wrongly tracked build output")
        with self.assertRaisesRegex(RuntimeError, "artifact"):
            self.prepare(self.root, self.output)
        self.git("rm", "--cached", "Artifacts/TailcatCore.xcframework.zip")
        self.git("commit", "-m", "Remove output without cleaning history")
        with self.assertRaisesRegex(RuntimeError, "artifact"):
            self.prepare(self.root, self.output)

    def test_distribution_commit_contains_remote_manifest_and_no_binary(self):
        self.assertTrue(callable(getattr(self.module, "distribution", None)), "Missing remote distribution manifest generation")
        self.prepare(self.root, self.output, self.commit)
        metadata = self.module.distribution(self.root, self.output)
        package_commit = metadata["commit"]
        manifest = self.git("show", package_commit + ":Package.swift")
        self.assertIn("https://github.com/zshannon/swift-tailcat/releases/download/v0.0.1/TailcatCore.xcframework.zip", manifest)
        self.assertIn("checksum:", manifest)
        self.assertNotIn("path:", manifest)
        self.assertEqual(self.git("rev-parse", package_commit + "^").strip(), self.commit)
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), self.commit)
        self.assertNotIn("Artifacts/", self.git("ls-tree", "-r", "--name-only", package_commit))
        repeated = self.module.distribution(self.root, self.output)
        self.assertEqual(repeated["commit"], package_commit)
        with zipfile.ZipFile(self.output / "swift-tailcat-v0.0.1.zip") as archive:
            self.assertEqual(archive.read("swift-tailcat/Package.swift").decode(), manifest)

    def test_explicit_versions_are_independent_of_commit_count(self):
        for version in ["0.0.1", "2.3.4", "1.0.0-rc.1", "1.2.3+build.4"]:
            with self.subTest(version=version):
                release = self.prepare(self.root, self.output, self.commit, version=version)
                self.assertEqual(release["tag"], "v" + version)
        for version in [None, "", "v0.0.1", "01.0.1", "1.2", "1.2.3-01", "1.2.3/evil"]:
            with self.subTest(version=version), self.assertRaisesRegex(RuntimeError, "version"):
                self.prepare(self.root, self.output, self.commit, version=version)

    def test_matching_distribution_manifest_preserves_exact_source_commit(self):
        release = self.prepare(self.root, self.output, self.commit)
        (self.root / "Package.swift").write_text(self.git("show", release["package_commit"] + ":Package.swift"))
        self.git("add", "Package.swift")
        self.git("commit", "-m", "Reviewed public distribution manifest")
        source = self.git("rev-parse", "HEAD").strip()
        release = self.prepare(self.root, self.output, source)
        self.assertEqual(release["package_commit"], source)
        metadata = self.module.distribution(self.root, self.output)
        self.assertEqual(metadata["commit"], source)
        self.assertIsNone(metadata["parent"])


class PublishingTests(unittest.TestCase):
    def setUp(self):
        self.module = load_script("publish-release.py")
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.commit = "a" * 40
        self.main_commit = self.commit
        self.tag = "v0.1.2"
        release = {"commit": self.commit, "source_tree": "b" * 40, "source_archive": "swift-tailcat-v0.1.2.zip", "tag": self.tag}
        for name in ["manifest.json", "swift-tailcat-v0.1.2.zip", "TailcatCore.xcframework.zip"]:
            (self.root / name).write_bytes(name.encode())
        self.manifest = {"archive": "TailcatCore.xcframework.zip", "archive_bytes": (self.root / "TailcatCore.xcframework.zip").stat().st_size, "archive_sha256": hashlib.sha256((self.root / "TailcatCore.xcframework.zip").read_bytes()).hexdigest(), "bridge_source_sha256": "e" * 64, "tailcat_commit": "f" * 40}
        release["artifact_manifest"] = self.manifest
        (self.root / "manifest.json").write_text(json.dumps(self.manifest))
        (self.root / "release.json").write_text(json.dumps(release))
        names = ["manifest.json", "release.json", "swift-tailcat-v0.1.2.zip", "TailcatCore.xcframework.zip"]
        (self.root / "SHA256SUMS").write_text("".join(hashlib.sha256((self.root / n).read_bytes()).hexdigest() + "  " + n + "\n" for n in names))
        (self.root / "release-notes.md").write_text("Fixture notes")
        self.calls = []
        self.remote = None
        self.tag_commit = None
        self.stored = {}
        self.fail_upload = False
        self.read_error = False
        self.package_commit = "d" * 40
        self.distribution_metadata = {"author": {"date": "2026-01-01T00:00:00Z", "email": "bot@example.invalid", "name": "Fixture"}, "base_tree": "b" * 40, "commit": self.package_commit, "manifest": "remote manifest", "message": "Release fixture\n", "parent": self.commit, "tree": "c" * 40}
        self.gh_patch = patch.object(self.module, "gh", self.fake_gh)
        self.gh_patch.start()
        self.addCleanup(self.gh_patch.stop)
        self.distribution_patch = patch.object(self.module, "build_distribution", self.fake_distribution, create=True)
        self.distribution_patch.start()
        self.addCleanup(self.distribution_patch.stop)
        self.verifier_patch = patch.object(self.module, "verify_built_asset", create=True)
        self.verifier = self.verifier_patch.start()
        self.addCleanup(self.verifier_patch.stop)

    def change_fresh_build(self):
        binary = self.root / "TailcatCore.xcframework.zip"
        binary.write_bytes(b"same source with a different build timestamp")
        candidate = dict(self.manifest, archive_bytes=binary.stat().st_size, archive_sha256=hashlib.sha256(binary.read_bytes()).hexdigest())
        (self.root / "manifest.json").write_text(json.dumps(candidate))
        release = json.loads((self.root / "release.json").read_text())
        release["artifact_manifest"] = candidate
        (self.root / "release.json").write_text(json.dumps(release))
        names = ["manifest.json", "release.json", release["source_archive"], "TailcatCore.xcframework.zip"]
        (self.root / "SHA256SUMS").write_text("".join(hashlib.sha256((self.root / n).read_bytes()).hexdigest() + "  " + n + "\n" for n in sorted(names)))

    def test_published_retry_reuses_verified_pair_after_a_different_fresh_build(self):
        self.module.publish(self.root)
        accepted = dict(self.stored)
        self.change_fresh_build()
        self.calls.clear()
        release = self.module.publish(self.root)
        self.assertEqual((self.root / "TailcatCore.xcframework.zip").read_bytes(), accepted["TailcatCore.xcframework.zip"])
        self.assertEqual(release["artifact_manifest"], self.manifest)
        self.verifier.assert_called()
        self.assertFalse(any(c[0] == "release" and c[1] in {"create", "edit", "upload"} for c in self.calls))
        self.assertFalse(any(c[0] == "api" and "--method" in c for c in self.calls))

    def test_draft_retry_reuses_uploaded_pair_after_a_different_fresh_build(self):
        with patch.object(self.module, "build_distribution", side_effect=RuntimeError("interrupted after binary")):
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                self.module.publish(self.root)
        self.assertTrue(self.remote["draft"])
        self.assertEqual(set(self.stored), {"TailcatCore.xcframework.zip", "manifest.json"})
        self.change_fresh_build()
        self.module.publish(self.root)
        self.assertFalse(self.remote["draft"])
        self.assertEqual((self.root / "TailcatCore.xcframework.zip").read_bytes(), self.stored["TailcatCore.xcframework.zip"])

    def test_manifest_only_draft_can_replace_metadata_before_binary_upload(self):
        self.remote = {"assets": [], "draft": True, "tag_name": self.tag, "target_commitish": self.commit}
        self.fake_gh("release", "upload", self.tag, str(self.root / "manifest.json"), "--repo", "zshannon/swift-tailcat")
        self.change_fresh_build()
        self.module.publish(self.root)
        self.assertFalse(self.remote["draft"])
        self.assertTrue(any(c[0] == "api" and c[-2:] == ("--method", "DELETE") for c in self.calls))

    def test_uploaded_binary_without_provenance_fails_before_mutation(self):
        self.module.publish(self.root)
        self.remote["draft"] = True
        self.tag_commit = None
        self.remote["target_commitish"] = self.commit
        self.remote["assets"] = [a for a in self.remote["assets"] if a["name"] != "manifest.json"]
        self.calls.clear()
        with self.assertRaisesRegex(RuntimeError, "provenance"):
            self.module.publish(self.root)
        self.assertFalse(any(c[0] == "release" and c[1] in {"create", "edit", "upload"} for c in self.calls))

    def test_reused_pair_must_match_current_source_provenance(self):
        self.module.publish(self.root)
        self.change_fresh_build()
        release = json.loads((self.root / "release.json").read_text())
        release["artifact_manifest"]["tailcat_commit"] = "0" * 40
        (self.root / "release.json").write_text(json.dumps(release))
        inventory = self.root / "SHA256SUMS"
        inventory.write_text("".join(hashlib.sha256((self.root / name).read_bytes()).hexdigest() + "  " + name + "\n" for name in ["manifest.json", "release.json", release["source_archive"], "TailcatCore.xcframework.zip"]))
        self.calls.clear()
        with self.assertRaisesRegex(RuntimeError, "provenance"):
            self.module.publish(self.root)
        self.assertFalse(any(c[0] == "api" and "--method" in c for c in self.calls))

    def test_wrong_remote_git_object_leaves_release_unpublished(self):
        for endpoint in ["/git/trees", "/git/commits"]:
            with self.subTest(endpoint=endpoint):
                self.remote, self.tag_commit, self.stored, self.calls = None, None, {}, []
                original = self.module.gh
                def wrong_sha(*args, **kwargs):
                    result = original(*args, **kwargs)
                    if args[0] == "api" and args[1].endswith(endpoint):
                        result["sha"] = "0" * 40
                    return result
                with patch.object(self.module, "gh", side_effect=wrong_sha):
                    with self.assertRaisesRegex(RuntimeError, "differs from the verified local"):
                        self.module.publish(self.root)
                self.assertTrue(self.remote["draft"])
                self.assertIsNone(self.tag_commit)
                self.assertFalse(any(c[:2] == ("release", "edit") for c in self.calls))

    def fake_distribution(self, directory):
        release = json.loads((directory / "release.json").read_text())
        release.update({"binary_url": "https://github.com/zshannon/swift-tailcat/releases/download/" + release["tag"] + "/TailcatCore.xcframework.zip", "package_commit": self.package_commit})
        (directory / "release.json").write_text(json.dumps(release, indent=2, sort_keys=True) + "\n")
        (directory / release["source_archive"]).write_bytes(b"source-only distribution")
        names = ["manifest.json", "release.json", release["source_archive"], "TailcatCore.xcframework.zip"]
        (directory / "SHA256SUMS").write_text("".join(hashlib.sha256((directory / n).read_bytes()).hexdigest() + "  " + n + "\n" for n in sorted(names)))
        return self.distribution_metadata

    def fake_gh(self, *args, allow_missing=False, payload=None):
        self.calls.append(args)
        if args[0] == "api":
            path = args[1]
            if self.read_error:
                raise RuntimeError("API network/403 error")
            if path == "graphql":
                pending = None if self.remote is None else {"databaseId": 1}
                return {"data": {"repository": {"release": pending}}}
            if path.endswith("/git/ref/heads/main"):
                return {"object": {"type": "commit", "sha": self.main_commit}}
            if "/git/commits/" in path:
                owner = self.commit if path.endswith(self.package_commit) else "b" * 40
                return {"parents": [{"sha": owner}], "tree": {"sha": "b" * 40}}
            if path.endswith("/git/trees"):
                self.assertEqual(payload["tree"][0]["content"], "remote manifest")
                return {"sha": self.distribution_metadata["tree"]}
            if path.endswith("/git/commits"):
                self.assertEqual(payload["parents"], [self.commit])
                return {"sha": self.package_commit}
            if "/git/ref/tags/" in path:
                return None if self.tag_commit is None else {"object": {"sha": self.tag_commit, "type": "commit"}}
            if "/releases/tags/" in path:
                return self.remote if self.remote is not None and not self.remote["draft"] else None
            if path.endswith("/releases/1"):
                return self.remote
            if args[-2:] == ("--method", "DELETE"):
                self.remote["assets"] = [a for a in self.remote["assets"] if str(a["id"]) != path.rsplit("/", 1)[-1]]
                return None
            raise AssertionError(args)
        operation, tag = args[1:3]
        self.assertEqual(tag, self.tag)
        if operation == "create":
            self.assertIn("--draft", args)
            self.assertEqual(args[args.index("--target") + 1], self.commit)
            self.remote = {"assets": [], "draft": True, "tag_name": tag, "target_commitish": self.commit}
        elif operation == "upload":
            path = pathlib.Path(args[3])
            if self.fail_upload:
                self.fail_upload = False
                self.remote["assets"].append({"id": 99, "name": path.name, "size": 0, "state": "starter"})
                raise RuntimeError("upload interrupted")
            data = path.read_bytes()
            self.stored[path.name] = data
            self.remote["assets"].append({"digest": "sha256:" + hashlib.sha256(data).hexdigest(), "id": len(self.remote["assets"]) + 1, "name": path.name, "size": len(data), "state": "uploaded"})
        elif operation == "download":
            name = args[args.index("--pattern") + 1]
            destination = pathlib.Path(args[args.index("--dir") + 1])
            (destination / name).write_bytes(self.stored[name])
        elif operation == "edit":
            self.assertEqual(len(self.remote["assets"]), 5)
            self.remote["draft"] = False
            self.assertEqual(args[args.index("--target") + 1], self.package_commit)
            self.remote["target_commitish"] = self.package_commit
            self.tag_commit = self.package_commit
        else:
            raise AssertionError(args)
        return None

    def test_creates_draft_then_publishes_after_all_five_assets(self):
        self.module.publish(self.root)
        self.assertFalse(self.remote["draft"])
        operations = [c[1] for c in self.calls if c[0] == "release"]
        self.assertEqual(operations, ["create"] + ["upload"] * 5 + ["edit"])
        self.assertTrue(any(c[:2] == ("api", "graphql") for c in self.calls))
        self.assertEqual(self.tag_commit, self.package_commit)
        self.assertEqual(list(self.stored)[:2], ["manifest.json", "TailcatCore.xcframework.zip"])

    def test_retry_of_published_release_performs_no_mutations(self):
        self.module.publish(self.root)
        self.calls.clear()
        self.module.publish(self.root)
        self.assertFalse(any(c[0] == "release" and c[1] in ["create", "edit", "upload"] for c in self.calls))

    def test_interrupted_upload_stays_draft_and_retry_recovers_starter(self):
        self.fail_upload = True
        with self.assertRaisesRegex(RuntimeError, "interrupted"):
            self.module.publish(self.root)
        self.assertTrue(self.remote["draft"])
        self.module.publish(self.root)
        self.assertFalse(self.remote["draft"])
        self.assertTrue(any(c[-2:] == ("--method", "DELETE") for c in self.calls))

    def test_conflicting_tag_stops_without_remote_writes(self):
        self.tag_commit = "b" * 40
        with self.assertRaisesRegex(RuntimeError, "tag"):
            self.module.publish(self.root)
        self.assertFalse(any(c[0] == "release" for c in self.calls))

    def test_api_failure_never_becomes_a_create(self):
        self.read_error = True
        with self.assertRaisesRegex(RuntimeError, "API"):
            self.module.publish(self.root)
        self.assertFalse(any(c[0] == "release" for c in self.calls))

    def test_corrupt_published_asset_is_never_overwritten(self):
        self.module.publish(self.root)
        self.remote["assets"][0]["digest"] = "sha256:" + "0" * 64
        self.calls.clear()
        with self.assertRaisesRegex(RuntimeError, "asset"):
            self.module.publish(self.root)
        self.assertFalse(any(c[0] == "release" and c[1] in ["create", "edit", "upload"] for c in self.calls))

    def test_missing_published_asset_is_a_failure(self):
        self.module.publish(self.root)
        self.remote["assets"].pop()
        with self.assertRaisesRegex(RuntimeError, "missing"):
            self.module.publish(self.root)

    def test_without_api_digest_compares_downloaded_bytes(self):
        self.module.publish(self.root)
        for asset in self.remote["assets"]:
            asset.pop("digest")
        self.calls.clear()
        self.module.publish(self.root)
        downloaded = {c[c.index("--pattern") + 1] for c in self.calls if c[:2] == ("release", "download")}
        self.assertEqual(downloaded, set(self.stored))

    def test_corrupt_local_asset_stops_before_any_remote_call(self):
        (self.root / "TailcatCore.xcframework.zip").write_bytes(b"corrupt")
        with self.assertRaisesRegex(RuntimeError, "Local asset"):
            self.module.publish(self.root)
        self.assertEqual(self.calls, [])

    def test_conflicting_draft_commit_stops_before_upload(self):
        self.remote = {"assets": [], "draft": True, "tag_name": self.tag, "target_commitish": "b" * 40}
        with self.assertRaisesRegex(RuntimeError, "another commit"):
            self.module.publish(self.root)
        self.assertFalse(any(c[0] == "release" for c in self.calls))

    def prepare_initial_payload(self):
        release = json.loads((self.root / "release.json").read_text())
        old_archive = release["source_archive"]
        self.tag = "v0.0.1"
        self.package_commit = self.commit
        self.distribution_metadata.update(commit=self.commit, parent=None)
        release.update(tag=self.tag, package_commit=self.commit, source_archive="swift-tailcat-v0.0.1.zip")
        (self.root / old_archive).rename(self.root / release["source_archive"])
        (self.root / "release.json").write_text(json.dumps(release))
        names = ["manifest.json", "release.json", release["source_archive"], "TailcatCore.xcframework.zip"]
        (self.root / "SHA256SUMS").write_text("".join(hashlib.sha256((self.root / n).read_bytes()).hexdigest() + "  " + n + "\n" for n in names))

    def test_initial_absent_source_tag_stops_before_any_mutation(self):
        self.prepare_initial_payload()
        with self.assertRaisesRegex(RuntimeError, "tag is missing"):
            self.module.publish(self.root, initial=True)
        self.assertFalse(any(c[0] == "release" or "--method" in c for c in self.calls))

    def test_initial_tag_disappearance_stops_mutations_at_each_later_checkpoint(self):
        self.prepare_initial_payload()
        for checkpoint, tag_check in [("draft cleanup", 2), ("package after binary", 2), ("final pre-edit", 3)]:
            with self.subTest(checkpoint=checkpoint):
                self.remote, self.stored, self.calls = None, {}, []
                self.tag_commit = self.commit
                if checkpoint == "draft cleanup":
                    self.remote = {"assets": [], "draft": True, "tag_name": self.tag, "target_commitish": self.commit}
                    self.fake_gh("release", "upload", self.tag, str(self.root / "manifest.json"), "--repo", "zshannon/swift-tailcat")
                    self.calls.clear()
                original = self.fake_gh
                checks = 0
                observed_missing_at = []
                def vanished(*args, **kwargs):
                    nonlocal checks
                    if args[0] == "api" and "/git/ref/tags/" in args[1]:
                        checks += 1
                        if checks == tag_check:
                            self.tag_commit = None
                    result = original(*args, **kwargs)
                    if args[0] == "api" and "/git/ref/tags/" in args[1] and result is None:
                        observed_missing_at.append(len(self.calls))
                    return result
                with patch.object(self.module, "gh", side_effect=vanished):
                    with self.assertRaisesRegex(RuntimeError, "tag is missing"):
                        self.module.publish(self.root, initial=True)
                self.assertEqual(len(observed_missing_at), 1)
                subsequent = self.calls[observed_missing_at[0]:]
                self.assertFalse(any(c[0] == "release" and c[1] in {"create", "upload", "edit"} or "--method" in c for c in subsequent))
                self.assertTrue(self.remote["draft"])
                self.assertIsNone(self.tag_commit)

    def test_initial_reviewed_source_tag_publishes_without_extra_commit(self):
        self.prepare_initial_payload()
        self.tag_commit = self.commit
        self.module.publish(self.root, initial=True)
        self.assertEqual(self.tag_commit, self.commit)
        self.assertFalse(any(c[0] == "api" and "--method" in c for c in self.calls))

    def test_initial_remote_main_mismatch_stops_before_draft_mutation(self):
        self.main_commit = "f" * 40
        with self.assertRaisesRegex(RuntimeError, "main"):
            self.module.publish(self.root, initial=True)
        self.assertFalse(any(c[0] == "release" or "--method" in c for c in self.calls))

    def test_initial_conflicting_child_tag_stops_before_draft_creation(self):
        self.tag_commit = self.package_commit
        with self.assertRaisesRegex(RuntimeError, "tag"):
            self.module.publish(self.root, initial=True)
        self.assertFalse(any(c[0] == "release" or "--method" in c for c in self.calls))

    def test_initial_retry_rejects_different_uploaded_binary(self):
        self.package_commit = self.commit
        self.distribution_metadata.update(commit=self.commit, parent=None)
        self.module.publish(self.root)
        self.change_fresh_build()
        self.calls.clear()
        with self.assertRaisesRegex(RuntimeError, "initial"):
            self.module.publish(self.root, initial=True)
        self.assertFalse(any(c[0] == "release" and c[1] in {"create", "edit", "upload"} for c in self.calls))

    def test_invalid_release_version_stops_before_remote_call(self):
        release = json.loads((self.root / "release.json").read_text())
        release["tag"] = "v01.2.3"
        (self.root / "release.json").write_text(json.dumps(release))
        with self.assertRaisesRegex(RuntimeError, "tag"):
            self.module.publish(self.root)
        self.assertEqual(self.calls, [])


class GitHubBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.module = load_script("publish-release.py")

    def test_only_explicit_404_is_treated_as_missing(self):
        for message, missing in [("gh: Not Found (HTTP 404)", True), ("gh: Forbidden (HTTP 403)", False), ("error connecting to api.github.com", False)]:
            with self.subTest(message=message), patch.object(self.module.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "", message)):
                if missing:
                    self.assertIsNone(self.module.gh("api", "repos/example/release", allow_missing=True))
                else:
                    with self.assertRaises(RuntimeError):
                        self.module.gh("api", "repos/example/release", allow_missing=True)

    def test_graphql_errors_are_not_missing_releases(self):
        response = subprocess.CompletedProcess([], 0, '{"data": {"repository": null}, "errors": [{"message": "Forbidden"}]}', "")
        with patch.object(self.module.subprocess, "run", return_value=response):
            with self.assertRaisesRegex(RuntimeError, "GraphQL"):
                self.module.gh("api", "graphql", "-f", "query=fixture")

    def test_publication_main_guard_requires_manual_matching_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            (directory / "release.json").write_text(json.dumps({"commit": "a" * 40, "tag": "v0.0.2"}))
            trusted = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REF": "refs/heads/main", "GITHUB_REPOSITORY": "zshannon/swift-tailcat", "GITHUB_SHA": "a" * 40, "TAILCAT_RELEASE_VERSION": "0.0.2"}
            with patch.object(sys, "argv", ["publish-release.py", str(directory)]), patch.object(self.module, "publish", return_value={"commit": "a" * 40, "tag": "v0.0.2"}) as publish:
                with patch.dict(os.environ, trusted, clear=True):
                    self.assertEqual(self.module.main(), 0)
                for overrides in [{"GITHUB_EVENT_NAME": "push"}, {"TAILCAT_RELEASE_VERSION": "0.0.3"}, {"GITHUB_REF": "refs/heads/feature"}, {"GITHUB_SHA": "b" * 40}]:
                    with patch.dict(os.environ, dict(trusted, **overrides), clear=True):
                        self.assertEqual(self.module.main(), 1)
                (directory / "release.json").write_text(json.dumps({"commit": "a" * 40, "tag": "v0.0.1"}))
                with patch.dict(os.environ, dict(trusted, TAILCAT_RELEASE_VERSION="0.0.1"), clear=True):
                    self.assertEqual(self.module.main(), 1)
                self.assertEqual(publish.call_count, 1)

    def test_initial_mode_requires_exact_reviewed_source_and_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            release = {"commit": "a" * 40, "package_commit": "a" * 40, "source_tree": "b" * 40, "tag": "v0.0.1"}
            expected = {"release.json": "b" * 64}
            with patch.object(self.module, "inventory", return_value=(release, expected)), patch.object(self.module.subprocess, "check_output", side_effect=lambda args, **kwargs: "" if "status" in args else ("b" * 40 if "HEAD^{tree}" in args else "a" * 40)), patch.object(self.module, "build_distribution", return_value={"commit": release["commit"]}), patch.object(self.module, "verify_built_asset"):
                self.module.validate_initial(directory)
                for key, value in [("tag", "v0.0.2"), ("package_commit", "c" * 40), ("commit", "c" * 40), ("source_tree", "c" * 40)]:
                    with patch.dict(release, {key: value}):
                        with self.assertRaisesRegex(RuntimeError, "initial|source"):
                            self.module.validate_initial(directory)


class WorkflowTests(unittest.TestCase):
    def test_all_owned_workflows_select_local_artifact_for_validation(self):
        for name in ["release.yml", "verify.yml", "update-upstream.yml"]:
            raw = subprocess.check_output(["ruby", "-rjson", "-ryaml", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", str(ROOT / ".github/workflows" / name)], text=True)
            job = next(iter(json.loads(raw)["jobs"].values()))
            self.assertEqual(job["env"]["TAILCAT_LOCAL_ARTIFACT"], "1")

    def test_apple_jobs_use_existing_fleet_routing_and_selected_xcode(self):
        for name in ["release.yml", "verify.yml"]:
            with self.subTest(workflow=name):
                path = ROOT / ".github/workflows" / name
                raw = subprocess.check_output(["ruby", "-rjson", "-ryaml", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", str(path)], text=True)
                job = next(iter(json.loads(raw)["jobs"].values()))
                self.assertEqual(job["runs-on"], "macos-xl", "Match the verified Crayon/Slick fleet scale-set label")
                self.assertNotIn("DEVELOPER_DIR", job.get("env", {}), "Use the fleet image's selected Xcode like Crayon/Slick")

    def test_both_build_workflows_install_pinned_go_without_saving_cache(self):
        for name in ["release.yml", "verify.yml"]:
            with self.subTest(workflow=name):
                path = ROOT / ".github/workflows" / name
                raw = subprocess.check_output(["ruby", "-rjson", "-ryaml", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", str(path)], text=True)
                workflow = json.loads(raw)
                steps = next(iter(workflow["jobs"].values()))["steps"]
                setup = [(index, step) for index, step in enumerate(steps) if step.get("uses", "").startswith("actions/setup-go@")]
                self.assertEqual(len(setup), 1, "A fresh hosted runner needs an explicit Go toolchain")
                index, step = setup[0]
                self.assertRegex(step["uses"], r"^actions/setup-go@[a-f0-9]{40}$")
                self.assertEqual(step["with"]["go-version"], "1.27.1")
                self.assertFalse(step["with"]["cache"])
                self.assertLess(index, next(i for i, value in enumerate(steps) if "Scripts/build-xcframework.sh" in value.get("run", "") or "Scripts/test-go.sh" in value.get("run", "")))

    def test_manual_version_gate_minimal_permissions_and_no_actions_storage(self):
        path = ROOT / ".github/workflows/release.yml"
        self.assertTrue(path.is_file(), "Missing main release workflow")
        raw = subprocess.check_output(["ruby", "-rjson", "-ryaml", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", str(path)], text=True)
        workflow = json.loads(raw)
        self.assertEqual(set(workflow["on"]), {"workflow_dispatch"})
        version = workflow["on"]["workflow_dispatch"]["inputs"]["version"]
        self.assertTrue(version["required"])
        self.assertEqual(version["type"], "string")
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        self.assertFalse(workflow["concurrency"]["cancel-in-progress"])
        self.assertIn("inputs.version", workflow["concurrency"]["group"])
        jobs = workflow["jobs"]
        self.assertEqual(set(jobs), {"release"})
        self.assertEqual(jobs["release"]["permissions"], {"contents": "write"})
        self.assertIn("zshannon/swift-tailcat", jobs["release"]["if"])
        self.assertIn("refs/heads/main", jobs["release"]["if"])
        self.assertIn("workflow_dispatch", jobs["release"]["if"])
        self.assertEqual(jobs["release"]["env"]["TAILCAT_LOCAL_ARTIFACT"], "1")
        runs = [s.get("run", "") for s in jobs["release"]["steps"]]
        self.assertIn("Scripts/build-xcframework.sh", runs)
        self.assertLess(runs.index("Scripts/build-xcframework.sh"), next(i for i, r in enumerate(runs) if "publish-release.py" in r))
        for job in jobs.values():
            for step in job["steps"]:
                if "uses" in step:
                    self.assertRegex(step["uses"], r"^actions/(checkout|setup-go)@[a-f0-9]{40}$")
                    if step["uses"].startswith("actions/checkout@"):
                        self.assertEqual(step["with"]["ref"], "${{ github.sha }}")
                        self.assertEqual(step["with"]["fetch-depth"], 0)
                        self.assertFalse(step["with"]["persist-credentials"])
        content = path.read_text()
        self.assertNotIn("upload-artifact", content)
        self.assertNotIn("actions/cache", content)
        self.assertNotIn("git push", content)


class ManifestTests(unittest.TestCase):
    def test_default_remote_and_explicit_local_modes(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=temporary, SWIFTPM_MODULECACHE_OVERRIDE=temporary)
            for mode in [None, "0", "1"]:
                with self.subTest(mode=mode):
                    environment.pop("TAILCAT_LOCAL_ARTIFACT", None)
                    if mode is not None:
                        environment["TAILCAT_LOCAL_ARTIFACT"] = mode
                    command = ["swift", "package", "--disable-sandbox", "--cache-path", temporary + "/cache", "--config-path", temporary + "/config", "--security-path", temporary + "/security", "dump-package"]
                    output = subprocess.check_output(command, cwd=ROOT, env=environment, text=True)
                    target = next(t for t in json.loads(output)["targets"] if t["name"] == "TailcatCore")
                    if mode == "1":
                        self.assertEqual(target["path"], "Artifacts/TailcatCore.xcframework.zip")
                        self.assertNotIn("url", target)
                    else:
                        self.assertEqual(target["url"], "https://github.com/zshannon/swift-tailcat/releases/download/v0.0.1/TailcatCore.xcframework.zip")
                        self.assertEqual(target["checksum"], "313571de2f27aa8a7e6f071bf9b748b1f557c179d9ac4f363888d0cd8f5cf687")
                        self.assertNotIn("path", target)


if __name__ == "__main__":
    unittest.main()
