#!/usr/bin/env python3
"""Propose one validated official Tailcat update; no releases or binary uploads."""
import argparse
import base64
import datetime
import json
import os
import pathlib
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = 'zshannon/swift-tailcat'
MODULE = 'github.com/tailscale/tailcat'
OFFICIAL = 'https://github.com/tailscale/tailcat'
# Exact occurrence counts form a small, explicit contract for duplicated pins.
REFERENCES = {
    'Scripts/environment.sh': (1, 1),
    'Bridge/go.mod': (0, 1),
    'Sources/Tailcat/Compatibility.swift': (1, 1),
    'Bridge/mobile/values.go': (1, 0),
    'Scripts/package-artifact.py': (1, 1),
    'Scripts/verify-upstream-copy.py': (0, 1),
    'README.md': (2, 1),
    'Docs/Design.md': (1, 1),
    'Docs/CLIInteroperability.md': (1, 0),
    'Bridge/internal/upstreamperf/PROVENANCE.md': (1, 0),
    'THIRD_PARTY_NOTICES.md': (0, 1),
    'Docs/DependencyInventory.json': (0, 1),
}
GENERATED = {'Bridge/go.mod', 'THIRD_PARTY_NOTICES.md', 'Docs/DependencyInventory.json'}
ALLOWED = set(REFERENCES) | {'Bridge/go.sum', 'Bridge/internal/upstreamperf/perf.go', 'Bridge/internal/upstreamperf/perf_test.go',
                             'Docs/Coverage.md', 'Docs/UpstreamAPI.json', 'Docs/UpstreamREADME.md'}
COVERAGE_PIN = re.compile(r'^Current installed pin and frozen README/API snapshots: \*\*([0-9a-f]{40})\*\*, module \*\*(v[^\s*]+)\*\*\.$', re.M)
COVERAGE_STATUS = re.compile(r'^Compatibility/matrix review status: .+$', re.M)
SHA = re.compile(r'[0-9a-f]{40}')


def run(root, args, **kwargs):
    return subprocess.check_output(args, cwd=root, text=True, **kwargs)


def api(method, endpoint, payload=None):
    token = os.environ.get('GITHUB_TOKEN')
    if not token:
        raise RuntimeError('GITHUB_TOKEN is required')
    url = 'https://api.github.com/graphql' if endpoint == '/graphql' else 'https://api.github.com/repos/' + REPOSITORY + endpoint
    request = urllib.request.Request(url,
                                    data=None if payload is None else json.dumps(payload).encode(),
                                    method=method,
                                    headers={'Authorization': 'Bearer ' + token,
                                             'Accept': 'application/vnd.github+json',
                                             'X-GitHub-Api-Version': '2026-03-10',
                                             'Content-Type': 'application/json',
                                             'User-Agent': 'swift-tailcat-updater'})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # Never print credentials or response contents.
        raise RuntimeError('GitHub ' + method + ' ' + endpoint + ' failed: HTTP ' + str(error.code)) from None


def branch(commit):
    return 'bot/tailcat-' + commit


def marker(commit):
    return '<!-- swift-tailcat-upstream:' + commit + ' -->'


def pins(root):
    environment = (root / 'Scripts/environment.sh').read_text()
    version = re.search(r'^TAILCAT_UPSTREAM_VERSION=(v[^\s]+)$', environment, re.M)
    commit = re.search(r'^TAILCAT_UPSTREAM_COMMIT=([0-9a-f]{40})$', environment, re.M)
    if not version or not commit:
        raise RuntimeError('Invalid recorded Tailcat pin')
    version, commit = version[1], commit[1]
    for name, (commits, versions) in REFERENCES.items():
        text = (root / name).read_text()
        if text.count(commit) != commits or text.count(version) != versions:
            raise RuntimeError('Inconsistent Tailcat pin references: ' + name)
    coverage_pin = COVERAGE_PIN.findall((root / 'Docs/Coverage.md').read_text())
    if coverage_pin != [(commit, version)]:
        raise RuntimeError('Inconsistent Tailcat pin references: Docs/Coverage.md')
    module = re.findall(r'^\s*github.com/tailscale/tailcat\s+(\S+)', (root / 'Bridge/go.mod').read_text(), re.M)
    inventory = [m['version'] for m in json.loads((root / 'Docs/DependencyInventory.json').read_text()) if m['module'] == MODULE]
    if module != [version] or inventory != [version]:
        raise RuntimeError('Inconsistent Tailcat module pin')
    return version, commit


def context(root):
    if os.environ.get('GITHUB_REPOSITORY') != REPOSITORY:
        raise RuntimeError('Updater is restricted to repository ' + REPOSITORY)
    if os.environ.get('GITHUB_EVENT_NAME') not in {'schedule', 'workflow_dispatch'}:
        raise RuntimeError('Updater requires schedule or manual dispatch')
    default = api('GET', '')['default_branch']
    if os.environ.get('GITHUB_REF') != 'refs/heads/' + default:
        raise RuntimeError('Updater requires the default branch')
    base = run(root, ['git', 'rev-parse', 'HEAD']).strip()
    if not SHA.fullmatch(base) or base != os.environ.get('GITHUB_SHA'):
        raise RuntimeError('Trigger and checkout commit disagree')
    if run(root, ['git', 'status', '--porcelain']).strip():
        raise RuntimeError('Updater requires a clean source checkout')
    return default, base


def proposals():
    """Find owned proposals across revisions, including closed/rejected targets."""
    owned = []
    page = 1
    while True:
        query = urllib.parse.urlencode({'page': page, 'per_page': 100, 'state': 'all'})
        prs = api('GET', '/pulls?' + query)
        for pr in prs:
            ref = pr['head']['ref']
            if not ref.startswith('bot/tailcat-'):
                continue
            if (pr['user']['login'] != 'github-actions[bot]' or
                    not SHA.fullmatch(ref.removeprefix('bot/tailcat-')) or
                    (pr['head'].get('repo') or {}).get('full_name') != REPOSITORY or
                    not re.search(r'<!-- swift-tailcat-upstream:[0-9a-f]{40} -->', pr.get('body') or '')):
                raise RuntimeError('Foreign or inconsistent updater branch/PR')
            owned.append(pr)
        if len(prs) < 100:
            break
        page += 1
    if sum(pr.get('state') == 'open' for pr in owned) > 1:
        raise RuntimeError('Multiple open updater PRs; maintainer review required')
    return owned


def proposed(commit):
    if any(marker(commit) in (pr.get('body') or '') for pr in proposals()):
        return True
    refs = api('GET', '/git/matching-refs/heads/' + branch(commit))
    if any(ref['ref'] == 'refs/heads/' + branch(commit) for ref in refs):
        raise RuntimeError('Updater branch already exists without a verified proposal; inspect it manually')
    return False


def check(root, state):
    default, base = context(root)
    version, old = pins(root)
    output = run(root, ['git', 'ls-remote', OFFICIAL + '.git', 'HEAD']).strip().split()
    if len(output) != 2 or output[1] != 'HEAD' or not SHA.fullmatch(output[0]):
        raise RuntimeError('Official HEAD did not resolve to one full hex SHA')
    target = output[0]
    if target == old or proposed(target):
        print('Official Tailcat unchanged or already proposed; skipped before Go setup/build.')
        return False
    state.write_text(json.dumps({'base': base, 'default': default, 'old_version': version,
                                 'old_commit': old, 'target': target}, sort_keys=True) + '\n')
    print('Frozen official Tailcat SHA: ' + target)
    return True


def regenerate(root, state):
    target = state['target']
    module = json.loads(run(root / 'Bridge', ['go', 'mod', 'download', '-json', MODULE + '@' + target]))
    origin = module.get('Origin', {})
    version = module.get('Version', '')
    if (module.get('Path') != MODULE or origin.get('VCS') != 'git' or
            origin.get('URL') != OFFICIAL or origin.get('Hash') != target or
            not re.fullmatch(r'v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?', version)):
        raise RuntimeError('Resolved Go module does not match the frozen official SHA')
    # Capture all replacements before go get changes the module pin.
    replacements = {name: (root / name).read_text().replace(state['old_commit'], target).replace(state['old_version'], version)
                    for name in REFERENCES if name not in GENERATED}
    official = pathlib.Path(module['Dir'])
    readme = (official / 'README.md').read_bytes()
    inventory = run(root, ['go', 'run', str(root / 'Scripts/upstream-api.go'), str(official)])
    coverage = (root / 'Docs/Coverage.md').read_text()
    coverage, count = COVERAGE_PIN.subn('Current installed pin and frozen README/API snapshots: **' + target +
                                       '**, module **' + version + '**.', coverage)
    coverage, status_count = COVERAGE_STATUS.subn('Compatibility/matrix review status: pending for the current installed pin.', coverage)
    if count != 1 or status_count != 1:
        raise RuntimeError('Invalid coverage snapshot/review status fields')
    replacements['Docs/Coverage.md'] = coverage
    perf = official / 'internal/perf'
    if {p.name for p in perf.iterdir() if p.is_file()} != {'perf.go', 'perf_test.go'}:
        raise RuntimeError('Official internal/perf layout changed; maintainer review required')
    copies = {name: (perf / name).read_bytes() for name in ['perf.go', 'perf_test.go']}
    run(root / 'Bridge', ['go', 'get', MODULE + '@' + version])
    run(root / 'Bridge', ['go', 'mod', 'tidy'])
    module_text = (root / 'Bridge/go.mod').read_text()
    if (not re.search(r'^go 1\.27\.1$', module_text, re.M) or
            not re.search(r'^\s*golang.org/x/mobile v0\.0\.0-20260908204917-8b95e45f8d3e(?:\s|$)', module_text, re.M) or
            re.search(r'^toolchain ', module_text, re.M)):
        raise RuntimeError('Pinned Go/mobile toolchain changed; maintainer review required')
    for name, text in replacements.items():
        (root / name).write_text(text)
    (root / 'Docs/UpstreamREADME.md').write_bytes(readme)
    (root / 'Docs/UpstreamAPI.json').write_text(inventory)
    for name, data in copies.items():
        (root / 'Bridge/internal/upstreamperf' / name).write_bytes(data)
    run(root, ['bash', 'Scripts/generate-notices.sh'])
    if pins(root) != (version, target):
        raise RuntimeError('Regenerated pin does not match the frozen target')
    run(root, ['python3', '-B', 'Scripts/verify-upstream-copy.py'])
    return version


def publish(root, base, default, target, version, changed):
    """Create one PR or fast-forward its verified bot branch without forcing refs.

    All blob payloads come from the reviewed local source commit. No git credentials
    or global config are needed; each HTTP operation uses the built-in token.
    """
    existing = next((pr for pr in proposals() if pr.get('state') == 'open'), None)
    parents = [base]
    if existing:
        head = existing['head']['sha']
        ref = existing['head']['ref']
        current = api('GET', '/git/ref/heads/' + urllib.parse.quote(ref, safe='/'))
        identity = api('GET', '/commits/' + head)
        if (not SHA.fullmatch(head) or current['object']['sha'] != head or
                existing['base']['ref'] != default or
                (identity.get('author') or {}).get('login') != 'github-actions[bot]' or
                (identity.get('committer') or {}).get('login') != 'github-actions[bot]'):
            raise RuntimeError('Updater branch changed or contains a foreign commit; inspect it manually')
        if head != base:
            parents.append(head)
    base_tree = api('GET', '/git/commits/' + base)['tree']['sha']
    tree = []
    for name in changed:
        mode = run(root, ['git', 'ls-files', '-s', '--', name]).split()[0]
        data = subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=root)
        blob = api('POST', '/git/blobs', {'content': base64.b64encode(data).decode(), 'encoding': 'base64'})['sha']
        tree.append({'path': name, 'mode': mode, 'type': 'blob', 'sha': blob})
    tree_sha = api('POST', '/git/trees', {'base_tree': base_tree, 'tree': tree})['sha']
    timestamp = run(root, ['git', 'show', '-s', '--format=%ct', 'HEAD']).strip()
    date = datetime.datetime.fromtimestamp(int(timestamp), datetime.timezone.utc).isoformat()
    identity = {'name': 'github-actions[bot]', 'email': '41898282+github-actions[bot]@users.noreply.github.com', 'date': date}
    commit = api('POST', '/git/commits', {'message': 'Update official Tailcat to ' + target,
                                       'tree': tree_sha, 'parents': parents, 'author': identity, 'committer': identity})['sha']
    body = (marker(target) + '\n\nUpdate official Tailcat to `' + target + '` (`' + version + '`).\n\n'
            'Regenerated module checksums, unmodified official internal/perf and provenance, notices and dependency inventory. '
            'Refreshed the exact official README and root exported-function/method inventory from the verified frozen module. '
            'The manually reviewed coverage-matrix baseline was retained. Compatibility/matrix review is pending for the new installed pin; '
            'passing validation does not establish a new manual coverage review. '
            'Validated Go race tests, five XCFramework architectures and artifact provenance, Swift architecture compilation, '
            'the full Swift local integration suite (including Quantum flows), and a fresh Swift-only consumer before creating this PR.\n\n'
            'GITHUB_TOKEN push events do not trigger normal CI; PR checks may require maintainer approval. '
            'Review upstream compatibility before merging. Runner-local binaries were not committed or uploaded. No release was published.\n\n'
            'Package.swift retains the previous public binary URL/checksum. These checks use TAILCAT_LOCAL_ARTIFACT=1 '
            'and the freshly rebuilt runner-local bridge. Merging this source PR does not deliver the upgraded bridge to normal SwiftPM consumers; '
            'that requires a separately reviewed manual release with its matching binary URL/checksum and provenance.')
    payload = {'body': body, 'title': 'Update official Tailcat to ' + target[:12]}
    if existing:
        # Atomic expected-head check also rejects a concurrent reset to an ancestor.
        mutation_id = 'swift-tailcat-upstream-' + target
        response = api('POST', '/graphql', {
            'query': 'mutation($input: UpdateRefsInput!) { updateRefs(input: $input) { clientMutationId } }',
            'variables': {'input': {
                'clientMutationId': mutation_id,
                'refUpdates': [{'afterOid': commit, 'beforeOid': existing['head']['sha'],
                                'force': False, 'name': 'refs/heads/' + existing['head']['ref']}],
                'repositoryId': api('GET', '')['node_id']}}})
        if response.get('errors') or ((response.get('data') or {}).get('updateRefs') or {}).get('clientMutationId') != mutation_id:
            raise RuntimeError('Atomic updater branch update failed; no PR metadata update')
        result = api('PATCH', '/pulls/' + str(existing['number']), payload)
        print('Updated source update PR: ' + result.get('html_url', existing['html_url']))
    else:
        # Atomic create: a branch appearing after preflight is never overwritten.
        api('POST', '/git/refs', {'ref': 'refs/heads/' + branch(target), 'sha': commit})
        payload.update({'base': default, 'head': branch(target)})
        result = api('POST', '/pulls', payload)
        print('Created source update PR: ' + result['html_url'])


def update(root, state_path):
    state = json.loads(state_path.read_text())
    default, base = context(root)
    if (state['base'] != base or state['default'] != default or
            not SHA.fullmatch(state['target']) or
            pins(root) != (state['old_version'], state['old_commit'])):
        raise RuntimeError('Frozen state no longer matches checkout/pins')
    if state['target'] == state['old_commit']:
        raise RuntimeError('Frozen target is unchanged')
    if proposed(state['target']):
        return
    version = regenerate(root, state)
    run(root, ['bash', 'Scripts/test-go.sh'])
    run(root, ['bash', 'Scripts/build-xcframework.sh'])
    run(root, ['python3', '-B', 'Scripts/verify-artifact.py'])
    run(root, ['bash', 'Scripts/check-platforms.sh'])
    run(root, ['bash', 'Scripts/test-swift.sh'])
    run(root, ['bash', 'Scripts/test-consumer.sh', '--working-tree-snapshot'])
    if pins(root) != (version, state['target']):
        raise RuntimeError('Validated pin no longer matches frozen target')
    changed = run(root, ['git', 'diff', '--name-only']).splitlines()
    deleted = run(root, ['git', 'diff', '--name-only', '--diff-filter=D']).splitlines()
    untracked = run(root, ['git', 'ls-files', '--others', '--exclude-standard']).splitlines()
    staged = run(root, ['git', 'diff', '--cached', '--name-only']).splitlines()
    tracked_artifacts = run(root, ['git', 'ls-files', 'Artifacts', '.build', '.build-tools']).splitlines()
    if not changed or set(changed) - ALLOWED or deleted or untracked or staged or tracked_artifacts:
        raise RuntimeError('Unexpected source changes or tracked binary/build files; no proposal')
    if run(root, ['git', 'rev-parse', 'HEAD']).strip() != base:
        raise RuntimeError('Validated checkout moved')
    if proposed(state['target']):
        return
    run(root, ['git', 'switch', '-c', branch(state['target'])])
    run(root, ['git', 'add', '--', *changed])
    run(root, ['git', '-c', 'user.name=github-actions[bot]',
               '-c', 'user.email=41898282+github-actions[bot]@users.noreply.github.com',
               'commit', '-m', 'Update official Tailcat to ' + state['target']])
    if run(root, ['git', 'status', '--porcelain']).strip():
        raise RuntimeError('Source checkout changed during commit; no proposal')
    publish(root, base, default, state['target'], version, changed)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['check', 'update'])
    parser.add_argument('--state', type=pathlib.Path, required=True, help='runner-temporary frozen state')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    try:
        if args.operation == 'check':
            ready = check(root, args.state)
            if os.environ.get('GITHUB_OUTPUT'):
                with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                    output.write('changed=' + str(ready).lower() + '\n')
        else:
            update(root, args.state)
    except (RuntimeError, subprocess.CalledProcessError, KeyError, ValueError) as error:
        raise SystemExit(str(error)) from None


if __name__ == '__main__':
    main()
