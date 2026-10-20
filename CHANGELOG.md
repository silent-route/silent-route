# Changelog

## 1.1.3-beta

Everything since 1.0.1-beta.

### Your data stays yours

- **Profiles belong to each macOS user.** On a Mac shared by several accounts, each has its own profiles; nobody can see another's servers or passwords, from the app or from `sroute`. The VPN itself is one for the whole Mac: while another user's VPN is on, you see only that it is on (not which profile, servers or routes) and may turn it off, since your traffic goes through it too. Their live traffic in Monitor is shown to them alone.
  - When you update, the profiles of the previous version go to the user who installs the update.
  - Uninstalling with *Keep a copy of the profiles* puts each user's copy into their own home folder, readable only by them.
- **Session logs.** Each time the VPN is turned on, its session is logged: connecting and reconnecting (with the reason), failed attempts, profile switches, routes moving between servers, the Mac waking from sleep, and sing-box's own warnings and errors.
  - Logs are written to the home folder of the user who turned the VPN on, `~/Library/Logs/Silent Route`, readable only by them. Open them in Finder or Console, or in the app under **Logs** (sidebar, under Monitor).
  - **Problems** narrows a log to errors, warnings, reconnects and failovers; **Show in Finder** opens the file; **Share** copies or saves it, optionally *without addresses* (IP addresses, host names and the names of your profiles, routes and servers are replaced), so a log can be shown to someone safely.
  - The last 30 sessions are kept. By default logs stay out of Time Machine backups and Spotlight search; both can be allowed in Settings › Advanced.
  - The old shared `sing-box.log`, readable by every account on the Mac, is deleted on update.

### New advanced options

All three are off by default and live where they apply. Leave them alone unless you need them.

- **Tunnel MTU** — profile › Network. The MTU is the largest packet sent through the tunnel at once. *Automatic* suits almost every network. On some networks (a phone hotspot, some hotel and provider networks) large packets get lost, and it looks like pages loading halfway and hanging; choosing 1400 or 1280 fixes that.
- **Multiplexing (MUX)** — server › Advanced. Normally every connection from your Mac (each tab, each app) opens its own connection to the server. With multiplexing, many of them travel inside a few: fewer handshakes, so pages with many requests can open faster, and the optional *padding* adds random data that blurs the shape of your traffic. Two things to know: the server must have multiplexing enabled with the same protocol (h2mux, smux or yamux), or nothing connects; and one slow connection can hold up the others sharing it. Available for VLESS (without XTLS Vision), Trojan, Shadowsocks and VMess; Hysteria2 does not need it — QUIC already works this way.
- **TLS fragmentation** — route editor. When a secure (HTTPS) connection starts, its first packet carries the site's name in the clear. This option splits that packet into pieces, so that network filtering looking for the name does not recognise it. It is meant for routes that go direct; traffic through a server is encrypted as a whole already. Some sites may connect a little slower.

### Also new

- **Proxies in the formats sellers use.** In Add Server › Proxy, paste `host:port:user:pass`, `user:pass:host:port`, `user:pass@host:port`, `host:port@user:pass`, or the same with `|` or a space between the halves. Passwords containing `:` or `@` work too.
- **Connection time and traffic** (Settings › General): counted per connection, restarting after a reconnect (the default), or from turning the VPN on until turning it off.

### Improved

- **Fewer dropped connections on network changes.** A Wi-Fi switch or waking from sleep no longer restarts sing-box at once: the helper checks the servers every 2 seconds and restarts only after 12 seconds without any answer. Short drops pass without breaking calls, downloads or open pages. Routes with a kill switch stay blocked meanwhile, as before.
- The profiles list is drawn as one rounded group, like the groups in System Settings.
- Routes can be reordered with the up/down arrows on each route, like the servers inside a route.

### Security

- The helper runs as root but writes logs into a folder the user owns, so it never opens anything there by a path that could have been swapped: every folder on the way is opened without following symbolic links and must belong to the user, and each file is created new. Uninstalling removes such folders only at their exact path, never through a link.

### Uninstalling

- Uninstalling asks whether to delete the session logs as well — for every user of the Mac. App cleaners such as AppCleaner remove them too.

### Updating

Install the update from the app (Settings › Updates) or from the disk image below. After the relaunch, click **Update Helper** when asked: this version changes how the app and the helper talk to each other. Profiles are kept.

## 1.0.1-beta

- Settings are now split into sections in a sidebar (General, Notifications, Updates, Advanced), so the window fits on any screen.
- The connection panel at the bottom of the sidebar keeps its layout: uptime and speeds sit in fixed columns and no longer wrap as the numbers change.
- Shorter units for sizes and speeds (B, KB, MB, GB).

## 1.0.0-beta

First public beta.

- Routes by domain, IP/CIDR, country, site list, app, port and protocol; each goes direct, is blocked, or uses an ordered list of servers with automatic failover.
- Kill switch enforced by pf, configurable per route.
- Hysteria2, VLESS (incl. Reality), Trojan, Shadowsocks, VMess, SOCKS5, HTTP and HTTPS servers.
- Profiles with import/export, switchable from the menu bar while connected.
- Monitor page, macOS notifications (route changes only, or all events), in-app updates.
