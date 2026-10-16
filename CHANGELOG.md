# Changelog

## 1.1.0-beta

### New

- **Session logs.** Each time the VPN is turned on, its session is written to a log: connecting and reconnecting (with the reason), failed attempts, profile switches, routes moving between servers, the Mac waking from sleep, and sing-box's own warnings and errors. Open **Logs** in the sidebar, under Monitor.
  - The list shows each session with its profile, duration and size; the running one is marked *Live* and updates as you watch.
  - **Problems** narrows a log to errors, warnings, reconnects and failovers; the filter field searches it.
  - **Share** copies or saves a log, optionally *without addresses*: IP addresses, host names and the names of your profiles, routes and servers are replaced, so a log can be shown to someone safely.
  - The last 30 sessions are kept. A session belongs to the macOS user who turned the VPN on, and only they can see it; other accounts on the same Mac see only their own.
- **Proxies in the formats sellers use.** In Add Server › Proxy, paste `host:port:user:pass`, `user:pass:host:port`, `user:pass@host:port`, `host:port@user:pass`, or the same with `|` or a space between the halves. Passwords containing `:` or `@` work too.
- **Connection time and traffic** (Settings › General): count them per connection, restarting after a reconnect (the default), or from turning the VPN on until turning it off.

### Improved

- **Fewer dropped connections on network changes.** A Wi-Fi switch or waking from sleep no longer restarts sing-box at once: the helper checks the servers every 2 seconds and restarts only after 12 seconds without any answer. Short drops pass without breaking calls, downloads or open pages. Routes with a kill switch stay blocked meanwhile, as before.
- Routes can be reordered with the up/down arrows on each route, like the servers inside a route.

### Privacy

- Logs are no longer readable by every account on the Mac. The old shared `sing-box.log` is deleted on update; logs now live in per-user folders that only root can open, and the app reads them through the helper.

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
