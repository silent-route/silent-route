#!/bin/bash
# End-to-end check of Silent Route on a real Mac: real pf, real sing-box,
# real network. Run with sudo from a terminal:
#
#   sudo ./experiments/integration/run.sh
#
# Another VPN must be off: the run refuses to start otherwise. It takes
# about three minutes; during it the Mac is on Silent Route (or deliberately
# blocked). At the end — also if anything fails or you press Ctrl-C — the
# VPN is turned off and the script checks that the internet works.
#
# Prerequisite: the helper is installed (from the app) and a profile with at
# least one working server is active.
#
# Results: terminal and results.txt next to this script.

set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/results.txt"
SROUTE=/usr/local/bin/sroute
ANCHOR="com.apple/silentroute"
SB_BIN="/Library/Application Support/Silent Route/bin/sing-box"
IFACE=$(scutil <<< 'show State:/Network/Global/IPv4' | awk '/PrimaryInterface/ {print $3}')
PASS=0 FAIL=0

exec > >(tee "$OUT") 2>&1

ok()   { PASS=$((PASS+1)); echo "  ✅ $*"; }
bad()  { FAIL=$((FAIL+1)); echo "  ❌ $*"; }
step() { echo; echo "── $*"; }
ip_now() { curl -s -m 10 https://ipinfo.io/ip 2>/dev/null; }
reach_phys() { curl -s -o /dev/null --interface "$IFACE" -m "${2:-6}" -w '%{http_code}' "$1" 2>/dev/null | grep -qv '^000$'; }
reach()  { curl -s -o /dev/null -m "${2:-6}" -w '%{http_code}' "$1" 2>/dev/null | grep -qv '^000$'; }
sb_pid() { pgrep -f "^$SB_BIN run" | head -1; }
# Routes through the TUN's own address: sing-box's (docs/network.md).
our_routes() { netstat -rn | awk '$2 == "172.19.0.5" || $2 == "fdfe:dcba:9876::5"' | grep -c .; }

# Counts packets on the physical interface matching a filter while a
# command runs. Anything above zero leaked past the tunnel.
count_on_phys() {
  local filter=$1; shift
  local cap; cap=$(mktemp)
  tcpdump -i "$IFACE" -n -l "$filter" > "$cap" 2>/dev/null &
  local td=$!
  sleep 1
  "$@" >/dev/null 2>&1
  sleep 1
  kill $td 2>/dev/null; wait $td 2>/dev/null
  grep -c . "$cap"
  rm -f "$cap"
}

restore() {
  step "restoring"
  "$SROUTE" down >/dev/null 2>&1 || "$SROUTE" panic >/dev/null 2>&1
  # The run must leave the Mac exactly as usable as it found it.
  if reach https://ipinfo.io 10; then
    echo "  ✅ internet works after the test"
  else
    FAIL=$((FAIL+1))
    echo "  ❌ NO INTERNET after the test — run: sroute panic"
  fi
  echo
  echo "passed: $PASS   failed: $FAIL"
  echo "saved to $OUT"
}
trap restore EXIT
trap 'exit 130' INT TERM

echo "Silent Route integration test — $(date '+%F %T'), macOS $(sw_vers -productVersion) $(uname -m), $IFACE"

step "prerequisites"
[ -x "$SROUTE" ] || { echo "  sroute not installed — install the helper first"; exit 1; }
"$SROUTE" status >/dev/null 2>&1 || { echo "  the helper does not answer"; exit 1; }
"$SROUTE" routes | grep -q '' || { echo "  no active profile — create one in the app"; exit 1; }
ok "helper answers, a profile is active"

step "1. starting point"
# Nothing else may be tunnelling, or every check below is meaningless.
other=$("$SROUTE" diag | awk -F': ' '/^other VPN/ {print $2}')
[ -z "$other" ] || [ "$other" = none ] || { bad "another VPN is still active ($other); turn it off and rerun"; exit 1; }
DIRECT=$(ip_now)
[ -n "$DIRECT" ] && ok "direct internet works ($DIRECT)" || { bad "no direct internet; cannot test"; exit 1; }
reach_phys https://1.1.1.1 6 && ok "requests bound to $IFACE work before connecting" \
  || { bad "requests bound to $IFACE fail even before connecting; the blocking checks would prove nothing"; exit 1; }

step "2. connect"
"$SROUTE" up || { bad "sroute up failed — nothing else can be tested"; exit 1; }
EXIT=$(ip_now)
if [ -n "$EXIT" ] && [ "$EXIT" != "$DIRECT" ]; then ok "traffic leaves through the tunnel ($EXIT)"; else bad "exit address '$EXIT' (direct: $DIRECT)"; fi
pfctl -a "$ANCHOR" -s rules 2>/dev/null | grep -q 'block drop out quick all' && ok "kill switch loaded" || bad "kill switch not loaded"
[ "$(ps -o gid= -p "$(sb_pid)" | tr -d ' ')" = "$(dscl . -read /Groups/_silentroute PrimaryGroupID | awk '{print $2}')" ] \
  && ok "sing-box runs with the _silentroute group" || bad "sing-box group is wrong"
reach_phys https://1.1.1.1 4 && bad "a request bound to $IFACE got out past the kill switch" || ok "requests bound to $IFACE are blocked"

step "3. leaks while connected"
n=$(count_on_phys "host 1.1.1.1" curl -s -m 8 https://1.1.1.1/cdn-cgi/trace)
[ "$n" = 0 ] && ok "1.1.1.1 reached only through the tunnel" || bad "$n packets to 1.1.1.1 on $IFACE"
n=$(count_on_phys "port 53" sh -c 'for d in example.com wikipedia.org github.com; do dscacheutil -q host -a name $d; done')
[ "$n" = 0 ] && ok "no foreign DNS queries on $IFACE" || bad "$n DNS packets on $IFACE besides the direct resolver"
n=$(count_on_phys "ip6 and not (net fe80::/10 or net ff00::/8)" curl -s -6 -m 5 https://ipv6.google.com)
[ "$n" = 0 ] && ok "no IPv6 outside the tunnel" || bad "$n IPv6 packets on $IFACE"

step "3b. direct by address (only if a route sends addresses direct)"
FIRST_DIRECT=$(python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); t=[i for i in c["inbounds"] if i["type"]=="tun"][0]; print(next((a.split("/")[0] for a in t.get("route_exclude_address",[]) if ":" not in a and not a.startswith(("10.","192.168.","172."))), ""))' \
  "/Library/Application Support/Silent Route/run/config.json" 2>/dev/null)
if [ -z "$FIRST_DIRECT" ]; then
  echo "  (the active profile has no such route: skipped)"
else
  n=$(our_routes)
  [ "$n" -gt 100 ] && ok "the tunnel takes the rest of the internet in $n routes" || bad "only $n routes through the tunnel"
  [ "$(route -n get "$FIRST_DIRECT" | awk '/interface:/ {print $2}')" = "$IFACE" ] \
    && ok "$FIRST_DIRECT goes by $IFACE" || bad "$FIRST_DIRECT does not go by $IFACE"
  [ "$(route -n get 1.1.1.1 | awk '/interface:/ {print $2}')" != "$IFACE" ] \
    && ok "1.1.1.1 still goes into the tunnel" || bad "1.1.1.1 goes by $IFACE"
  # One UDP socket: first to a direct address, then to a STUN server, which
  # says what address it sees. It must be the tunnel's, as for a socket
  # that never sent anything direct — sing-box once sent such a socket's
  # whole traffic direct.
  STUN=$(mktemp)
  cat > "$STUN" <<'PY'
import os, socket, struct, sys
def stun(s):
    tid = os.urandom(12)
    s.sendto(struct.pack(">HHI", 1, 0, 0x2112A442) + tid, (socket.gethostbyname("stun.cloudflare.com"), 3478))
    s.settimeout(6)
    d, _ = s.recvfrom(2048)
    i = 20
    while i < len(d):
        t, l = struct.unpack(">HH", d[i:i+4]); v = d[i+4:i+4+l]
        if t == 0x20: return socket.inet_ntoa(bytes(a ^ b for a, b in zip(v[4:8], struct.pack(">I", 0x2112A442))))
        i += 4 + l + (-l % 4)
fresh = stun(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b"x", (sys.argv[1], 9))
print(fresh, stun(s))
PY
  read -r FRESH AFTER <<< "$(python3 -I "$STUN" "$FIRST_DIRECT" 2>/dev/null)"
  rm -f "$STUN"
  if [ -n "$AFTER" ] && [ "$AFTER" = "$FRESH" ] && [ "$AFTER" != "$DIRECT" ]; then
    ok "a socket that first went direct still sends the rest through the tunnel"
  else
    bad "after a direct packet the STUN server saw '$AFTER' (tunnel: '$FRESH', direct: $DIRECT)"
  fi
fi

step "4. sing-box killed: the kill switch must hold"
kill -9 "$(sb_pid)" 2>/dev/null
sleep 1
n=$(count_on_phys "host 1.1.1.1" curl -s -m 5 https://1.1.1.1/cdn-cgi/trace)
[ "$n" = 0 ] && ok "nothing reached 1.1.1.1 directly while down" || bad "$n packets leaked to 1.1.1.1"
# Bound to the physical interface, as a leaking app would be. The reconnect
# may already be done by now, so a plain request proves nothing.
reach_phys https://1.1.1.1 4 && bad "a request bound to $IFACE got out" || ok "requests bound to $IFACE are blocked"
for _ in $(seq 1 40); do "$SROUTE" status | grep -q Connected && break; sleep 1; done
"$SROUTE" status | grep -q Connected && ok "reconnected by itself" || bad "did not reconnect in 40 s: $("$SROUTE" status | tr '\n' ' ')"
[ "$(ip_now)" = "$EXIT" ] && ok "exit address back to $EXIT" || bad "exit address after reconnect: $(ip_now)"

step "5. helper killed: launchd restarts it, still no leak"
kill -9 "$(pgrep -f '/Silent Route/bin/SilentRouteHelper$' | head -1)" 2>/dev/null
n=$(count_on_phys "host 1.1.1.1" sh -c 'for i in 1 2 3; do curl -s -m 3 https://1.1.1.1/cdn-cgi/trace; sleep 1; done')
[ "$n" = 0 ] && ok "no direct traffic during the helper restart" || bad "$n packets leaked during the helper restart"
for _ in $(seq 1 40); do "$SROUTE" status 2>/dev/null | grep -q Connected && break; sleep 1; done
"$SROUTE" status | grep -q Connected && ok "helper back and connected" || bad "not connected 40 s after the helper restart"
[ "$(pgrep -f "^$SB_BIN run" | wc -l | tr -d ' ')" = 1 ] && ok "exactly one sing-box running" || bad "sing-box count: $(pgrep -f "^$SB_BIN run" | wc -l)"

step "6. disconnect: the network must be exactly as before"
"$SROUTE" down >/dev/null
[ -z "$(pfctl -a "$ANCHOR" -s rules 2>/dev/null)" ] && ok "kill switch removed" || bad "rules left in $ANCHOR"
[ -z "$(sb_pid)" ] && ok "sing-box stopped" || bad "sing-box still running"
ifconfig | grep -q 'inet 172.19.0.5 ' && bad "TUN interface left behind" || ok "TUN interface gone"
[ "$(our_routes)" = 0 ] && ok "no routes into the tunnel left" || bad "$(our_routes) routes into the tunnel left"
[ "$(ip_now)" = "$DIRECT" ] && ok "direct internet back ($DIRECT)" || bad "after down the exit address is '$(ip_now)'"
reach_phys https://1.1.1.1 6 && ok "requests bound to $IFACE work again" || bad "requests bound to $IFACE still blocked"

step "7. panic from connected"
"$SROUTE" up >/dev/null || bad "could not connect again: $("$SROUTE" status | tail -1)"
"$SROUTE" panic >/dev/null
[ -z "$(pfctl -a "$ANCHOR" -s rules 2>/dev/null)" ] && ok "panic removed the kill switch" || bad "rules left in $ANCHOR after panic"
[ -z "$(sb_pid)" ] && ok "panic stopped sing-box" || bad "sing-box still running after panic"
[ "$(our_routes)" = 0 ] && ok "panic left no routes into the tunnel" || bad "$(our_routes) routes into the tunnel left after panic"
reach https://ipinfo.io 8 && ok "network works after panic" || bad "no internet after panic"

step "helper log"
tail -30 /Library/Logs/Silent Route/helper.log | sed 's/^/  /'
