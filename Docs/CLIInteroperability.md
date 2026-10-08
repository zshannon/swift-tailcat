# CLI interoperability boundary

Swift Tailcat uses official Tailcat's transport and address formats at commit **b4dc28e8aa8936f0a90a41ad8293a64e3d6b645f**. The [coverage matrix](Coverage.md) maps command behavior to Swift APIs. Typed `Tailcat.Listener`/`Tailcat.Connection` requests add the private framing described in [Messaging.md](Messaging.md); stock CLI byte streams do not speak that framing. The pinned stock `tailcat <address> <port>` stream mode is exercised by `stockCLIStreamInteroperability` against a Swift listener with an owned relay. Other stock CLI commands and system `ssh`, `scp`, or `sftp` combinations remain unverified.

| Official CLI role | Swift peer role | Shared protocol |
|---|---|---|
| `<tailcat-address> <port>` | Swift raw `Tailcat.TCPListener` or `Tailcat.Server.Handlers.tcp` | Official encrypted stream transport |
| `forward`, `socks` | Swift direct or exit-forwarded service | Same node/address and TCP/UDP routing |
| `ssh <address>` | `serveSSH` | SSH with configured public-key/no-auth policy |
| `cp`, `ls`, stock scp/sftp via Tailcat ProxyCommand | Rooted Swift file service | SFTP over SSH |
| `serve files`, `recv`, `serve ssh` | Swift native SSH/SFTP client | SSH/SFTP, with host-key pin supplied by host |
| `perf`, `serve perf` | Swift perf client/service | Official copied perf protocol |

Use the pinned official CLI for additional interoperability runs and an owned relay/map, temporary identities, and temporary file roots. Verify both client/server directions, host-key/auth behavior, all four file modes, chunked drop-box uploads and direct/relay perf gates. Record exact CLI revision, commands and results before marking it verified. Owned library-to-library tests do not establish stock CLI compatibility.

A Tailcat address includes preshared secret material. Saved identities require both the node private key and PSK. Current clients reject historical addresses without the required independent discovery key even when parsing succeeds. PSK disabling is an explicit legacy compatibility option and weakens protection; it does not promise support for every historical release.

Swift uses native SSH/SFTP, including portable protocol clients/file services on iOS. The official CLI executes system `ssh`/`scp`; their complete option sets are external-tool behavior rather than exported Tailcat Go API. The host supplies SSH private keys, a pinned host key, terminal I/O, user and endpoint/port. System SSH agent/config/known_hosts lookup and scp flags/progress formatting are not reproduced. Swift file helpers preserve supported timestamps/permission bits and reject top-level symlink inputs and recursively encountered symlink entries; they do not claim full scp parity.

CLI process concerns become host responsibilities: stdio piping, Ctrl-C, text/JSON formatting, browser opening, named key lookup, and timeouts. The live `Tailcat.Client.forwardTCP(bind:port:)` and `forwardTCP(bind:endpoint:)` APIs supply an HTTP URL for their host-local listener using the CLI formatting convention, even when the arbitrary TCP service does not speak HTTP. `Tailcat.Server.forward` supplies a tunnel mapping address and port without populating `url`. The host decides whether opening a browser for a client forward is appropriate. `Tailcat.DERPMap.region(matching:)` supplies code/name parsing, while the host formats region lists. `Tailcat.Identity.FileStore` reads/writes official identity JSON only in an explicit host-selected directory; it does not silently consume an existing CLI key. `Tailcat.Cache.FileStorage` preserves the CLI's paired JSON/ETag format in an explicit host directory. `lookup(name:resolver:)` explicitly resolves DNS TXT and returns origin metadata; use destination-aware `Tailcat.Session.openSSH(cache:configuration:derpMapURL:destination:permitPublicNoAuthentication:privateKey:)` to retain the public no-auth SSH safety guard. Never publish a no-auth shell address.

Shell/PTY/forced local commands, inetd exec services, and local commands through SOCKS work only on macOS. SSH/SFTP protocol clients and rooted file services are portable to iOS within its container/file access and lifecycle constraints. Device/simulator runtime execution and internet NAT behavior remain unverified.
