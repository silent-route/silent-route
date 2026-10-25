# Changelog

## 1.2.3-beta

Everything that changed since 1.0.1-beta.

### Your data stays yours

- **Profiles belong to each macOS user.** On a Mac shared by several accounts, each has its own profiles; nobody can see another's servers or passwords, from the app or from `sroute`. The VPN itself is one for the whole Mac: while another user's VPN is on, you see only that it is on (not which profile, servers or routes) and may turn it off, since your traffic goes through it too. Their live traffic in Monitor is shown to them alone.
  - When you update, the profiles of the previous version go to the user who installs the update.
  - Uninstalling with *Keep a copy of the profiles* puts each user's copy into their own home folder, readable only by them.
- **Session logs.** Each time the VPN is turned on, its session is logged: connecting and reconnecting (with the reason), failed attempts, profile switches, routes moving between servers, the Mac waking from sleep, and sing-box's own warnings and errors.
  - Logs are written to the home folder of the user who turned the VPN on, `~/Library/Logs/Silent Route`, readable only by them. Open them in Finder or Console, or in the app under **Logs** (sidebar, under Monitor).
  - **Problems** narrows a log to errors, warnings, reconnects and failovers; **Show in Finder** opens the file; **Share** copies or saves it, optionally *without addresses* (IP addresses, host names and the names of your profiles, routes and servers are replaced), so a log can be shown to someone safely.
  - The last 30 sessions are kept. By default logs stay out of Time Machine backups and Spotlight search; both can be allowed in Settings › Advanced.
  - The old shared `sing-box.log`, readable by every account on the Mac, is deleted on update.

### No DNS leaks through the router

On most networks macOS asks the router to look up names, and the router is reached over the local network — past the tunnel. The router, and the provider behind it, could see every site you opened even with the VPN on. Some providers also answer with fake addresses for sites they block, so those sites failed even through the VPN.

- **While the VPN is on, macOS's resolver points into the tunnel** (`172.19.0.6`), where sing-box answers by your profile's rules: names of routes through servers are resolved encrypted through that same server, names of direct routes by the direct resolver.
- **The kill switch now lets only sing-box ask the router** (DNS on ports 53 and 853, IPv4 and IPv6), so nothing that talks to the router directly can leak names either.
- **Local names still work.** Names in the profile's *local zones* — by default `lan`, `home.arpa` and `internal` (a NAS, a printer, the router's own page) — are asked of the router, and nothing else is. Change the list in the profile's DNS tab. Names ending in `.local` (AirPrint, AirDrop) were never DNS and keep working.
- **Your network settings are not changed.** Only macOS's live network state is: it goes back when the VPN turns off, on Emergency Restore and when the helper stops; a crashed helper puts it back when it starts again; and a restart of the Mac starts from your own settings, untouched. If a network rewrites its DNS (a new Wi-Fi), the helper points it back within seconds.

### Hotel and café Wi-Fi, without turning the VPN off

Some networks let nothing through until you log in on their web page. Turning the VPN off to log in would let everything on the Mac out directly the moment the network accepts you — and change your address mid-session.

- When the VPN reconnects behind its kill switch and the new network wants a login, Silent Route notices (it asks Apple's check page, `captive.apple.com`, the way macOS does) and keeps sing-box running, with everything still blocked.
- A notification and **This Wi-Fi needs a login** in the menu bar and the window offer **Open Login Page**: a small browser window inside Silent Route whose traffic — and nothing else on the Mac — goes out directly, with the router's DNS. Its way out listens only on this Mac, takes a new password every time, and is given only to the user who turned the VPN on. The window keeps no cookies or history.
- Once you have logged in, the servers answer and the VPN carries on **through the same server, with the same address as before** — sing-box was never restarted, and the kill switch was on throughout.
- Turning the VPN on for the first time on such a network changes nothing: log in first, then turn it on.

### New advanced options

All three are off by default and live where they apply. Leave them alone unless you need them.

- **Tunnel MTU** — profile › Network. The MTU is the largest packet sent through the tunnel at once. *Automatic* suits almost every network. On some networks (a phone hotspot, some hotel and provider networks) large packets get lost, and it looks like pages loading halfway and hanging; choosing 1400 or 1280 fixes that. *Custom…* takes any value from 1280 to 9000.
- **Multiplexing (MUX)** — server › Advanced. Normally every connection from your Mac (each tab, each app) opens its own connection to the server. With multiplexing, many of them travel inside a few: fewer handshakes, so pages with many requests can open faster, and the optional *padding* adds random data that blurs the shape of your traffic. Two things to know: the server must have multiplexing enabled with the same protocol (h2mux, smux or yamux), or nothing connects; and one slow connection can hold up the others sharing it. Available for VLESS (without XTLS Vision), Trojan, Shadowsocks and VMess; Hysteria2 does not need it — QUIC already works this way.
- **TLS fragmentation** — route editor. When a secure (HTTPS) connection starts, its first packet carries the site's name in the clear. This option splits that packet into pieces, so that network filtering looking for the name does not recognise it. It is meant for routes that go direct; traffic through a server is encrypted as a whole already. Some sites may connect a little slower.

### Honest server checks

**Check** on a server is now made by the helper, the way the VPN itself reaches the server: directly, bound to the physical network. Before, with the VPN on, the check went through the VPN — a tunnel inside a tunnel — and the latency it showed included another server. The country and address shown were right; the time now is too.

### Also new

- **Proxies in the formats sellers use.** In Add Server › Proxy, paste `host:port:user:pass`, `user:pass:host:port`, `user:pass@host:port`, `host:port@user:pass`, or the same with `|` or a space between the halves. Passwords containing `:` or `@` work too.
- **Connection time and traffic** (Settings › General): counted per connection, restarting after a reconnect (the default), or from turning the VPN on until turning it off.
- **Settings › General › Transparency**: *Standard* (as before) or *More* see-through glass panels. On macOS 26 *More* uses the clear variant of Liquid Glass.
- **[docs/network.md](docs/network.md)** describes every connection Silent Route makes or lets through — by whom, where to, by which path and when — how DNS is resolved, what the kill switch lets out, and the Wi-Fi login step by step.

### Improved

- **Fewer dropped connections on network changes.** A Wi-Fi switch or waking from sleep no longer restarts sing-box at once: the helper checks the servers every 2 seconds and restarts only after 12 seconds without any answer. Short drops pass without breaking calls, downloads or open pages. Routes with a kill switch stay blocked meanwhile, as before.
- The profiles list is drawn as one rounded group, like the groups in System Settings.
- Routes can be reordered with the up/down arrows on each route, like the servers inside a route.

### Interface

- **Edit… is in each route's ⋯ menu**, *Everything else* included, next to Duplicate and Delete. A double-click on a route opens it too.
- **Logs are listed as one rounded group**, like the profiles. The session still running is marked with a green dot on the right, as the active profile is.
- **The Settings button in the toolbar is dimmed while Settings is open** and back to normal once it is closed.
- **The menu bar panel closes when you switch to another app or another desktop.** It used to stay on screen and could look as if it had opened by itself.
- Section headers use Title Case, as in Apple's apps, and the Routes / Servers / DNS / Network switcher is centred.

### Updates that don't get stuck

The app could hold on to an update it had found earlier — even after that release was withdrawn or superseded — offer only that version, and fail to install it, with no way to look again.

- **Installing now asks GitHub again first** and installs what is published at that moment: the newest release, not whatever was found hours ago. If nothing newer is published any more, it says so.
- **Check Now is always there** in Settings › Updates, also while an update is shown, so an old result can always be refreshed.
- **Automatic checks run every 6 hours** instead of once a day.

If your copy shows an update it cannot install, quit Silent Route and open it again: it checks afresh soon after starting. Or download this release below and replace the app; profiles and logs are kept.

### Updating from an earlier version works again

- **The helper update could stop halfway.** When the installer tidied up old backups of a kind that did not exist yet, it ended with an error before putting the new helper in place. The old helper kept running — the network was never left broken — but the app and the helper stayed on different versions. Fixed, along with three similar spots in the installer.
- **With the app and the helper on different versions, the VPN can now always be turned off.** The switch and **Emergency Restore** used to be greyed out in that case. Now the app turns the VPN off and restores the network through the installed helper's own command line, which always matches the helper. Turning the VPN *on* still needs the helper updated first.
- **A VPN that was on during the update comes back with your profile.** When the profiles of an earlier version move to the user who installs the update, that user also becomes the owner of the running VPN, so it reconnects with their profile rather than an empty one.

### Security

- The helper runs as root but writes logs into a folder the user owns, so it never opens anything there by a path that could have been swapped: every folder on the way is opened without following symbolic links and must belong to the user, and each file is created new. Uninstalling removes such folders only at their exact path, never through a link.

### Uninstalling

- Uninstalling asks whether to delete the session logs as well — for every user of the Mac. App cleaners such as AppCleaner remove them too.

### Updating

Install the update from the app (Settings › Updates) or from the disk image below. After the relaunch, click **Update Helper** when asked: this version changes how the app and the helper talk to each other. Profiles and logs are kept.

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
