"""Offline updater tests with real temporary Git repos and controlled Go/HTTP boundaries."""
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[2]
NEW = 'a' * 40
VERSION = 'v0.7.1-0.20261001010101-' + NEW[:12]


class UpdateTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / 'Scripts/update-upstream.py'
        self.assertTrue(path.is_file(), 'Missing weekly updater implementation')
        spec = importlib.util.spec_from_file_location('update_upstream', path)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name) / 'repo'
        self.root.mkdir()
        archive = subprocess.check_output(['git', 'archive', 'HEAD'], cwd=ROOT)
        subprocess.run(['tar', '-xf', '-', '-C', str(self.root)], input=archive, check=True)
        # Exercise scoped working files even before the fix is committed.
        for name in ['Docs/Coverage.md', 'Docs/Design.md', 'Scripts/test-consumer.sh', 'Scripts/upstream-api.go']:
            if (ROOT / name).is_file():
                shutil.copy2(ROOT / name, self.root / name)
        self.git('init', '--initial-branch=main')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'Fixture')
        self.base = self.git('rev-parse', 'HEAD').strip()
        self.old = self.module.pins(self.root)[1]
        self.state = pathlib.Path(self.temporary.name) / 'state.json'
        self.calls = []
        self.upstream = pathlib.Path(self.temporary.name) / 'upstream'
        (self.upstream / 'internal/perf').mkdir(parents=True)
        for name in ['perf.go', 'perf_test.go']:
            (self.upstream / 'internal/perf' / name).write_bytes((self.root / 'Bridge/internal/upstreamperf' / name).read_bytes() + b'\n// changed official source\n')
        (self.upstream / 'README.md').write_bytes(b'# Changed official README\r\nFrozen fixture bytes.\r\n')
        (self.upstream / 'api.go').write_text('package tailcat\n\nfunc Added(value int) string { return "" }\n')
        self.real_api = self.module.api
        self.api_patch = patch.object(self.module, 'api', side_effect=self.api)
        self.api_patch.start()
        self.addCleanup(self.api_patch.stop)
        self.run_patch = patch.object(self.module, 'run', side_effect=self.command)
        self.run_patch.start()
        self.addCleanup(self.run_patch.stop)
        self.env_patch = patch.dict('os.environ', {'GITHUB_REPOSITORY': 'zshannon/swift-tailcat', 'GITHUB_REF': 'refs/heads/main', 'GITHUB_SHA': self.base, 'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_TOKEN': 'fixture-token'}, clear=False)
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        self.version = VERSION
        self.official = NEW
        self.prs = []
        self.foreign = False
        self.foreign_commit = False
        self.fail_validation = False
        self.module_hash = NEW

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, text=True, stderr=subprocess.DEVNULL)

    def api(self, method, endpoint, payload=None):
        self.calls.append((method, endpoint, payload))
        if endpoint == '':
            return {'default_branch': 'main', 'node_id': 'fixture-repository'}
        if endpoint == '/graphql':
            return {'data': {'updateRefs': {'clientMutationId': payload['variables']['input']['clientMutationId']}}}
        if endpoint.startswith('/pulls?'):
            query = self.module.urllib.parse.parse_qs(endpoint.split('?', 1)[1])
            head = query.get('head', [None])[0]
            return [pr for pr in self.prs if head is None or head == 'zshannon:' + pr['head']['ref']]
        if endpoint.startswith('/git/ref/heads/'):
            pr = next(pr for pr in self.prs if pr.get('state') == 'open')
            return {'object': {'sha': pr['head']['sha']}}
        if endpoint.startswith('/commits/'):
            return {'author': {'login': 'foreign' if self.foreign_commit else 'github-actions[bot]'},
                    'committer': {'login': 'github-actions[bot]'}}
        if endpoint.startswith('/git/matching-refs/'):
            return [{'ref': 'refs/heads/' + self.module.branch(NEW)}] if self.foreign else []
        if method == 'GET' and endpoint.startswith('/git/commits/'):
            return {'tree': {'sha': 'b' * 40}}
        if endpoint == '/git/refs':
            return {'ref': payload['ref']}
        if endpoint == '/pulls':
            return {'html_url': 'https://example.invalid/pr/1'}
        return {'sha': 'c' * 40}

    def command(self, root, args, **kwargs):
        self.calls.append(('run', args))
        if args[:2] == ['git', 'ls-remote']:
            return self.official + '\tHEAD\n'
        if args[:3] == ['go', 'mod', 'download']:
            return json.dumps({'Path': 'github.com/tailscale/tailcat', 'Version': self.version, 'Dir': str(self.upstream), 'Origin': {'VCS': 'git', 'URL': 'https://github.com/tailscale/tailcat', 'Hash': self.module_hash}})
        if args[:2] == ['go', 'get']:
            path = self.root / 'Bridge/go.mod'
            path.write_text(path.read_text().replace(self.module.pins(self.root)[0], self.version))
            (self.root / 'Bridge/go.sum').write_text('regenerated checksums\n')
            return ''
        if args[:2] == ['go', 'run']:
            environment = dict(os.environ, GO111MODULE='off', GOCACHE=str(pathlib.Path(tempfile.gettempdir()) / 'swift-tailcat-round4-parser-cache'),
                               GOPROXY='off', GOTOOLCHAIN='local', GOWORK='off')
            return subprocess.check_output(args, cwd=root, env=environment, stderr=subprocess.PIPE, text=True)
        if args[:2] == ['go', 'mod']:
            return ''
        if args and args[0] == 'bash':
            if self.fail_validation and args[1] == 'Scripts/test-go.sh':
                raise RuntimeError('validation failed')
            if args[1] == 'Scripts/generate-notices.sh':
                for name in ['THIRD_PARTY_NOTICES.md', 'Docs/DependencyInventory.json']:
                    path = self.root / name
                    path.write_text(path.read_text().replace(self.old_version, self.version))
            if args[1] == 'Scripts/build-xcframework.sh':
                (self.root / 'Artifacts').mkdir(exist_ok=True)
                (self.root / 'Artifacts/TailcatCore.xcframework.zip').write_bytes(b'ignored binary')
            return ''
        if args[:2] == ['python3', '-B']:
            return ''
        return subprocess.check_output(args, cwd=root, text=True, stderr=subprocess.DEVNULL, **kwargs)

    def check(self):
        self.old_version = self.module.pins(self.root)[0]
        return self.module.check(self.root, self.state)

    def test_final_checkout_pin_references_are_coherent(self):
        self.assertEqual(self.module.pins(ROOT), self.module.pins(self.root))

    def test_unchanged_skips_tooling_build_and_writes(self):
        self.official = self.old
        self.assertFalse(self.check())
        self.assertFalse(self.state.exists())
        self.assertFalse(any(c[0] != 'GET' and c[0] != 'run' for c in self.calls))
        self.assertFalse(any(c[0] == 'run' and c[1][0] in ['go', 'bash'] for c in self.calls))

    def test_changed_pin_regenerates_validates_and_proposes_source_only(self):
        self.assertTrue(self.check())
        self.module.update(self.root, self.state)
        self.assertEqual(self.module.pins(self.root), (VERSION, NEW))
        self.assertEqual((self.root / 'Bridge/internal/upstreamperf/perf.go').read_bytes(), (self.upstream / 'internal/perf/perf.go').read_bytes())
        self.assertNotIn('Artifacts/', self.git('ls-files'))
        self.assertEqual(self.git('rev-parse', 'main').strip(), self.base)
        post = [c for c in self.calls if c[0] == 'POST']
        self.assertEqual(sum(c[1] == '/pulls' for c in post), 1)
        self.assertEqual(sum(c[1] == '/git/refs' for c in post), 1)
        tree = next(c[2] for c in post if c[1] == '/git/trees')
        self.assertFalse(any(x['path'].startswith('Artifacts/') for x in tree['tree']))
        validation = [c[1][1] for c in self.calls if c[0] == 'run' and c[1][0] == 'bash']
        self.assertEqual(validation[-5:], ['Scripts/test-go.sh', 'Scripts/build-xcframework.sh', 'Scripts/check-platforms.sh', 'Scripts/test-swift.sh', 'Scripts/test-consumer.sh'])
        self.assertLess(next(i for i,c in enumerate(self.calls) if c[0] == 'run' and c[1][:2] == ['bash', 'Scripts/test-consumer.sh']), next(i for i,c in enumerate(self.calls) if c[0] == 'POST'))
        self.assertFalse(any(c[0] == 'run' and ('push' in c[1] or 'publish-release.py' in ' '.join(c[1])) for c in self.calls))

    def test_changed_evidence_refreshes_without_advancing_manual_review(self):
        old_api = (self.root / 'Docs/UpstreamAPI.json').read_bytes()
        old_readme = (self.root / 'Docs/UpstreamREADME.md').read_bytes()
        old_version = self.module.pins(self.root)[0]
        self.check()
        self.module.update(self.root, self.state)
        coverage = (self.root / 'Docs/Coverage.md').read_text()
        readme = (self.root / 'Docs/UpstreamREADME.md').read_bytes()
        inventory = (self.root / 'Docs/UpstreamAPI.json').read_bytes()
        print('Evidence fixture: stale README=' + str(readme == old_readme) +
              ', stale API=' + str(inventory == old_api) +
              ', falsely advanced baseline=' + str('The baseline is official Tailcat **' + NEW in coverage))
        with self.subTest(evidence='README'):
            self.assertEqual(readme, (self.upstream / 'README.md').read_bytes())
        with self.subTest(evidence='API'):
            self.assertEqual(json.loads(inventory), [{'file': 'api.go', 'line': 3, 'signature': 'func Added(value int) string'}])
        with self.subTest(evidence='review anchor'):
            self.assertIn('Manually reviewed matrix baseline: **' + self.old + '**, module **' + old_version + '**.', coverage)
            self.assertIn('Compatibility/matrix review status: pending for the current installed pin.', coverage)
            self.assertNotIn('The baseline is official Tailcat **' + NEW, coverage)
        with self.subTest(evidence='proposal'):
            tree = next(c[2]['tree'] for c in self.calls if c[:2] == ('POST', '/git/trees'))
            paths = {entry['path'] for entry in tree}
            self.assertTrue({'Docs/UpstreamAPI.json', 'Docs/UpstreamREADME.md'} <= paths)
            self.assertFalse(paths - self.module.ALLOWED)
            self.assertFalse(any(path.startswith(('Artifacts/', '.build/', '.build-tools/')) for path in paths))
            body = next(c[2]['body'] for c in self.calls if c[:2] == ('POST', '/pulls'))
            self.assertIn('Compatibility/matrix review is pending', body)
        # A second actual check/update must retain the original review anchor.
        self.base = self.git('rev-parse', 'HEAD').strip()
        os.environ['GITHUB_SHA'] = self.base
        self.calls.clear()
        self.official = self.module_hash = 'd' * 40
        self.version = 'v0.7.1-0.20261002020202-' + self.official[:12]
        (self.upstream / 'README.md').write_bytes(b'# Second frozen README\n')
        (self.upstream / 'api.go').write_text('package tailcat\nfunc Second() {}\n')
        self.check()
        self.module.update(self.root, self.state)
        coverage = (self.root / 'Docs/Coverage.md').read_text()
        self.assertEqual(self.module.pins(self.root), (self.version, self.official))
        self.assertIn('Manually reviewed matrix baseline: **' + self.old + '**, module **' + old_version + '**.', coverage)
        self.assertIn('Current installed pin and frozen README/API snapshots: **' + self.official + '**, module **' + self.version + '**.', coverage)
        self.assertEqual((self.root / 'Docs/UpstreamREADME.md').read_bytes(), (self.upstream / 'README.md').read_bytes())
        self.assertEqual(json.loads((self.root / 'Docs/UpstreamAPI.json').read_text()), [{'file': 'api.go', 'line': 2, 'signature': 'func Second()'}])
        self.assertNotIn('Artifacts/', self.git('ls-files'))

    def test_malformed_upstream_api_stops_before_regeneration_and_remote_writes(self):
        self.check()
        (self.upstream / 'api.go').write_text('package tailcat\nfunc Broken(\n')
        old_readme = (self.root / 'Docs/UpstreamREADME.md').read_bytes()
        with self.assertRaises(subprocess.CalledProcessError) as failure:
            self.module.update(self.root, self.state)
        self.assertIn('api.go', failure.exception.stderr)
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))
        self.assertFalse(any(c[0] == 'run' and c[1][:2] == ['go', 'get'] for c in self.calls))
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.base)
        self.assertEqual((self.root / 'Docs/UpstreamREADME.md').read_bytes(), old_readme)
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_invalid_coverage_snapshot_pin_fails_before_build_or_remote_writes(self):
        path = self.root / 'Docs/Coverage.md'
        path.write_text(path.read_text().replace('Current installed pin and frozen README/API snapshots: **' + self.old,
                                                'Current installed pin and frozen README/API snapshots: **' + 'f' * 40))
        self.check_coverage_failure()

    def check_coverage_failure(self):
        with self.assertRaisesRegex(RuntimeError, 'pin references: Docs/Coverage.md'):
            self.check()
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))
        self.assertFalse(any(c[0] == 'run' and c[1][0] in ['go', 'bash'] for c in self.calls))

    def test_missing_coverage_review_status_stops_before_regeneration_and_remote_writes(self):
        self.check()
        path = self.root / 'Docs/Coverage.md'
        path.write_text('\n'.join(line for line in path.read_text().splitlines() if not line.startswith('Compatibility/matrix review status:')) + '\n')
        # Freeze a clean fixture without the required status, then check/update it.
        self.git('add', 'Docs/Coverage.md')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'Missing review status fixture')
        self.base = self.git('rev-parse', 'HEAD').strip()
        os.environ['GITHUB_SHA'] = self.base
        self.check()
        with self.assertRaisesRegex(RuntimeError, 'review status fields'):
            self.module.update(self.root, self.state)
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))
        self.assertFalse(any(c[0] == 'run' and c[1][:2] == ['go', 'get'] for c in self.calls))
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.base)

    def test_identical_previously_closed_bot_pr_skips_build(self):
        self.prs = [{'user': {'login': 'github-actions[bot]'}, 'head': {'ref': self.module.branch(NEW), 'repo': {'full_name': 'zshannon/swift-tailcat'}}, 'body': self.module.marker(NEW)}]
        self.assertFalse(self.check())
        self.assertFalse(any(c[0] == 'run' and c[1][0] in ['go', 'bash'] for c in self.calls))

    def open_proposal(self, target):
        return {'number': 7, 'state': 'open', 'user': {'login': 'github-actions[bot]'},
                'head': {'ref': self.module.branch(target), 'sha': 'e' * 40,
                         'repo': {'full_name': 'zshannon/swift-tailcat'}},
                'base': {'ref': 'main'}, 'body': self.module.marker(target),
                'html_url': 'https://example.invalid/pr/7'}

    def test_advancing_head_updates_existing_open_bot_pr(self):
        existing = self.open_proposal('d' * 40)
        self.prs = [existing]
        self.assertTrue(self.check())
        self.module.update(self.root, self.state)
        self.assertFalse(any(c[:2] in [('POST', '/git/refs'), ('POST', '/pulls')] for c in self.calls))
        mutation = next(c[2]['variables']['input'] for c in self.calls if c[:2] == ('POST', '/graphql'))
        self.assertEqual(mutation['repositoryId'], 'fixture-repository')
        self.assertEqual(mutation['refUpdates'], [{'afterOid': 'c' * 40, 'beforeOid': existing['head']['sha'],
                                                  'force': False, 'name': 'refs/heads/' + existing['head']['ref']}])
        commit = next(c[2] for c in self.calls if c[:2] == ('POST', '/git/commits'))
        self.assertEqual(commit['parents'], [self.base, existing['head']['sha']])
        pr = next(c[2] for c in self.calls if c[:2] == ('PATCH', '/pulls/7'))
        self.assertIn(self.module.marker(NEW), pr['body'])
        self.assertEqual(pr['title'], 'Update official Tailcat to ' + NEW[:12])

    def test_same_target_on_reused_branch_skips_before_build(self):
        existing = self.open_proposal('d' * 40)
        existing['body'] = self.module.marker(NEW)
        self.prs = [existing]
        self.assertFalse(self.check())
        self.assertFalse(any(c[0] == 'run' and c[1][0] in ['go', 'bash'] for c in self.calls))

    def test_pr_body_explains_retained_binary_release_boundary(self):
        self.check()
        self.module.update(self.root, self.state)
        body = next(c[2]['body'] for c in self.calls if c[:2] == ('POST', '/pulls'))
        self.assertIn('Package.swift retains the previous public binary URL/checksum', body)
        self.assertIn('TAILCAT_LOCAL_ARTIFACT=1', body)
        self.assertIn('separately reviewed manual release', body)

    def test_concurrent_ref_reset_does_not_overwrite_or_update_pr(self):
        self.prs = [self.open_proposal('d' * 40)]
        self.check()
        original = self.api
        def raced(method, endpoint, payload=None):
            if endpoint == '/graphql':
                original(method, endpoint, payload)
                return {'errors': [{'message': 'beforeOid no longer matches after concurrent reset'}]}
            return original(method, endpoint, payload)
        with patch.object(self.module, 'api', side_effect=raced):
            with self.assertRaisesRegex(RuntimeError, 'Atomic updater branch update failed'):
                self.module.update(self.root, self.state)
        self.assertFalse(any(c[0] == 'PATCH' or c[:2] in [('POST', '/git/refs'), ('POST', '/pulls')] for c in self.calls))

    def test_foreign_commit_in_owned_bot_pr_is_not_overwritten(self):
        self.prs = [self.open_proposal('d' * 40)]
        self.foreign_commit = True
        self.check()
        with self.assertRaisesRegex(RuntimeError, 'foreign commit'):
            self.module.update(self.root, self.state)
        self.assertFalse(any(c[0] in {'PATCH', 'POST'} for c in self.calls))

    def test_multiple_open_bot_prs_stop_before_build(self):
        self.prs = [self.open_proposal('d' * 40), self.open_proposal('f' * 40)]
        with self.assertRaisesRegex(RuntimeError, 'Multiple open updater PRs'):
            self.check()
        self.assertFalse(any(c[0] == 'run' and c[1][0] in ['go', 'bash'] for c in self.calls))

    def test_foreign_branch_or_pr_is_never_overwritten(self):
        self.foreign = True
        with self.assertRaisesRegex(RuntimeError, 'branch'):
            self.check()
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))

    def test_mismatched_recorded_pin_fails_before_build(self):
        path = self.root / 'Sources/Tailcat/Compatibility.swift'
        path.write_text(path.read_text().replace(self.old, 'f' * 40))
        with self.assertRaisesRegex(RuntimeError, 'pin'):
            self.check()
        self.assertFalse(any(c[0] == 'run' and c[1][0] in ['go', 'bash'] for c in self.calls))

    def test_invalid_official_sha_is_rejected(self):
        self.official = 'a' * 12
        with self.assertRaisesRegex(RuntimeError, 'SHA'):
            self.check()

    def test_stale_state_or_wrong_target_fails_before_regeneration(self):
        self.check()
        data = json.loads(self.state.read_text())
        data['base'] = '0' * 40
        self.state.write_text(json.dumps(data))
        with self.assertRaisesRegex(RuntimeError, 'checkout'):
            self.module.update(self.root, self.state)
        with patch.dict('os.environ', {'GITHUB_REPOSITORY': 'foreign/repo'}):
            with self.assertRaisesRegex(RuntimeError, 'repository'):
                self.check()

    def test_resolved_go_origin_must_match_frozen_sha(self):
        self.check()
        self.module_hash = 'b' * 40
        with self.assertRaisesRegex(RuntimeError, 'frozen'):
            self.module.update(self.root, self.state)
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))

    def test_failed_validation_creates_no_branch_pr_or_commit(self):
        self.check()
        self.fail_validation = True
        with self.assertRaisesRegex(RuntimeError, 'validation failed'):
            self.module.update(self.root, self.state)
        self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.base)
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))

    def test_binary_or_wrapper_changes_abort_before_proposal(self):
        self.check()
        original = self.command
        def changed(root, args, **kwargs):
            output = original(root, args, **kwargs)
            if args[:2] == ['bash', 'Scripts/test-consumer.sh']:
                (self.root / 'Sources/Tailcat/Models.swift').write_text('unexpected API change')
            return output
        with patch.object(self.module, 'run', side_effect=changed):
            with self.assertRaisesRegex(RuntimeError, 'Unexpected'):
                self.module.update(self.root, self.state)
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))

    def test_non_default_dispatch_is_rejected(self):
        with patch.dict('os.environ', {'GITHUB_REF': 'refs/heads/feature'}):
            with self.assertRaisesRegex(RuntimeError, 'default branch'):
                self.check()
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))

    def test_foreign_pr_is_rejected(self):
        self.prs = [{'user': {'login': 'foreign'}, 'head': {'ref': self.module.branch(NEW), 'repo': {'full_name': 'zshannon/swift-tailcat'}}, 'body': self.module.marker(NEW)}]
        with self.assertRaisesRegex(RuntimeError, 'Foreign'):
            self.check()
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))

    def test_tracked_artifact_aborts_without_remote_writes(self):
        (self.root / 'Artifacts').mkdir()
        (self.root / 'Artifacts/binary.zip').write_bytes(b'bad tracked binary')
        self.git('add', '-f', 'Artifacts/binary.zip')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'Bad artifact')
        self.base = self.git('rev-parse', 'HEAD').strip()
        with patch.dict('os.environ', {'GITHUB_SHA': self.base}):
            self.check()
            with self.assertRaisesRegex(RuntimeError, 'tracked binary'):
                self.module.update(self.root, self.state)
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))

    def test_branch_creation_race_does_not_update_ref_or_create_pr(self):
        self.check()
        original = self.api
        def raced(method, endpoint, payload=None):
            if method == 'POST' and endpoint == '/git/refs':
                raise RuntimeError('GitHub POST /git/refs failed: HTTP 422')
            return original(method, endpoint, payload)
        with patch.object(self.module, 'api', side_effect=raced):
            with self.assertRaisesRegex(RuntimeError, 'HTTP 422'):
                self.module.update(self.root, self.state)
        self.assertFalse(any(c[0] == 'PATCH' or c[:2] == ('POST', '/pulls') for c in self.calls))

    def test_all_failed_validation_gates_prevent_remote_writes(self):
        # Each gate is independent: failing the final consumer must also stop publication.
        for gate in ['Scripts/test-go.sh', 'Scripts/build-xcframework.sh', 'Scripts/verify-artifact.py', 'Scripts/check-platforms.sh', 'Scripts/test-swift.sh', 'Scripts/test-consumer.sh']:
            with self.subTest(gate=gate):
                self.git('reset', '--hard', self.base)
                self.calls.clear()
                self.check()
                original = self.command
                def failed(root, args, **kwargs):
                    if gate in args:
                        raise RuntimeError('failed gate ' + gate)
                    return original(root, args, **kwargs)
                with patch.object(self.module, 'run', side_effect=failed):
                    with self.assertRaisesRegex(RuntimeError, 'failed gate'):
                        self.module.update(self.root, self.state)
                self.assertFalse(any(c[0] == 'POST' for c in self.calls))
                self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.base)

    def test_upstream_head_movement_keeps_the_frozen_sha(self):
        self.check()
        self.official = 'd' * 40
        self.module.update(self.root, self.state)
        self.assertEqual(self.module.pins(self.root), (VERSION, NEW))
        resolves = [c for c in self.calls if c[0] == 'run' and c[1][:2] == ['git', 'ls-remote']]
        self.assertEqual(len(resolves), 1)

    def test_unexpected_perf_layout_requires_manual_review(self):
        self.check()
        (self.upstream / 'internal/perf/new.go').write_text('new unsupported official layout')
        with self.assertRaisesRegex(RuntimeError, 'layout changed'):
            self.module.update(self.root, self.state)
        self.assertFalse(any(c[0] == 'POST' for c in self.calls))

    def test_http_boundary_uses_per_request_token_and_current_version(self):
        # No network: inspect the real urllib request, not a mocked api result.
        request = []
        class Response:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def read(self):
                return b'{"sha": "fixture"}'
        def opened(value, timeout):
            request.append(value)
            return Response()
        with patch.object(self.module, 'api', self.real_api):
            with patch.object(self.module.urllib.request, 'urlopen', side_effect=opened):
                self.module.api('POST', '/git/blobs', {'content': 'eA==', 'encoding': 'base64'})
        self.assertEqual(request[0].get_header('Authorization'), 'Bearer fixture-token')
        self.assertEqual(request[0].get_header('X-github-api-version'), '2026-03-10')
        self.assertEqual(request[0].full_url, 'https://api.github.com/repos/zshannon/swift-tailcat/git/blobs')

    def consume_without_native_build(self, args):
        # Execute the real helper; replace only its final native `env swift run`
        # boundary with an observer of the actual temporary dependency directory.
        tools = pathlib.Path(self.temporary.name) / 'consumer-tools'
        tools.mkdir(exist_ok=True)
        observed = pathlib.Path(self.temporary.name) / 'consumer-observed.json'
        observer = tools / 'env'
        observer.write_text('#!' + sys.executable + '\n' +
                            'import json, pathlib\n' +
                            'consumer = pathlib.Path.cwd()\n' +
                            'dependency = consumer.parent / "dependency"\n' +
                            'data = {"source": (dependency / "Sources/Tailcat/Compatibility.swift").read_text(), '
                            '"package": (consumer / "Package.swift").read_text(), '
                            '"untracked": (dependency / "untracked-sentinel.txt").exists(), '
                            '"binary": (dependency / "Artifacts/TailcatCore.xcframework.zip").read_text()}\n' +
                            'pathlib.Path(' + repr(str(observed)) + ').write_text(json.dumps(data))\n')
        observer.chmod(0o755)
        environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'])
        subprocess.run(args, cwd=self.root, env=environment, check=True, text=True, capture_output=True)
        return json.loads(observed.read_text())

    def test_fresh_consumer_receives_regenerated_source_before_bot_commit(self):
        self.check()
        original = self.command
        observed = []
        def consumed(root, args, **kwargs):
            if args[:2] == ['bash', 'Scripts/test-consumer.sh']:
                self.assertEqual(self.git('rev-parse', 'HEAD').strip(), self.base)
                self.assertFalse(any(c[0] == 'POST' for c in self.calls))
                observed.append(self.consume_without_native_build(args))
            return original(root, args, **kwargs)
        with patch.object(self.module, 'run', side_effect=consumed):
            self.module.update(self.root, self.state)
        self.assertEqual(len(observed), 1)
        self.assertIn(NEW, observed[0]['source'])
        self.assertIn(VERSION, observed[0]['source'])
        self.assertNotIn(self.old, observed[0]['source'])
        self.assertIn('.package(path: "../dependency")', observed[0]['package'])
        self.assertEqual(observed[0]['binary'], 'ignored binary')

    def test_consumer_default_still_uses_committed_source(self):
        path = self.root / 'Sources/Tailcat/Compatibility.swift'
        path.write_text(path.read_text().replace(self.old, NEW))
        (self.root / 'untracked-sentinel.txt').write_text('not part of snapshot')
        (self.root / 'Artifacts').mkdir()
        (self.root / 'Artifacts/TailcatCore.xcframework.zip').write_text('fixture binary')
        observed = self.consume_without_native_build(['bash', 'Scripts/test-consumer.sh'])
        self.assertIn(self.old, observed['source'])
        self.assertNotIn(NEW, observed['source'])
        self.assertFalse(observed['untracked'])
        self.assertEqual(observed['binary'], 'fixture binary')

    def test_consumer_snapshot_copies_tracked_working_source_only(self):
        path = self.root / 'Sources/Tailcat/Compatibility.swift'
        path.write_text(path.read_text().replace(self.old, NEW))
        (self.root / 'untracked-sentinel.txt').write_text('not part of snapshot')
        (self.root / 'Artifacts').mkdir()
        (self.root / 'Artifacts/TailcatCore.xcframework.zip').write_text('fixture binary')
        observed = self.consume_without_native_build(['bash', 'Scripts/test-consumer.sh', '--working-tree-snapshot'])
        self.assertIn(NEW, observed['source'])
        self.assertNotIn(self.old, observed['source'])
        self.assertFalse(observed['untracked'])
        self.assertEqual(observed['binary'], 'fixture binary')


if __name__ == '__main__':
    unittest.main()
