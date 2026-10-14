# Changelog

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
