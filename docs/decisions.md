# Decisions

Each entry: the question, what was tested, the result, the decision.

## D1. Toolchain: Command Line Tools only (2026-10-10)

- The development Mac has no Xcode. SwiftPM builds the SwiftUI app per architecture with `--triple`; `lipo` merges them; the bundle is assembled by `scripts/build-app.sh`.
- swift-testing works with extra search paths and `-disable-cross-import-overlays` (`scripts/test.sh`).
- SDK 26.2 is available, so Liquid Glass (`glassEffect`) compiles; it is used behind `#available(macOS 26, *)` with a material fallback for 14–15.

## D2. No Apple Developer account (2026-10-10)

- Distribution: an un-notarized disk image from GitHub Releases. macOS asks once to confirm opening it (System Settings › Privacy & Security › Open Anyway, or `xattr -dr com.apple.quarantine`).
- The helper is not registered with `SMAppService`: that runs a root daemon from inside the app bundle, which an admin user can modify without a password. Instead the app installs the helper and sing-box into root-owned `/Library` paths after an administrator password prompt, and writes the LaunchDaemon plist itself.
- XPC client check without a Team ID: the app and helper are signed with a local self-signed code-signing certificate; the helper requires its client to be signed by the same leaf certificate (`certificate leaf = H"…"`). Verified: `codesign --verify -R` accepts such a requirement for an untrusted self-signed identity.

## D3. Kill switch: pf matches sing-box's sockets by group — variant A (2026-10-10)

Experiment: `experiments/pf-group/run.sh` (run with sudo, safe with another VPN up). macOS 15.8, Intel. Rules in a `com.apple/` sub-anchor: `pass out quick on en0 proto {tcp udp} to T group 4242`, then `block` for the same target. Probes leave through en0 with `IP_BOUND_IF`, as sing-box's direct outbound does.

| Credentials | TCP | UDP connected | UDP unconnected (quic-go style) |
|---|---|---|---|
| root, egid 0 | blocked | blocked | blocked |
| root, egid 4242 | **pass** | **pass** | **pass** |
| nobody, egid 4242 | pass | pass | pass |
| root, egid 0, supplementary 4242 | blocked | blocked | blocked |
| uid 501, staff | blocked | blocked | blocked |
| real sing-box 1.13.16, egid 4242 (DNS over UDP) | — | pass | — |
| real sing-box, egid 0 | — | blocked | — |

Findings:
- pf's `group` matches the **effective** gid of the socket's credentials, for TCP and both kinds of UDP sockets. Supplementary groups do not count.
- No user record is needed for the match itself; production still creates a system group so the gid is reserved.

Decision:
- The kill switch is "on the physical interface only sing-box's group may send TCP/UDP", plus explicit policy for what pf cannot attribute (DHCP, ICMP, LAN, IPv6 link-local). pf no longer contains any routing addresses, so routing and kill switch cannot disagree.
- The helper starts sing-box as uid 0 with egid = the Silent Route group (set in the child before exec). Nothing else may run with that gid.
- To re-check on Apple Silicon / macOS 26 before release (same script).
- Found by the first integration run (2026-10-11): pf gives every `pass` rule an implicit `flags S/SA keep state`. On `lo0` each packet is seen twice, so the reply to a localhost SYN never matched a state and was dropped by the final block — the helper lost sing-box's API and reconnected forever. Loopback is now `no state`, and every TCP-capable pass rule has `flags any` so connections older than the rules survive. A test checks `pfctl -nv` output for leftover `flags S/SA`.

## D4. Integration run on a real Mac (2026-10-12)

`experiments/integration/run.sh`, Intel, macOS 15.8, Wi-Fi, one Hysteria2 tunnel: **26/26 passed**. Connect with the kill switch on; no TCP, DNS or IPv6 leaking on the physical interface; requests bound to it are blocked while connected and while sing-box is dead; sing-box killed → reconnected in about a second; helper killed → launchd restarts it, it re-attaches behind the kill switch, one sing-box; `down` and `panic` leave the network as before.

Bugs the earlier runs found, all with regression tests now:
- pf's implicit `flags S/SA` dropped loopback replies (see D3).
- `panic` rebuilt routes under another live VPN; it now repairs only a missing route, a vanished interface or our own TUN.
- `panic` raced with the exit report of the sing-box it stopped and put the kill switch back; pfctl calls are now also serialised in issue order.

## D5. Address and site lists are not shipped (2026-10-13)

- The geoip rule-sets are built from MaxMind GeoLite2 data, whose licence does not allow passing the data on to third parties without MaxMind's consent. Silent Route therefore ships no lists. sing-box downloads the ones a profile uses from the sing-box project's public rule-set branches (`remote` rule-sets, direct, refreshed weekly, cached in `cache.db`); a list already on disk is used as is.
- Side effect: every country and every site list works, not only the few that used to be bundled. Validation checks only the form of the name.

## D6. Releases and updates (2026-10-13)

- A version tag (`v1.0.0-beta`) makes GitHub Actions test on Apple Silicon, build the universal app and publish `Silent-Route-<version>.dmg` with its sha256 and the source of the bundled sing-box (GPL). Suffixed tags are pre-releases.
- The app checks the repository's releases (the helper never goes online). Pre-releases are offered only to someone running one. Installing: download, sha256, mount, signature check, swap the bundle, relaunch; the new app then updates the helper. Profiles live in the helper's directory and are backed up by every install.
- Each build signs with its own self-signed identity. The helper accepts only an app signed like itself, so a new app reports the old helper as "from another version" and updates it.

## D7. Switching profiles while connected (2026-10-13)

- If either profile has a kill switch, blocking goes on before the old sing-box stops and lifts (when the new profile wants none) only after the new one is proven. Tests cover both directions.

## Known issues

- **DNS to a LAN resolver bypasses the tunnel.** If the system resolver is the router (DHCP default), mDNSResponder sends queries straight to it over the LAN, which the kill switch allows. Not visible when the resolver is a public address (it routes into the TUN). Planned fix: while connected the helper overrides the system DNS (SCDynamicStore) with an address inside the TUN subnet, where sing-box hijacks it, and pf blocks port 53 to the LAN for everything but sing-box's group. `experiments/integration/run.sh` step 3 catches the leak.
