#!/bin/bash
# Phase 0, experiment 1: can pf tell sing-box's sockets apart by group?
#
#   sudo ./experiments/pf-group/run.sh
#
# Safe to run with another VPN up. It touches exactly one address, a public
# DNS resolver nothing else on the Mac is expected to use, for about a
# minute, in a separate sub-anchor of com.apple. It never runs `pfctl -f`
# or `pfctl -d`, so any other ruleset stays as it is. The anchor is flushed on
# exit, including Ctrl-C.
#
# Results go to the terminal and to results.txt next to this script.

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ANCHOR="com.apple/zz.silentroute.exp"
TARGET=149.112.112.112
GID=4242          # the experiment does not need a real group record
OUT="$HERE/results.txt"
WORK=$(mktemp -d)
TOKEN=""

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

IFACE=$(scutil <<< 'show State:/Network/Global/IPv4' | awk '/PrimaryInterface/ {print $3}')
[ -n "$IFACE" ] || { echo "no primary interface"; exit 1; }

cleanup() {
  pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
  [ -n "$TOKEN" ] && pfctl -X "$TOKEN" >/dev/null 2>&1
  pkill -f "$WORK/sb.json" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

exec > >(tee "$OUT") 2>&1

echo "Silent Route phase 0 / pf group match — $(date '+%F %T')"
echo "macOS $(sw_vers -productVersion) ($(uname -m)), interface $IFACE, target $TARGET"
echo

clang -O2 -o "$WORK/nettest" "$HERE/nettest.c" || { echo "clang failed"; exit 1; }
NT="$WORK/nettest"

if ! pfctl -sr 2>/dev/null | grep -q 'anchor "com.apple/\*"'; then
  echo "The main pf ruleset has no 'anchor \"com.apple/*\"' — this sub-anchor"
  echo "would never be evaluated. Stopping without changes."
  exit 1
fi

TOKEN=$(pfctl -E 2>&1 | awk '/Token/ {print $3}')

load_rules() {
  # $1: extra rules placed before the final block
  printf '%s\nblock drop out quick on %s proto { tcp udp } to %s\n' "$1" "$IFACE" "$TARGET" \
    | pfctl -a "$ANCHOR" -f - || { echo "pfctl refused the rules"; exit 1; }
}

row() {
  # $1: label, $2: expected, rest: nettest credential options
  local label=$1 want=$2; shift 2
  local line="" all=ok
  for m in tcp udp-conn udp-unconn; do
    local got; got=$("$NT" "$@" probe $m "$TARGET" 53 "$IFACE" | head -1)
    line+=$(printf ' %-11s' "$got")
    [ "$got" = "$want" ] || all=MISMATCH
  done
  printf '%-44s want %-7s |%s  %s\n' "$label" "$want" "$line" "$all"
}

echo "                                                       tcp         udp-conn    udp-unconn"
pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
row "1. no rules, root/wheel (baseline)"         OK
load_rules ""
row "2. block only, root/wheel"                  BLOCKED
row "3. block only, root/gid $GID"               BLOCKED  --gid $GID
load_rules "pass out quick on $IFACE proto { tcp udp } to $TARGET group $GID keep state"
row "4. pass group $GID: root/wheel"             BLOCKED
row "5. pass group $GID: root/gid $GID  << KEY"  OK       --gid $GID
row "6. pass group $GID: nobody/gid $GID"        OK       --gid $GID --uid 4294967294
row "7. pass group $GID: root/wheel +supp $GID"  BLOCKED  --supp $GID
row "8. pass group $GID: uid 501/staff"          BLOCKED  --gid 20 --uid 501
load_rules "pass out quick on $IFACE proto { tcp udp } to $TARGET user 0 keep state"
row "9. pass user 0: root/wheel (sanity)"        OK

# The real thing: sing-box's own Go sockets. Its DNS client resolves through
# $TARGET over UDP from the physical interface; with the group rule in place
# it must work only when sing-box runs with gid $GID.
SB=$(command -v sing-box || echo /usr/local/bin/sing-box)
if [ -x "$SB" ]; then
  cat > "$WORK/sb.json" <<EOF
{
  "log": {"level": "warn"},
  "dns": {"servers": [{"type": "udp", "tag": "d", "server": "$TARGET", "bind_interface": "$IFACE"}],
          "final": "d", "strategy": "ipv4_only"},
  "inbounds": [{"type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": 11098}],
  "outbounds": [{"type": "direct", "tag": "direct", "bind_interface": "$IFACE"}],
  "route": {"final": "direct", "default_domain_resolver": "d"}
}
EOF
  load_rules "pass out quick on $IFACE proto { tcp udp } to $TARGET group $GID keep state"
  sbtest() {
    local label=$1 want=$2; shift 2
    "$NT" "$@" exec "$SB" run -c "$WORK/sb.json" > "$WORK/sb.log" 2>&1 &
    local pid=$!
    sleep 2
    local code; code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
                       --socks5-hostname 127.0.0.1:11098 "https://example.com/?$RANDOM")
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    local got=BLOCKED; [ "$code" != "000" ] && got=OK
    printf '%-44s want %-7s | sing-box DNS: %-8s (http %s)  %s\n' "$label" "$want" "$got" "$code" \
      "$([ "$got" = "$want" ] && echo ok || echo MISMATCH)"
  }
  sbtest "10. sing-box as root/gid $GID"   OK      --gid $GID
  sbtest "11. sing-box as root/wheel"      BLOCKED
else
  echo "10-11. skipped: sing-box not found"
fi

echo
echo "Rows 5 and 10 OK with 4, 7, 11 BLOCKED => variant A (group match) works."
echo "Saved to $OUT"
