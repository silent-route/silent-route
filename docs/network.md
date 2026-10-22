# How Silent Route uses the network

Everything Silent Route sends or lets through, by whom, where to, and when. It covers the VPN on, the VPN off, network changes and Wi-Fi logins.

## Who talks to the network

| Component | Runs as | Talks to |
|---|---|---|
| **sing-box** | root, group `_silentroute` | Your servers, direct destinations, DNS servers, rule-set downloads. The only process the kill switch lets out. |
| **Helper** | root | Only `127.0.0.1` (sing-box's control API). It also runs `curl` once in a while for the Wi-Fi login check, through sing-box. |
| **App** | you | `127.0.0.1` (live stats), GitHub (update checks), and a temporary sing-box when you press **Check** on a server. |
| **Login window** | you | Only the Wi-Fi login proxy on `127.0.0.1`, while a network wants a login. |

## Every connection

| What | From → to | Path | When |
|---|---|---|---|
| Your apps' traffic | Any app → sites and services | Into the tunnel interface, then by your routes: through a server, direct, or blocked | VPN on |
| Your apps' DNS | macOS resolver → `172.19.0.6` (inside the tunnel) → sing-box | By the profile's DNS rules (see [DNS](#dns)) | VPN on |
| A route's DNS | sing-box → the profile's DNS-over-HTTPS server (default `1.1.1.1:443`) | Through that route's server, so a name is looked up where its traffic goes | Names of routes that go through servers, and of *Everything else* |
| Direct DNS | sing-box → the profile's direct resolver (default `1.1.1.1:53`, UDP) | Direct | Names of routes that go direct, *Always resolved directly* zones, and your servers' own host names |
| Local names | sing-box → your router's DNS, as DHCP gives it | Direct, over the local network | Only names in the profile's local zones (default `lan`, `home.arpa`, `internal`), and only while the local network is reachable directly |
| Server health checks | Helper → sing-box → each server in use → `www.gstatic.com/generate_204` (HTTP) | Through each server | Every 10 s while connected; every 2 s for a while after a network change |
| Address and site lists | sing-box → `raw.githubusercontent.com:443` (SagerNet rule-sets) | Direct | The first time a profile uses a list, then weekly; cached |
| Wi-Fi login check | Helper → `curl` → login proxy → `captive.apple.com:80` (HTTP) | Direct, with the router's DNS | Only while reconnecting behind the kill switch and no server answers |
| Wi-Fi login page | Login window → login proxy → the network's login page | Direct, with the router's DNS | While a network wants a login and you have the window open |
| Server **Check** | Helper → temporary sing-box (the kill switch's group, bound to the physical interface) → the server → `ipinfo.io:443` | Direct to the server, the way the VPN reaches it — also while the VPN is on, so the latency is the server's own | When you press Check |
| Update check | App → `api.github.com:443` (this project's releases) | Your routes, like any app | Once a day if enabled (Settings › Updates), or when you ask |
| Update download | App → `github.com:443` (release asset) | Your routes, like any app | When you install an update |
| Control and stats | App ↔ helper (XPC); app/helper → sing-box API on `127.0.0.1` | Local only | Always local |

There is no telemetry, no analytics and no account. Nothing is sent while the VPN is off except update checks (if enabled) and server Checks you start.

## The kill switch

While any route through servers has its kill switch on, pf (macOS's packet filter) lets out on the physical network only:

1. **sing-box's own traffic**, identified by its group. Whatever the routes decide, traffic leaves through sing-box or not at all.
2. **Loopback** (`127.0.0.1`), and the tunnel interface itself.
3. **DHCP**, so the Mac keeps its address on the network.
4. **The local network** (printers, AirDrop, a NAS), if the profile allows it. **DNS (ports 53 and 853) to the local network is the exception**: only sing-box may ask the router, so nothing else can show it the names you look up.
5. **IPv6 link-local and multicast** (needed by macOS for the local network), again without DNS.

Everything else is dropped. It stays that way while sing-box restarts, so nothing slips out during a reconnect. pf is changed only through Silent Route's own anchor (`com.apple/silentroute`); the system's rules and other VPNs' rules are never touched.

## DNS

While the VPN is on, macOS's resolver is pointed at `172.19.0.6`, an address inside the tunnel, where sing-box answers. Without this, most networks would send every lookup to the router, past the tunnel, and the router and the provider behind it would see every site you open.

- The change is made only in macOS's live network state, never in your saved network settings. It is undone when the VPN turns off, on Emergency Restore, and when the helper stops. A restart of the Mac starts from your own settings, untouched.
- What was there before is saved on disk. If the helper crashes, it puts it back when it starts again.
- If the network rewrites its DNS (a new Wi-Fi, a DHCP renewal), the helper points it back within seconds. Meanwhile the kill switch keeps anything but sing-box from asking the router.

How sing-box answers each name:

| Name | Resolved by | Path |
|---|---|---|
| In a local zone (`nas.lan`) | Your router | Direct, local network |
| Matching a route that goes through servers | The profile's DoH server | Through that route's server |
| Matching a route that goes direct, or an *Always resolved directly* zone | The profile's direct resolver | Direct |
| Matching a blocked route | Not resolved | — |
| Anything else | Like *Everything else* | Its server, or direct |
| A server's own host name | The profile's direct resolver | Direct (a tunnel cannot resolve its own server) |

Names ending in `.local` (AirPrint, AirDrop, Bonjour) use multicast DNS, not DNS, and keep working as usual.

## Network changes and sleep

When the network changes (another Wi-Fi, waking from sleep), sing-box keeps running. The helper checks the servers every 2 seconds and restarts sing-box only if none has answered for 12 seconds. Short drops pass without breaking calls or downloads. Routes with a kill switch stay blocked the whole time.

## Logging in to a hotel or café Wi-Fi

Some networks let nothing through until you log in on their web page. Turning the VPN off to log in would let everything on the Mac out directly the moment the network accepts you. Silent Route keeps the VPN on and opens a single, narrow way out instead:

1. **You arrive with the VPN on.** The old network is gone, the tunnel drops, and the kill switch blocks everything.
2. **The helper notices** that no server answers on the new network. It asks Apple's check page (`captive.apple.com`) through sing-box's login proxy, which goes direct. A network that wants a login answers with its login page instead of "Success".
3. **sing-box keeps running**, with the kill switch on. You get a notification, and **This Wi-Fi needs a login** appears in the menu bar and the window.
4. **Open Login Page** opens a small browser window inside Silent Route. Its traffic, and nothing else on the Mac, goes out directly through the login proxy, using the router's DNS. The proxy listens only on `127.0.0.1`, takes a new password every time sing-box starts, and only the app of the user who turned the VPN on gets it. The window keeps no cookies or history.
5. **You log in.** The network starts letting traffic through, and the servers answer the next check (every 3 seconds).
6. **The VPN carries on** through the same server, with the same address as before you left. sing-box was never restarted. The login proxy closes, and the kill switch was on throughout.

If you turn the VPN on for the first time while on such a network, it does not connect, and nothing changes: the network stays as it was before you pressed the switch. Log in first (Safari or macOS's own login window will offer it), then turn the VPN on.

## When the VPN is off

Nothing of Silent Route is in the way: no pf rules, no DNS change, no tunnel. After a restart of the Mac the VPN never starts by itself, and the network is exactly as macOS set it up.
