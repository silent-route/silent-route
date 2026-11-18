# Changelog

## 1.6.0-beta

- **Server Library**, in the sidebar under Logs: servers and proxies kept apart from profiles. A profile adds one with **Add Server › From Library** and takes a copy of its own, so it stays complete when shared; **Add to Library** in a server's menu goes the other way. The library is each macOS user's own.
- **When another VPN's kill switch is on**, Silent Route can reach none of its servers. A failed start and a server check now say so — *another firewall on this Mac (pf) blocks the way* — instead of reporting the servers as dead.
- **A failed server check says why.** It showed macOS's *bad URL* whenever the server could not be reached; it now gives sing-box's own reason — a timeout, a refused or closed connection.
- **No more waiting on HTTP/3 through a proxy without UDP.** Routes whose servers cannot carry UDP (a SOCKS5 proxy without UDP, an HTTP proxy) refuse it at once, as they refuse ping, so browsers move to TCP right away and the log no longer fills with *UDP is not supported*.
- A double-click edits a server, also in the library.

## 1.5.2-beta

Replaces 1.5.0-beta, which was withdrawn. Fixed since 1.5.0:

- The Routes, Servers, DNS and Network buttons of a profile did nothing.
- After an update with the VPN on, it could stay blocked behind the kill switch for minutes: it came back needing lists it had not downloaded yet, and could not download them there. The helper now fetches lists the way the kill switch lets out, also while it blocks.
- Turning a VPN that is on to another profile first checks that the profile can run — its lists downloaded, no errors — and leaves the running one alone if not.

### Lists you add yourself

- **No address or site lists are built in any more.** A profile's lists are added in **Network › Lists** by their web address (HTTPS): a sing-box rule-set (`.srs` or `.json`) or plain text with one site or address per line — v2fly (`domain:`, `full:`, `keyword:`) and Clash (`DOMAIN-SUFFIX,`, `IP-CIDR,`) styles are understood. A route uses one as `list:name`.
- **Kept up to date by the helper.** A list is downloaded when the profile is saved or turned on, checked for a new version every day, and on **Update Now**; each list shows when it was updated, its size, and why the last download failed, if it did. A new version replaces the old one only after sing-box has read it whole, and a VPN that is on picks it up without reconnecting.
- **Never half a profile.** A profile whose list could not be downloaded does not start, and a running VPN does not switch to it — with a message saying which list. What a list should catch never slips past its route.
- Profiles that used `geoip:` and `geosite:` keep working: those become lists with the sing-box project's address they always came from.

### Routes

- **A route's apps and sites match on their own.** Everything the listed apps send, and every connection to the listed sites from any app, goes the route's way. Before, a route with both took only those apps' traffic to those sites, and other apps going there fell through to *Everything else*. Ports and a protocol still narrow both.
- **Local network addresses** as a route condition: the router, printers, a NAS — every private and link-local address, on whatever network the Mac joins.
- **A double-click edits** a route, a server or a list. A route's chain of servers wraps instead of scrolling sideways.

### Window

- Switching to another profile stays on the same page (Routes, Servers, DNS or Network).
- Profile pages take the window's width.

## 1.4.4-beta

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

- **While the VPN is on, macOS's resolver points at sing-box**, which answers by your profile's rules: names of routes through servers are resolved encrypted through that same server, names of direct routes by the direct resolver.
- **Wi-Fi is no longer reset every half hour.** sing-box answers DNS on this Mac's port 53, and each network service is given its own address as its DNS server. Before, macOS was pointed at an address inside the tunnel, which its own network checks (DNS scoped to the Wi-Fi interface) could never reach; macOS took that for a broken Wi-Fi and reconnected it about every 30 minutes, cutting every connection. That port answers this Mac only: DNS coming in from the network is dropped while the VPN is on, so other devices nearby can neither use nor probe it. If something else already uses port 53, the address inside the tunnel is used as before.
- **The kill switch now lets only sing-box ask the router** (DNS on ports 53 and 853, IPv4 and IPv6), so nothing that talks to the router directly can leak names either.
- **Local names still work.** Names in the profile's *local zones* — by default `lan`, `home.arpa` and `internal` (a NAS, a printer, the router's own page) — are asked of the router, and nothing else is. Change the list in the profile's DNS tab. Names ending in `.local` (AirPrint, AirDrop) were never DNS and keep working.
- **Your network settings are not changed.** Only macOS's live network state is: it goes back when the VPN turns off, on Emergency Restore and when the helper stops; a crashed helper puts it back when it starts again; and a restart of the Mac starts from your own settings, untouched. If a network rewrites its DNS (a new Wi-Fi), the helper points it back within seconds.

### A kill switch from the first moment

- **With a kill switch on any active route, everything outside the tunnel is blocked the moment you turn the VPN on**, and the servers are checked behind that block. Before, traffic went out directly for the few seconds the first connection took. If the VPN cannot connect, the block is lifted and the network is as it was. A kill switch on a route that is turned off does not count; with none on any active route, nothing is ever blocked.
- **Devices with local IPv6 addresses** (`fd…` — a NAS, a home server) are reachable when the profile allows the local network, as their IPv4 addresses always were.
- **Ping no longer clutters the log.** A proxy server cannot carry ping, so pings meant for a route through servers were dropped with a warning for every packet. They are now refused at once — never sent past the tunnel — and routes that go direct keep their ping.
- When the network changes, the session log says so, so the errors sing-box prints for the connections the change cut have a visible cause.

### Servers that are slow, not dead

- **A server counts as down only after two missed checks in a row.** One lost check — a dropped packet, a busy moment — used to block its routes (or move them to the next server) for about ten seconds, again and again, while the server was fine.
- **Slow servers get time.** Connecting to a server may take up to 15 seconds (it was 5), and a health check waits up to 10 seconds for an answer. A busy proxy that is slow to accept connections stays slow, as it is in other clients, instead of failing and getting its route blocked.
- **SOCKS5 proxies carry TCP only by default**, as in most clients. With UDP, every HTTP/3 connection (Google and many sites use it) held a connection of its own to the proxy, and proxies that limit connections ran out of them. Browsers now use TCP through such a proxy. **UDP through this proxy**, in the server's settings, turns it back on for calls or games, if the proxy supports it.

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

- **Safari and Apple web content.** Safari runs from macOS's updatable system part (a cryptex; /Applications/Safari.app is only a link), so a route listing Safari never matched it: now it does. The web pages Safari, Mail, the App Store and other Apple apps show load through one shared system process; a route's new **Apple web content** setting decides where they go — set in the route only, with a warning of what it affects (Mail, the App Store, sign-in windows); nothing on the Mac is changed, and turning the VPN off or Emergency Restore puts everything back. Safari listed in a route or added from Monitor says that its pages follow that setting; in Monitor that process shows as *Apple web content (WebKit)*.
- **A new profile can be turned on as it is.** *Everything else* now starts direct instead of "through servers" with none chosen, which could not be turned on: "only this app through the tunnel, the rest untouched" works without touching it. It can still be sent through any servers, or blocked, in its Edit…. A profile with servers that no route uses says so (everything would go direct); one whose *Everything else* has no servers says how to fix it.
- **Fewer dropped connections on network changes.** A Wi-Fi switch or waking from sleep no longer restarts sing-box at once: the helper checks the servers every 2 seconds and restarts only after 12 seconds without any answer. Short drops pass without breaking calls, downloads or open pages. Routes with a kill switch stay blocked meanwhile, as before.
- Routes can be reordered with the up/down arrows on each route, like the servers inside a route.

### A Mac interface by Apple's guidelines

The whole interface was reworked to follow Apple's Human Interface Guidelines for macOS.

- **The VPN switch is at the top of the sidebar,** with the connection time and speed: the most important control where reading starts, and never at the bottom, which a window moved down can hide.
- **Toolbars like Apple's apps.** Each page's view switch sits centred in the toolbar — a profile's Routes / Servers / DNS / Network, Monitor's Apps / Connections, Logs' All / Problems — and actions on the trailing side: Add, Export and Settings; Show in Finder and Share for logs. Monitor and Logs filter through a search field in the toolbar, as in Activity Monitor and Console.
- **Save and Revert are in the toolbar,** Save highlighted, instead of a bar at the bottom of the window. Unsaved changes and anything that stops a save are shown at the top of the page.
- **A profile's name is the page's title,** large and editable, with its state and number of servers and routes underneath.
- **Plain grouped sections** for routes, servers and settings, as in System Settings. Liquid Glass stays with the controls and the menu bar panel, where Apple uses it; **Settings › General › Transparency** now sets how see-through the menu bar panel is.
- **Everything is in the menu bar too:** File › New Profile (⌘N), Import Profile… (⌘O), Export Profile… (⇧⌘E); View › Monitor, Logs, Active Profile (⌘1, ⌘2, ⌘3); VPN › Turn VPN On / Off (⇧⌘T) and Emergency Restore…; Window › Silent Route (⌘0); Help › Silent Route Help.
- **Settings as toolbar panes** (General, Notifications, Updates, Advanced), the window titled after the open pane, and the last pane you viewed comes back.
- **Edit… is in each route's ⋯ menu**, *Everything else* included, next to Duplicate and Delete. A double-click on a route opens it too.
- **Settings › Advanced › Log every connection** records each connection in the session log — which app, which site, through which route and server — to track a problem down. It takes effect from the next session; off by default.
- **Logs: right-click a session** to export it (with or without addresses), show it in Finder, or move it to the Trash.
- **The profiles and the logs are plain lists with the system's own selection,** as in Finder, Mail and Notes. The session still running is marked with a green dot on the right, as the active profile is.
- **Monitor is laid out like Activity Monitor's Network tab:** the list of apps or connections takes the window, edge to edge; below it, the figures (download, upload, connections, data received and sent) and a chart in a thin frame — larger than Activity Monitor's.
- **Monitor's colours:** download purple, upload teal.
- **The chart covers the whole session**, from the moment the VPN was turned on and across reconnects, also while Monitor was closed — open it any time to see what happened before. Show the last 2 minutes, an hour, or the whole session from a small pop-up beside the figures, with times along the bottom. A reconnect shows as a drop to zero. The list of connections is read only while Monitor is on screen.
- **Monitor's lists sort by any column,** as in Activity Monitor: click a header, click again to reverse.
- **Pin to Top** (right-click a row) keeps an app, or an app's traffic to a site, at the top of Monitor's list, in your own order (Move Up / Move Down). A pinned row with nothing live is shown faded. Pins are kept across launches.
- **Add to Route…** (right-click, or double-click a row in Monitor) puts an app — or, for a connection, its site, at the level you choose: googlevideo.com with its subdomains, or one exact name — into a route: an existing one, or a new one placed first, through the server you pick, direct or blocked; in any profile or a new one. It is saved at once, and for the profile in use it applies right away. If adding would narrow a route rather than widen it (the first app in a route of sites), the sheet says so first.
- **Apps are counted whole in Monitor:** a browser's helper processes are part of the browser's row, not rows of their own.
- **The Settings button in the toolbar is dimmed while Settings is open** and back to normal as soon as it is closed.
- **The toolbar's title says what kind of page is open:** Monitor, Logs or Profile (a profile's name is already shown large on the page). Before, switching from Monitor or Logs to a profile left the previous title behind.
- The main window opens a little wider by default.
- **No dark corners on the menu bar panel** on macOS 26 with *Standard* transparency.
- **The menu bar panel closes when you switch to another app or another desktop.** It used to stay on screen and could look as if it had opened by itself.
- Buttons that open another window end in an ellipsis (Add Route…, Install Helper…), and titles use Title Case, as in Apple's apps.

### Updates that keep you protected

- **With the VPN on, nothing leaks during an update.** Before, the old helper lifted the kill switch when it stopped, so for a few seconds traffic went out directly, and the VPN did not always come back afterwards. Now everything outside the tunnel stays blocked while one helper replaces the other, and the new helper brings the VPN back by itself, through the same profile. With the VPN off, the network is not touched at all.
- **The VPN comes back after an update.** The new helper loaded your profile before checking whether the VPN had been on — and loading it saved the state, so it read back its own "off" instead of what the previous helper had left. The VPN stayed off and the block was lifted. The state is now read before anything can write it. Telling a restart of the Mac from a helper restart also uses the kernel's boot session id now, instead of the boot time macOS shifts when it corrects the clock.
- **The password is asked when you click Install,** not after the relaunch: the helper is updated from the new version first, then the app is replaced and relaunched.
- **A small window shows the update's progress,** with a filling bar while downloading. While downloading, **Cancel** stops it with nothing changed. While the helper is replaced with the VPN on, **Cancel…** warns that traffic will no longer be protected, then turns the VPN off so the network goes back to normal. After the relaunch the window stays until the VPN is back, with **Turn VPN Off…** in case it does not come back.
- **If the helper cannot be updated,** the previous one is put back. If no helper starts at all, nothing is unblocked behind your back: the window says what happened and offers **Restore Network** (or restart the Mac).

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

- The helper (root) never follows a path a user could have prepared: removing users' logs is done by descriptor or as that user, nothing is written by path in /Library/Logs, sing-box's folders are checked along with the file, and the `sroute` link is replaced without following what is there.
- A profile save that could not be written (a full disk) is reported, and nothing changes, instead of looking saved.
- A Shadowsocks link with an empty plugin name crashed the app; links, rule lines and profiles are now fuzz-tested.

- **The Wi-Fi login proxy's password no longer appears on a command line,** where any user of the Mac could read it with `ps`; it is the one way past the kill switch while a network wants a login.
- **The helper refuses a request it cannot attribute to a user,** instead of treating it as coming from root; and at most three server checks (each a sing-box run) go at once.
- **“Without addresses” in logs also hides your account name** in the paths sing-box prints.
- The helper runs as root but writes logs into a folder the user owns, so it never opens anything there by a path that could have been swapped: every folder on the way is opened without following symbolic links and must belong to the user, and each file is created new. Uninstalling removes such folders only at their exact path, never through a link.

### Uninstalling

- Uninstalling asks whether to delete the session logs as well — for every user of the Mac. App cleaners such as AppCleaner remove them too.

### Updating

Install the update from the app (Settings › Updates) or from the disk image below. Coming from 1.2.3 or earlier (1.0.1 included), the update still runs the old way once: after the relaunch, click **Update Helper** if asked. From 1.2.4 on, the helper is updated before the relaunch, with the VPN kept protected. Profiles and logs are kept.

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
