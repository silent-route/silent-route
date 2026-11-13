# Silent Route

A macOS client for [sing-box](https://github.com/SagerNet/sing-box) that decides — per site, address, country, app and port — which tunnel or proxy each piece of traffic takes, and backs it with a pf kill switch, so nothing leaves the Mac by a path you didn't choose.

I wrote it because I needed several exits at once — some traffic direct, some through one server, some through another — and no client did that together with a kill switch I could trust.

Intel and Apple Silicon, macOS 14 Sonoma through macOS 27 Golden Gate.

[Releases](../../releases)

**Status:** beta. The core and the helper pass an end-to-end test on a real Mac; the interface still changes. If the network ever ends up in a bad state, see [Recovery](#recovery).

## Features

**Routing**
- A profile holds servers and routes. Servers: Hysteria2, VLESS (incl. Reality), Trojan, Shadowsocks, VMess, SOCKS5, HTTP, HTTPS — from a share link, by hand, or pasted in the usual seller formats (`host:port:user:pass`, `user:pass@host:port`…). Link options sing-box can't do are reported, not dropped.
- A route matches by domain, IP/CIDR, country (geoip), site list (geosite), app, port and protocol, and sends traffic direct, blocks it, or through an ordered list of servers — the first that answers carries it. Routes are checked top to bottom; *Everything else* is last, and goes wherever you set it — through servers, direct or blocked. A new profile starts with it direct, so one app through a tunnel and the rest untouched works as is.
- **Apple web content** is a route setting of its own: the web pages shown by Safari, Mail, the App Store and other Apple apps load through one shared macOS process (`com.apple.WebKit.Networking`) and cannot be told apart, so this one setting decides where they go — set in the route only, never from Monitor, with a warning: those apps then depend on that route. Nothing on the Mac is changed; turning the VPN off or Emergency Restore puts everything back. Safari itself can be listed like any app (it runs from the system cryptex; both its paths are matched); its pages follow the setting, which the app points out.
- Switch profiles from the menu bar while connected; edits to the profile in use apply on Save, no reconnect needed. Profiles export as `.srprofile` files (they contain credentials).

**Protection**
- Each route has its own kill switch: when none of its servers answer, its traffic is blocked or goes direct. With one on any active route, blocking starts the moment the VPN is turned on; if it can't connect, the network is left as it was.
- No DNS leaks: while the VPN is on, macOS asks sing-box (on this Mac's port 53, closed to the network), and only sing-box may ask the router. Local names (`nas.lan`, zones you choose) still work. Saved network settings are never changed.
- Hotel and café Wi-Fi: the VPN stays on behind its kill switch and offers **Open Login Page** — a small window whose traffic alone goes out directly.
- Short drops (a Wi-Fi switch, sleep) don't restart sing-box: it restarts only after 12 seconds without an answer, and a server counts as down after two missed checks in a row.
- Nothing starts on its own, not even after a reboot, and nothing Silent Route sets up survives one.

**Monitor**
- Throughput over the whole session, traffic per app, and every open connection with its route and server — laid out like Activity Monitor, every column sortable.
- Right-click a row to **Pin to Top** (an app, or an app's traffic to a site) or **Add to Route…** — the app, or the connection's site, into an existing or new route of any profile, saved at once.

**Everything else**
- Profiles belong to each macOS user; on a shared Mac nobody sees another's servers or passwords.
- Session logs in `~/Library/Logs/Silent Route` (owner-only, last 30 sessions), shown under Logs with a problems filter and export without addresses. Optionally every connection is logged (Settings › Advanced).
- Notifications when a route fails over, goes direct, is blocked or recovers.
- Advanced options, off by default: tunnel MTU, multiplexing, TLS fragmentation for direct routes, UDP through a SOCKS5 proxy.
- A native Mac app by Apple's Human Interface Guidelines: the VPN switch at the top of the sidebar, actions in the toolbar and the menu bar with shortcuts, Liquid Glass on macOS 26.

What changed in each version: [CHANGELOG.md](CHANGELOG.md).

### A word of caution about server lists

When a route moves to its next server, your IP address changes mid-session. Banks, payment systems, marketplaces and AI services may then log you out or flag the account. For those, give the route a single server and turn its kill switch on: no connection is better than a sudden change of address.

## Installation

1. Download `Silent-Route-<version>.dmg` from [Releases](../../releases) and copy the app to Applications.
2. The app is not notarized (there is no Apple Developer account behind it), so remove the quarantine attribute:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Silent Route.app"
   ```

   or open it once and click Open Anyway in System Settings → Privacy & Security.
3. Launch it and click **Install Helper…** (administrator password): a root launchd daemon that runs sing-box and pf.

### Updating

Settings → Updates (or Silent Route → Check for Updates…) downloads the release, verifies its SHA-256 and signature, updates the helper (administrator password), replaces the app and relaunches it. Profiles are kept, with the last ten copies in `/Library/Application Support/Silent Route/backups/`.

If the VPN was on with a kill switch, traffic stays blocked while the helper is replaced and the VPN comes back by itself; **Cancel** turns it off instead. With the VPN off, the network isn't touched. If the new helper fails, the old one is put back; if neither starts, the block stays until you choose **Restore Network** or restart the Mac.

### Uninstalling

Settings → Uninstall Silent Route…, the `Uninstall Silent Route.command` in `/Library/Application Support/Silent Route/`, or an app cleaner such as AppCleaner (the helper notices, restores the network and removes itself). All remove the helper, profiles, the `_silentroute` group and `sroute`; session logs too, unless you choose to keep them.

### Recovery

**Emergency Restore** (menu bar, or ⇧⌘⌫) stops the VPN, removes the pf rules and repairs the default route. From Terminal: `sroute panic`.

## Design

<p align="center"><img src="docs/images/design.svg" alt="Silent Route design: the app talks to the root helper over XPC; the helper runs sing-box and the pf kill switch"></p>

- **The helper owns all state.** The app sends typed requests over XPC, from clients signed with the helper's certificate; the helper builds the sing-box config and pf rules itself and never accepts raw ones. Profiles are kept per user in `/Library/Application Support/Silent Route/users/<uid>/` (root only).
- **Kill switch:** sing-box runs with the `_silentroute` group, and the pf anchor `com.apple/silentroute` passes only that group's traffic on physical interfaces (plus loopback, DHCP and, optionally, the LAN). Anything not sent by sing-box is dropped, whatever the routing table says. The main ruleset and other anchors are left alone.
- **Failover:** every 10 seconds the helper measures the servers in use through the clash API and picks, per route, the first that answers. If sing-box exits, the pf rules stay and the helper reconnects with backoff.
- **Integrity:** binaries are copied into root-owned directories, and sing-box's SHA-256 is checked against `singbox.pin` before each launch. Logs are written into the user's folder without following symlinks, as new 0600 files.
- geoip/geosite rule-sets aren't bundled: sing-box downloads the ones a profile uses from SagerNet's repositories and refreshes them weekly.

Every connection Silent Route makes or lets through, DNS and the Wi-Fi login are described in [docs/network.md](docs/network.md) — in short, apart from your traffic only server checks, rule-set downloads, the login check and update checks go out; no telemetry. Design notes and test results: [docs/decisions.md](docs/decisions.md).

## Command line

```
sroute status | up | down | panic
sroute profiles | use <profile> | import <file> | export <profile> <file> | delete <profile>
sroute servers | routes | add <link> | remove <name>
sroute probe <link>    test a server through a temporary local proxy
sroute diag            interfaces, routes, other active VPNs
```

## Building

Swift 6 and the macOS 26 SDK (Xcode 26 or its Command Line Tools).

```sh
scripts/build-app.sh      # build/Silent Route.app, universal, self-signed
scripts/test.sh           # unit tests; generated configs checked with `sing-box check`
swift run ui-snapshots    # renders views to PNG
sudo experiments/integration/run.sh   # end-to-end test on a real Mac (briefly turns off networking)
```

Releases are built by GitHub Actions on a `v*` tag.

| Directory | Contents |
|---|---|
| `Sources/VPNCore` | model, link parser, sing-box and pf generators (no I/O) |
| `Sources/VPNHelperKit` | helper state machine, pfctl / sing-box / network adapters |
| `Sources/SilentRouteHelper` | helper executable |
| `Sources/SilentRouteUI`, `Sources/SilentRouteApp` | app |
| `Sources/sroute` | CLI |
| `Resources/install-helper.sh` | install, update, uninstall |

## Legal

VPN software is restricted in some countries; make sure using it is legal where you are. Provided as is, without warranty.

## License

GPL-3.0, see [LICENSE](LICENSE). Release builds include an unmodified sing-box binary (GPL-3.0-or-later, © nekohasekai) with its source attached to each release. Silent Route is not affiliated with the sing-box project.
