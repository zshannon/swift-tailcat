# Explicit releases

The package on `main` downloads `https://github.com/zshannon/swift-tailcat/releases/download/v0.0.1/TailcatCore.xcframework.zip` with the measured SHA-256. Maintainer mode `TAILCAT_LOCAL_ARTIFACT=1` selects the ignored local artifact. No Go tools or private binary credentials are needed by consumers. Add the package with `branch: "main"`, as shown in the README.

## Prepare locally

First build and validate a matching artifact as described in the [README maintainer checks](../README.md#maintainer-verification-and-releases). `TAILCAT_LOCAL_ARTIFACT=1` selects that artifact for SwiftPM; it does not create it. From clean reviewed source with the matching ignored artifact and provenance:

```sh
python3 -B Scripts/verify-artifact.py
python3 -B Scripts/prepare-release.py --version 0.0.1 --commit "$(git rev-parse HEAD)" --output /tmp/swift-tailcat-v0.0.1
(cd /tmp/swift-tailcat-v0.0.1 && shasum -a 256 -c SHA256SUMS)
```

Versions are explicit semantic versions, independent of commit counts. Preparation verifies the exact checkout, clean tracked source, full artifact-free ancestry, bridge fingerprint, archive size/checksum, then generates the deterministic tag URL/checksum distribution locally. If the manifest already matches, `package_commit` equals the source commit; otherwise a deterministic local child changes only `Package.swift`. No ref is moved by preparation. Repeating preparation in the same output directory is supported and rewrites the named payload files; keep one directory per version/candidate so unrelated old files cannot be confused with the five-asset inventory. Publication retries use the unchanged prepared directory. The source ZIP contains the actual distribution manifest, all committed source, license/notices and `Docs/DependencyInventory.json`, with no binary, inspection logs, Git metadata or untracked files.

The five release assets are `TailcatCore.xcframework.zip`, `swift-tailcat-v0.0.1.zip`, `manifest.json`, `release.json` and `SHA256SUMS` (substitute later versions in the source ZIP name). `release.json` records exact source/tree/package identities and binary provenance. Source ZIP timestamps and stored compression are deterministic for a fixed commit. Separate Go builds may have different bytes; each release uses its measured checksum.

## First 0.0.1 boundary

Prepare the distribution source tree before the coordinated initial main/tag reset. The reviewed parentless main and `v0.0.1` must identify the same source tree and commit, including the measured public manifest. Reset/ref actions require their own exact review and are outside these scripts. Once that exact candidate is checked out, regenerate the payload with the preparation command above: `commit == package_commit == reviewed HEAD`, and the source ZIP identifies that candidate. Copy the already verified ignored artifact into that checkout; do not rebuild the first payload.

After the separately approved remote main/tag action, publish that exact prepared directory explicitly from the clean candidate checkout:

```sh
python3 -B Scripts/publish-release.py --prepared-initial /tmp/swift-tailcat-v0.0.1
```

This command performs publication. It is limited to v0.0.1, verifies clean HEAD/source/tree/package equality, validates the measured artifact and unchanged prepared inventory, and requires remote main commit/tree and an already existing lightweight `v0.0.1` tag to equal the prepared source commit before creating or resuming a draft. It does not create the initial tag. A missing, annotated or conflicting tag stops publication. It uses the maintainer's existing GitHub CLI authorization; no credential installation or forged workflow environment is required. It rechecks tag existence before draft-only recovery mutations when needed, after binary upload and package verification, immediately before publication, and after publication. Missing tags fail at every check; the package checks also require the exact prepared commit. Upload provenance before the binary, then the remaining source/checksum assets, verify every remote asset and exact tag, and publish only after all checks pass. The manual hosted release workflow rejects 0.0.1 so it cannot silently replace this reviewed payload with a fresh rebuild or a different package child.

## Later manual releases

Dispatch [Manual release](../.github/workflows/release.yml) on reviewed main with an explicit version other than 0.0.1. Main pushes do not publish. The bounded existing `macos-xl` job checks out the exact event SHA, builds pinned inputs, validates artifact metadata, all five Swift targets, Go race tests, Swift integration and a fresh consumer, then prepares and publishes. Only the built-in workflow token receives `contents: write`; there are no extra credentials, uploads to Actions storage, persistent caches, automatic releases or automatic merges. Hosting requires the existing fleet selection to permit this repository; no job is enabled or run by local preparation.

If the URL/checksum changes, publication verifies a locally generated package child against GitHub's created tree/commit before tagging it. Main remains the reviewed source commit. Tag URLs do not depend on returned asset IDs.

## Weekly official upstream updates

The [updater](../.github/workflows/update-upstream.yml) checks official `tailscale/tailcat` HEAD every Tuesday at 04:23 UTC and accepts manual dispatch on the default branch. It freezes the full official SHA before installing Go. Unchanged revisions and previously proposed revisions, including closed proposals, skip the rebuild. If an owned bot PR remains open when HEAD advances, the updater refreshes its branch, title and body; it keeps one open update PR. Foreign branches/commits, inconsistent proposals or multiple open updater PRs require maintainer review. Existing branches advance without force and use GitHub's [atomic expected-head check](https://docs.github.com/en/graphql/reference/git#updaterefs); concurrent ref changes fail instead of overwriting them.

For a new revision it resolves the Go module back to the frozen official origin/SHA, updates module checksums, duplicated pin references, copied official perf code/tests and provenance, dependency notices/inventory, and exact official README/API snapshots. The manually reviewed coverage baseline remains unchanged; compatibility review is marked pending. Unexpected upstream layout or pinned Go/mobile toolchain changes stop the update for manual review.

Before creating or updating the PR, the job runs Go race tests, rebuilds all five XCFramework architectures, verifies binary provenance/notices/architecture metadata, compiles and links Swift for all five targets, runs the full owned-loopback Swift suite, and checks a fresh Swift-only consumer against the regenerated working source. Offline updater/release tests run before regeneration. A failed gate creates no branch or PR.

This is a source update, not a release. `Package.swift` retains the previous public binary URL/checksum while these maintainer checks explicitly use `TAILCAT_LOCAL_ARTIFACT=1` and the freshly rebuilt runner-local binary. Merging an updater PR does not deliver the upgraded bridge to ordinary SwiftPM consumers. A separately reviewed manual release must publish the matching binary, package URL/checksum and provenance. Binaries remain outside Git and are neither uploaded to Actions storage nor published by this updater.

Operational prerequisites are the existing `macos-xl` fleet route with compatible Swift/Xcode, permitted pinned checkout/setup-go actions, and the built-in workflow token's job-scoped `contents: write` and `pull-requests: write`. Repository policy must permit [GitHub Actions to create pull requests](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#preventing-github-actions-from-creating-or-approving-pull-requests). The updater installs no extra credential, expands no repository/fleet setting, and uses no persistent Actions cache or artifact storage. Token-created pushes do not trigger ordinary CI, so validation runs directly before proposal; additional PR checks may require approval. There is no automatic merge or publication. These behaviors are locally tested with controlled Go/GitHub boundaries; a hosted scheduled run has not been verified.

## Retry and immutable payloads

Publication creates a draft before uploading assets and completes all assets before publishing. Conflicting commits/tags/assets, wrong sizes/checksums, incomplete inventories and non-404 API failures stop the operation. Published releases are verified without mutations; their assets are never replaced or deleted. Draft lookup uses REST and GraphQL; failed drafts can be retried with the same prepared directory.

Later rebuild retries may reuse an already uploaded binary/provenance pair after validating the complete source/toolchain provenance and actual artifact. The initial prepared mode additionally requires identical parsed manifest values, including binary size and SHA-256, plus the matching binary checksum. It does not require the downloaded manifest JSON to have the same whitespace or key order as the original local file. Accepted manifest bytes are adopted locally and the inventory is regenerated. An uploaded binary without complete provenance fails closed. An untagged draft, or the initial exact-source tag, may recover interrupted `starter` uploads before the binary completes, with state rechecked before draft-only deletion. No completed binary is overwritten.

Local verification uses mocked remote calls only:

```sh
python3 -B -m unittest discover -s Scripts/tests -v
```

Local builds/tests establish source and artifact behavior, not hosted workflow success or public URL availability. After publication, verify consumption from a fresh directory:

1. Download the five release assets from the published version, then run `shasum -a 256 -c SHA256SUMS` in that directory. Use public unauthenticated download URLs to establish public availability.
2. In another empty directory, create the exact README `Package.swift` and `Sources/Demo/main.swift`. Use the README’s `branch: "main"` dependency.
3. Run `env -u TAILCAT_LOCAL_ARTIFACT swift run Demo` on macOS. Confirm SwiftPM downloads/verifies the release binary and the demo prints `Hello, Sam!`, then `1`, `2`, and `3`. The unchanged README program uses default networking. Owned relay/runtime checks belong to the explicit maintainer fixtures and do not establish public default-network consumption.
4. Record the release tag, source/package commit, asset checksums, toolchain and command results before claiming hosted consumption verified.

No postpublication consumer check has been established by these local preparation instructions. Runtime coverage remains macOS arm64 owned loopback; physical devices, simulator runtime, macOS Intel runtime and internet NAT traversal remain unverified.
