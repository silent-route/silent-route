# Changelog

## 1.6.9-beta

- **Server Library: add a server from a profile.** Add Server › From Profile lists the profiles and their servers; the one you pick is copied into the library. Before, a server could only be typed in from scratch there, or sent from a profile one at a time through its menu.
- **A tidier disk image.** The window opens at the size of its contents: the app on the left, Applications on the right, an arrow between them, with no scrolling (also when Finder shows its tab bar or path bar). The disk shows the app's icon.
- **A lighter shadow under the app icon.**

## 1.6.8-beta

Replaces 1.7.0-beta, which was withdrawn. It moved to sing-box 1.14.3, and on some networks Hysteria2 kept dropping on macOS: the new QUIC code sends larger packets to probe the path, and when a router answers that a packet is too large, macOS reports it in a way that sing-box 1.14 treats as fatal for the whole connection. Every site and app going through that server then reconnected, over and over. This release stays on sing-box 1.13.16, as 1.6.7 did, and keeps the other fixes of 1.7.0. If you installed 1.7.0-beta, install this one by hand: the app does not offer a lower version as an update.

- **A list of sites and addresses no longer sends other names past the tunnel.** A list used in a route also decides where the names in it are looked up. When a list held addresses as well (`IP-CIDR` lines, a country's networks next to its sites), sing-box asked that route's resolver about every name, in the list or not, to compare the answer with those addresses; for a direct route that was past the tunnel. Now only a list's sites take part in DNS; traffic is still matched against the whole list. Lists already downloaded are converted when the helper starts, without downloading them again.
- **Save… and Export… in the log window write the whole log.** For a large session they wrote what the window shows: its beginning and its end, with the middle left out.
- **The log shows harmless connection closes in grey, not red.** sing-box calls them errors: the server closing an idle connection with code 0 ("no error"), or an app having already dropped its side ("endpoint not connected"). Nothing went wrong in either.

## 1.6.7-beta

Replaces 1.6.6-beta, which was withdrawn.

- **The server form has every setting a link can carry.** Shadowsocks: *Plugin* (obfs-local, v2ray-plugin) and its options. Hysteria2: upload and download speed. VMess: alter ID. Before, the app read them from a link but had no fields for them, and they were lost when the server was added or edited.
- Reality picked for a VLESS server no longer stays in the server when another protocol is chosen afterwards.
- `sroute probe` checks a server through the helper, the way the VPN reaches it, as the app does. Before, it ran on its own and with the kill switch on always reported that the server does not answer.
- The menu bar panel no longer flashes on the next desktop when you swipe to another one while it is open.
- The speed in the menu bar panel and Monitor no longer stays empty for a whole connection when the first request for it fails.

## 1.6.5-beta

- The update window no longer stays above other windows. Clicking the Dock icon while an update runs brings it back.
- **Split the handshake** for servers with ordinary TLS (VLESS, Trojan, VMess, HTTPS proxies), in the server's Security section: the first TLS message goes out in parts, so a network that blocks by server name does not see it. On by default for servers added from now on, in TLS records; servers already in profiles keep working as before. Reality and Hysteria2 do not have it: sing-box does not split their handshake.
- **Monitor's chart follows Connection time and traffic** (Settings › General): with *Start again after a reconnect* the chart's *Session* starts at the current connection too. Before, it always counted from turning the VPN on.

## 1.6.4-beta

Everything that changed since 1.0.1-beta. The betas in between were withdrawn.

**Updating from 1.0.1:** install from the app (Settings › Updates) or from the disk image below. After the relaunch, click **Update Helper** if asked. This happens once: later updates replace the helper before the relaunch, with the VPN kept protected. Profiles and logs are kept. If 1.0.1 shows an update it cannot install, quit Silent Route and open it again, or replace the app with the one below.

### Lists you add yourself

- **No address or site lists are built in.** A profile's lists are added in **Network › Lists** by their web address (HTTPS): a sing-box rule-set (`.srs` or `.json`) or plain text with one site or address per line. The v2fly (`domain:`, `full:`, `keyword:`) and Clash (`DOMAIN-SUFFIX,`, `IP-CIDR,`) styles are understood. A route uses one as `list:name`. Lists are saved in the profile, so an exported profile works on another Mac.
- The helper keeps lists up to date. A list is downloaded when the profile is saved or turned on, checked for a new version every day, and on **Update Now**; each list shows when it was updated, its size and, if the last download failed, why. A new version replaces the old one only after sing-box has read it whole, and a VPN that is on picks it up without reconnecting.
- If a list could not be downloaded, its profile does not start and a running VPN does not switch to it. The message says which list.
- Profiles that used countries or site lists (`geoip:`, `geosite:`) keep working: those become lists with the sing-box project's address they always came from.

### Routes

- **A route's apps and sites match on their own.** Everything the listed apps send, and every connection to the listed sites from any app, goes the route's way. Ports and a protocol narrow both.
- **Local network addresses** as a route condition: the router, printers, a NAS, any private or link-local address on whatever network the Mac joins.
- **Apple web content.** Safari runs from macOS's updatable system part (a cryptex; /Applications/Safari.app is only a link), so a route listing Safari never matched it: now it does. The pages Safari, Mail, the App Store and other Apple apps show load through one shared system process; a route's **Apple web content** setting decides where they go, with a warning of what it affects. Nothing on the Mac is changed; turning the VPN off or Emergency Restore puts everything back.
- In a new profile *Everything else* goes direct, so you can send one app through a server and leave the rest as it was. If servers are unused or *Everything else* has none, the profile says how to fix it.
- Routes are reordered with the arrows on each route. A double-click edits a route, a server or a list.

### Servers

- **Server Library**, in the sidebar under Logs: servers and proxies kept apart from profiles. A profile adds one with **Add Server › From Library** and takes its own copy, so it stays complete when shared; **Add to Library** in a server's menu goes the other way. The library is each macOS user's own.
- **Proxies in the formats sellers use.** In Add Server › Proxy, paste `host:port:user:pass`, `user:pass:host:port`, `user:pass@host:port`, `host:port@user:pass`, or the same with `|` or a space between the halves. Passwords containing `:` or `@` work too.
- **Hysteria2 links from Xray** work: the obfuscation it writes in `fm` is read like `obfs`, and `security=tls` is accepted. Any other `security` value is noted and ignored, since Hysteria2 always uses TLS.
- A server counts as down only after two missed checks in a row. Slow servers get up to 15 seconds to connect and 10 seconds for a health check, so a busy proxy is slow but not marked dead.
- **Check** goes to the server directly, as the VPN does, so the latency is the server's own even while the VPN is on. A failed check shows sing-box's reason (timeout, connection refused or closed) instead of macOS's *bad URL*.
- **When another VPN's kill switch is on**, Silent Route can reach none of its servers. A failed start and a server check now say *another firewall on this Mac (pf) blocks the way* instead of reporting the servers as dead.
- **SOCKS5 proxies carry TCP only by default**, as in most clients: with UDP, every HTTP/3 connection held a connection of its own to the proxy, and proxies that limit connections ran out of them. **UDP through this proxy**, in the server's settings, turns it back on for calls or games. Routes whose servers cannot carry UDP refuse it at once, so browsers move to TCP right away.

### DNS

Before, macOS asked the router to look up names, outside the tunnel. The router and your provider could see which sites you opened, and some providers return fake addresses for blocked sites.

- **While the VPN is on, macOS's resolver points at sing-box**, which answers by your profile's rules: names of routes through servers are resolved encrypted through that same server, names of direct routes by the direct resolver. sing-box listens on this Mac's port 53, closed to the network.
- **The kill switch lets only sing-box ask the router** (DNS on ports 53 and 853, IPv4 and IPv6).
- **Local names still work.** Names in the profile's *local zones* (by default `lan`, `home.arpa` and `internal`) are asked of the router; change the list in the profile's DNS tab. `.local` names (AirPrint, AirDrop) are not DNS and keep working.
- **Your network settings are not changed**, only macOS's live state: it goes back when the VPN turns off, on Emergency Restore and when the helper stops, and a restart of the Mac starts from your own settings.

### Kill switch

- **With a kill switch on any active route, everything outside the tunnel is blocked the moment you turn the VPN on**, and the servers are checked behind that block. If the VPN cannot connect, the block is lifted and the network is as it was.
- Turning the VPN off right while it was connecting could leave sing-box running for a moment after the switch showed off. Fixed.
- **Fewer dropped connections on network changes.** A Wi-Fi switch or waking from sleep no longer restarts sing-box at once; it restarts only after 12 seconds without any answer.
- Devices with local IPv6 addresses (`fd…`) are reachable when the profile allows the local network. Ping meant for a route through servers is refused at once instead of filling the log.

### Hotel and café Wi-Fi

- When the VPN reconnects behind its kill switch and the network wants a login, Silent Route notices and keeps everything blocked.
- **Open Login Page** (notification, menu bar, window) opens a small browser window whose traffic alone goes out directly. It keeps no cookies or history.
- Once you have logged in, the VPN carries on **through the same server, with the same address**, since sing-box was never restarted.

### Privacy and logs

- **Profiles belong to each macOS user.** On a shared Mac nobody can see another's servers or passwords, from the app or from `sroute`. The VPN itself is one for the whole Mac: while another user's VPN is on, you see only that it is on and may turn it off.
- **Session logs** in `~/Library/Logs/Silent Route`, readable only by you, and in the app under **Logs**: connecting, reconnects with the reason, failovers, profile switches, sleep and wake, sing-box's warnings and errors. **Problems** narrows a log to what went wrong; **Share** can remove addresses, host names and the names of your profiles, routes and servers, so a log can be shown to someone safely. The last 30 sessions are kept, out of Time Machine and Spotlight by default.
- **Settings › Advanced › Log every connection** records which app went to which site, through which route and server. Off by default.

### Updates

- **With the VPN on, nothing leaks during an update.** Everything outside the tunnel stays blocked while the helper is replaced, and the VPN comes back by itself with the same profile. With the VPN off, the network is not touched.
- **A window shows the update's progress.** **Cancel** stops a download with nothing changed; while the helper is replaced, it turns the VPN off instead. If the new helper cannot start, the previous one is put back. If neither starts, the block stays until you click **Restore Network** or restart the Mac.
- **Installing asks GitHub again first**, so it installs the newest release, not one found hours ago. **Check Now** is always there; automatic checks run every 6 hours.
- With the app and the helper on different versions, the VPN can still be turned off and Emergency Restore still works.

### Advanced options

All off by default, where they apply:

- **Tunnel MTU** (profile › Network): for networks where pages load halfway and hang (a phone hotspot, some hotels); try 1400 or 1280.
- **Multiplexing** (server › Advanced): many connections inside a few, with optional padding. The server must have it enabled with the same protocol (h2mux, smux or yamux).
- **TLS fragmentation** (route editor): splits the first packet of a secure connection, which carries the site's name in the clear, so filtering looking for the name does not recognise it. Meant for direct routes.

### Interface

- **The VPN switch is at the top of the sidebar**, with the connection time and speed.
- **Toolbars like Apple's apps:** each page's view switch centred (a profile's Routes / Servers / DNS / Network, Monitor's Apps / Connections, Logs' All / Problems), actions on the trailing side, **Save** and **Revert** there too.
- **A profile's name is the page's title**, large and editable. Profile pages take the window's width, and switching profiles stays on the same page.
- **Everything is in the menu bar too**, with shortcuts: New Profile (⌘N), Import (⌘O), Export (⇧⌘E), Monitor, Logs, Active Profile (⌘1–⌘3), Turn VPN On / Off (⇧⌘T), Emergency Restore.
- **Settings as toolbar panes**: General, Notifications, Updates, Advanced. **Transparency** (General) sets how see-through the menu bar panel is; on macOS 26 *More* uses the clear Liquid Glass.
- **Monitor is laid out like Activity Monitor's Network tab**, every column sortable, with a chart of the whole session, including the time Monitor was closed. **Pin to Top** keeps an app or an app's traffic to a site at the top; **Add to Route…** puts an app or a site into an existing or a new route of any profile, saved at once.
- **Connection time and traffic** (Settings › General): per connection, or from turning the VPN on until turning it off.

### Security

- The helper (root) never follows a path a user could have prepared: logs are written into the user's folder without following symbolic links, each file created new; sing-box's folders are checked along with the binary.
- The Wi-Fi login proxy's password never appears on a command line, where any user could read it with `ps`.
- The helper refuses a request it cannot attribute to a user, and runs at most three server checks at once.
- A profile save that cannot be written (a full disk) is reported and nothing changes. Links, rule lines and profiles are fuzz-tested.
- Uninstalling asks whether to delete the session logs as well; app cleaners such as AppCleaner remove them too.

[docs/network.md](docs/network.md) describes every connection Silent Route makes or lets through, how DNS is resolved, what the kill switch lets out, and the Wi-Fi login step by step.

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
