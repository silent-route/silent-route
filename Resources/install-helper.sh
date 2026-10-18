#!/bin/bash
# Installs, updates or removes Silent Route's privileged helper. Runs as root:
# the app starts it through the standard administrator password prompt, or by
# hand:
#
#   sudo /Applications/Silent Route.app/Contents/Resources/install-helper.sh install
#   sudo "/Library/Application Support/Silent Route/uninstall.sh" uninstall   (a copy of this script)
#
# install   First install and update are the same: the new files are staged
#           next to the old ones and swapped in at once. The previous
#           binaries and a copy of the profiles are kept; if the new helper
#           does not answer within 15 s, the previous one is put back.
#           Profiles are never overwritten by an install.
# uninstall [--yes] [--user NAME] [--keep-profiles] [--keep-logs]
#           Stops the helper (which disconnects and lifts the kill switch),
#           makes sure no Silent Route rule or process is left, then deletes
#           everything: helper, profiles, logs, the _silentroute group, the
#           sroute command, NAME's (default: the sudo user's) app settings,
#           and every user's session logs (~/Library/Logs/Silent Route) unless
#           --keep-logs.
#           The app itself is moved to the Trash by the app, or left for you.
#
# Safe to run any number of times, and with the VPN on.

set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin

[ "$(id -u)" = 0 ] || { echo "must run as root: sudo $0 $*" >&2; exit 1; }

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="/Library/Application Support/Silent Route"
LOGS="/Library/Logs/Silent Route"
LABEL="org.silentroute.app.helper"
BUNDLE_ID="org.silentroute.app"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
GROUP="_silentroute"
ANCHOR="com.apple/silentroute"

note() { echo "• $*"; }

stop_helper() {
  if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    # SIGTERM: the helper disconnects and leaves the network clean.
    launchctl bootout "system/$LABEL" 2>/dev/null || true
    for _ in $(seq 1 50); do
      launchctl print "system/$LABEL" >/dev/null 2>&1 || break
      sleep 0.1
    done
  fi
}

helper_answers() {
  for _ in $(seq 1 30); do
    "$ROOT/bin/sroute" status >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

ensure_group() {
  if dscl . -read "/Groups/$GROUP" PrimaryGroupID >/dev/null 2>&1; then return; fi
  # A free system gid between 300 and 499.
  local used gid
  used=$(dscl . -list /Groups PrimaryGroupID | awk '{print $2}')
  for gid in $(seq 300 499); do
    echo "$used" | grep -qx "$gid" || break
  done
  dscl . -create "/Groups/$GROUP"
  dscl . -create "/Groups/$GROUP" PrimaryGroupID "$gid"
  dscl . -create "/Groups/$GROUP" RealName "Silent Route sing-box"
  dscl . -create "/Groups/$GROUP" Password '*'
  note "created group $GROUP ($gid)"
}

write_plist() {
  cat > "$PLIST.tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>              <string>$LABEL</string>
  <key>ProgramArguments</key>   <array><string>$ROOT/bin/SilentRouteHelper</string></array>
  <key>MachServices</key>       <dict><key>$LABEL</key><true/></dict>
  <key>RunAtLoad</key>          <true/>
  <key>KeepAlive</key>          <true/>
  <key>ProcessType</key>        <string>Interactive</string>
  <key>StandardErrorPath</key>  <string>$LOGS/helper.log</string>
  <key>StandardOutPath</key>    <string>$LOGS/helper.log</string>
</dict>
</plist>
EOF
  chown root:wheel "$PLIST.tmp"
  chmod 0644 "$PLIST.tmp"
  mv -f "$PLIST.tmp" "$PLIST"
}

# ── helpers registered under another label ──────────────────────────────────
# An earlier build may have used another identifier. Whatever its label, a
# launch daemon that runs our helper binary is ours: stop it and remove it,
# so exactly one helper is ever registered.

remove_stale_daemons() {
  local f label
  for f in /Library/LaunchDaemons/*.plist; do
    [ -f "$f" ] && [ "$f" != "$PLIST" ] || continue
    grep -qF "$ROOT/bin/SilentRouteHelper" "$f" 2>/dev/null || continue
    label=$(defaults read "$f" Label 2>/dev/null) || continue
    launchctl bootout "system/$label" 2>/dev/null || true
    for _ in $(seq 1 50); do launchctl print "system/$label" >/dev/null 2>&1 || break; sleep 0.1; done
    rm -f "$f"
    note "removed an earlier helper registration ($label)"
  done
}

# ── install / update ────────────────────────────────────────────────────────

do_install() {
  local contents arch sb version stage
  contents=$(cd "$HERE/.." && pwd)
  case "$(uname -m)" in
    arm64) arch=arm64 ;;
    x86_64) arch=amd64 ;;
    *) echo "unsupported CPU $(uname -m)" >&2; exit 1 ;;
  esac
  sb="$contents/Resources/sing-box/sing-box-darwin-$arch"
  [ -x "$sb" ] || { echo "missing $sb — run this from inside Silent Route.app" >&2; exit 1; }
  [ -x "$contents/MacOS/SilentRouteHelper" ] && [ -x "$contents/MacOS/sroute" ] || { echo "missing helper binaries" >&2; exit 1; }
  version=$(defaults read "$contents/Info.plist" CFBundleVersion 2>/dev/null || echo unknown)

  ensure_group
  install -d -o root -g wheel -m 0755 "$ROOT" "$ROOT/rules"
  # Root's own log folder: helper.log (state changes, errors). Session logs
  # live in each user's home instead.
  install -d -o root -g wheel -m 0700 "$LOGS"
  chmod 0700 "$LOGS"
  [ -f "$LOGS/helper.log" ] || install -o root -g wheel -m 0600 /dev/null "$LOGS/helper.log"
  chmod 0600 "$LOGS/helper.log"
  install -d -o root -g wheel -m 0700 "$ROOT/run" "$ROOT/backups"

  # 1. Stage the new files next to the current ones; nothing running changes yet.
  stage="$ROOT/bin.new"
  rm -rf "$stage"
  install -d -o root -g wheel -m 0755 "$stage"
  # Copies, not links: root must only run files that no user can change.
  install -o root -g wheel -m 0755 "$contents/MacOS/SilentRouteHelper" "$stage/SilentRouteHelper"
  install -o root -g wheel -m 0755 "$contents/MacOS/sroute" "$stage/sroute"
  install -o root -g wheel -m 0755 "$sb" "$stage/sing-box"
  echo "$version" > "$stage/VERSION"
  chmod 0644 "$stage/VERSION"

  # 2. Keep a copy of the profiles (the last ten installs).
  if [ -f "$ROOT/profiles.json" ]; then
    cp -p "$ROOT/profiles.json" "$ROOT/backups/profiles-$(date +%Y%m%d-%H%M%S).json"
    ls -1t "$ROOT/backups"/profiles-*.json 2>/dev/null | tail -n +11 | while read -r f; do rm -f "$f"; done
  fi

  # 3. Swap: stop the old helper, keep its binaries as bin.prev.
  stop_helper
  remove_stale_daemons
  rm -rf "$ROOT/bin.prev"
  [ -d "$ROOT/bin" ] && mv "$ROOT/bin" "$ROOT/bin.prev"
  mv "$stage" "$ROOT/bin"
  # Address and site lists are not shipped: sing-box downloads the ones a
  # profile uses. Lists already on disk (from earlier builds) stay in use.
  for f in "$contents/Resources/sing-box/rules/"*.srs; do
    [ -f "$f" ] || continue
    install -o root -g wheel -m 0644 "$f" "$ROOT/rules/"
  done
  # The uninstaller lives with the data it removes, so it works without the app.
  install -o root -g wheel -m 0755 "$contents/Resources/install-helper.sh" "$ROOT/uninstall.sh"
  cat > "$ROOT/Uninstall Silent Route.command" <<'EOF'
#!/bin/bash
# Double-click to remove Silent Route completely. Asks for your password.
sudo "/Library/Application Support/Silent Route/uninstall.sh" uninstall --user "$USER"
echo; read -r -p "Press Return to close this window. " _
EOF
  chown root:wheel "$ROOT/Uninstall Silent Route.command"
  chmod 0755 "$ROOT/Uninstall Silent Route.command"

  write_plist
  launchctl bootstrap system "$PLIST"

  # 4. The new helper must answer, or the previous one comes back.
  if ! helper_answers; then
    echo "the new helper does not answer — restoring the previous version" >&2
    stop_helper
    if [ -d "$ROOT/bin.prev" ]; then
      rm -rf "$ROOT/bin.failed"
      mv "$ROOT/bin" "$ROOT/bin.failed"
      mv "$ROOT/bin.prev" "$ROOT/bin"
      launchctl bootstrap system "$PLIST" || true
      helper_answers && echo "previous version restored" >&2
    fi
    exit 1
  fi

  install -d -m 0755 /usr/local/bin
  ln -sf "$ROOT/bin/sroute" /usr/local/bin/sroute
  note "Silent Route helper $version installed"
}

# ── uninstall ───────────────────────────────────────────────────────────────

# Every local user's ~/Library/Logs/Silent Route. Each is in a user's own
# folder, so it is checked first: removed only if it really is that path
# (no symbolic link anywhere on the way), never something it points to.
remove_user_logs() {
  local user home dir real
  dscl . -list /Users NFSHomeDirectory 2>/dev/null | while read -r user home; do
    case "$user" in _*|daemon|nobody) continue ;; esac
    [ -d "$home" ] || continue
    dir="$home/Library/Logs/Silent Route"
    [ -e "$dir" ] || [ -L "$dir" ] || continue
    # A link among the parents: the path leads somewhere else; leave it.
    if [ -L "$home/Library" ] || [ -L "$home/Library/Logs" ]; then continue; fi
    # The folder itself is a link: remove the link only.
    if [ -L "$dir" ]; then rm -f "$dir"; continue; fi
    real=$(cd "$dir" 2>/dev/null && pwd -P) || continue
    [ "$real" = "$(cd "$home" && pwd -P)/Library/Logs/Silent Route" ] || continue
    rm -rf "$real"
    note "session logs of $user removed"
  done
}

do_uninstall() {
  local yes=0 keep=0 keeplogs=0 user=${SUDO_USER:-} answer home
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) yes=1 ;;
      --keep-profiles) keep=1 ;;
      --keep-logs) keeplogs=1 ;;
      --user) user=${2:-}; shift ;;
      *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
  done

  if [ "$yes" = 0 ]; then
    echo "This removes Silent Route completely: the helper, all profiles (tunnels,"
    echo "proxies, rules), logs and settings. The network goes back to normal."
    [ "$keep" = 1 ] && echo "(a copy of the profiles is kept in /Users/Shared/Silent Route profiles)"
    read -r -p "Type 'yes' to continue: " answer
    [ "$answer" = yes ] || { echo "cancelled"; exit 1; }
    if [ "$keeplogs" = 0 ]; then
      read -r -p "Also delete the session logs of every user of this Mac? [Y/n] " answer
      case "$answer" in n|N|no|No) keeplogs=1 ;; esac
    fi
  fi

  # 1. The helper disconnects and lifts the kill switch on its way out.
  stop_helper
  remove_stale_daemons
  # 2. Belt and braces: nothing of ours may stay in pf or keep running, even
  #    if the helper was already gone or broken. Only our own anchor and our
  #    own processes — never anything else's.
  pfctl -a "$ANCHOR" -F all >/dev/null 2>&1 || true
  pkill -f "^$ROOT/bin/sing-box run" 2>/dev/null || true
  pkill -f "^$ROOT/bin/SilentRouteHelper" 2>/dev/null || true
  note "helper stopped, kill switch removed"

  # 3. Files.
  rm -f "$PLIST"
  [ "$(readlink /usr/local/bin/sroute 2>/dev/null)" = "$ROOT/bin/sroute" ] && rm -f /usr/local/bin/sroute
  if [ "$keep" = 1 ] && [ -f "$ROOT/profiles.json" ]; then
    local keepdir="/Users/Shared/Silent Route profiles"
    install -d -m 0700 "$keepdir"
    cp -p "$ROOT/profiles.json" "$keepdir/profiles-$(date +%Y%m%d-%H%M%S).json"
    [ -n "$user" ] && chown -R "$user" "$keepdir"
    note "profiles saved to $keepdir"
  fi
  rm -rf "$ROOT" "$LOGS"
  if [ "$keeplogs" = 0 ]; then remove_user_logs; else note "session logs kept in each user's ~/Library/Logs/Silent Route"; fi
  dscl . -delete "/Groups/$GROUP" 2>/dev/null || true
  note "helper, profiles, logs and the $GROUP group removed"

  # 4. The app's per-user leftovers (what AppCleaner would find).
  if [ -n "$user" ] && home=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | awk '{print $2}') && [ -d "$home" ]; then
    sudo -u "$user" defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
    rm -rf "$home/Library/Preferences/$BUNDLE_ID.plist" \
           "$home/Library/Caches/$BUNDLE_ID" \
           "$home/Library/HTTPStorages/$BUNDLE_ID" \
           "$home/Library/Saved Application State/$BUNDLE_ID.savedState"
    note "app settings of $user removed"
  fi

  # 5. Check.
  if [ -z "$(pfctl -a "$ANCHOR" -s rules 2>/dev/null)" ] && ! launchctl print "system/$LABEL" >/dev/null 2>&1; then
    note "Silent Route removed; the network is back to macOS defaults"
  else
    echo "something is left — reboot to clear it (nothing of Silent Route starts after a reboot)" >&2
    exit 1
  fi
}

case "${1:-}" in
  install) do_install ;;
  uninstall) shift; do_uninstall "$@" ;;
  *) echo "usage: $0 install | uninstall [--yes] [--user NAME] [--keep-profiles] [--keep-logs]" >&2; exit 2 ;;
esac
