#!/bin/sh
# pia-iptv: a PIA VPN gateway container with a kill switch.
#
# Other containers (m3u-editor) join this one's network namespace
# (network_mode: container:pia-iptv / service:pia-iptv) and so reach the internet
# only through the PIA tunnel. LAN clients (TiviMate) reach them on LAN_PORTS.
#
# The VPN layer is adapted from GeorgeAL78/pia-qbittorrent-docker (GPL-3.0):
# token login, region resolution, WireGuard addKey with server failover, OpenVPN
# fallback, the kill switch (policies before flush, every eth0 ACCEPT pinned with
# -d, IPv6 blocked), WireGuard fwmark routing and the in-place reconnect loop. The
# reasons behind those choices are documented in that repository.

# shellcheck source=vpn-thresholds.sh
. /pia/vpn-thresholds.sh

ts() { date +'%Y-%m-%d %H:%M:%S'; }
log() { printf "[%s] [%s] %s\n" "$(ts)" "$1" "$2"; }
die() { log ERROR "$2"; exit "$1"; }

printf " =========================================\n"
printf " ======== PIA IPTV GATEWAY (pia-iptv) ====\n"
printf " =========================================\n"
printf " OS: %s\n" "$(grep PRETTY_NAME= /etc/os-release | cut -d '"' -f 2)"
printf " OpenVPN: %s\n" "$(openvpn --version 2>/dev/null | head -n 1 | cut -d' ' -f2)"
printf " WireGuard: %s\n" "$(wg --version 2>/dev/null | head -n 1 | cut -d' ' -f2)"
printf " Container version: %s\n" "${CONTAINER_VERSION:-unknown}"
printf " =========================================\n\n"

VPN_CLIENT=$(printf '%s' "${VPN_CLIENT:-wireguard}" | tr '[:upper:]' '[:lower:]')
case "$VPN_CLIENT" in wireguard|openvpn) ;; *) die 1 "VPN_CLIENT must be wireguard or openvpn" ;; esac
LAN_PORTS=${LAN_PORTS:-${APP_PORT:-36400}${XTREAM_PORT:+,$XTREAM_PORT}}
for p in $(echo "$LAN_PORTS" | tr ',' ' '); do
  case "$p" in *[!0-9]*|"") die 1 "LAN_PORTS entry '$p' is not a port number" ;; esac
done
VPN_LOG_DIR=/logs
OVPN_STATUS=/run/openvpn.status
TARGET_PATH=/openvpn/target
mkdir -p "$VPN_LOG_DIR" && chmod 700 "$VPN_LOG_DIR"

if [ -n "$TZ" ] && [ -f "/usr/share/zoneinfo/$TZ" ] && [ ! -e /etc/localtime ]; then
  ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
fi

############################################
# Credentials -> /auth.conf (root-only)
############################################
if [ -f /auth.conf ] && [ "$(wc -l < /auth.conf)" -gt 0 ]; then
  log INFO "Using PIA credentials from /auth.conf"
else
  [ -n "$PIA_USERNAME" ] || die 1 "PIA_USERNAME is not set"
  [ -n "$PIA_PASSWORD" ] || die 1 "PIA_PASSWORD is not set"
  umask 077
  printf '%s\n%s\n' "$PIA_USERNAME" "$PIA_PASSWORD" > /auth.conf || die 1 "Cannot write /auth.conf"
  chmod 400 /auth.conf
  umask 022
fi
unset PIA_USERNAME PIA_PASSWORD

############################################
# Pre-firewall window: DNS, server list, token.
# Nothing user-facing runs yet; the kill switch is built right after.
############################################
: > /etc/resolv.conf
for ns in $(echo "${DNS_SERVERS:-9.9.9.9,149.112.112.112}" | tr ',' ' '); do
  echo "nameserver $ns" >> /etc/resolv.conf
done

printf "[%s] [INFO] Refreshing PIA server list..." "$(ts)"
tmp=$(mktemp)
if curl -sSL --max-time 8 --retry 1 https://serverlist.piaservers.net/vpninfo/servers/v6 2>/dev/null | head -n 1 > "$tmp" &&
   jq -e '.regions | length > 0' "$tmp" >/dev/null 2>&1; then
  cat "$tmp" > /pia/data.json; printf "DOWNLOADED %s regions\n" "$(jq -r '.regions|length' /pia/data.json)"
else
  printf "UNREACHABLE - using the %s baked-in regions\n" "$(jq -r '.regions|length' /pia/data.json 2>/dev/null)"
fi
rm -f "$tmp"

# Exact id > exact name > substring, as in pia-qbittorrent.
server=$(printf '%s' "${PIA_REGION:-netherlands}" | tr '[:upper:]' '[:lower:]')
region_match=$(jq -r --arg SERVER "$server" '
  def normalize: gsub("[_-]"; " ") | ascii_downcase | gsub("\\s+"; " ");
  ($SERVER | ascii_downcase) as $raw | ($SERVER | normalize) as $search |
  [.regions[] | select((.id | ascii_downcase) == $raw)] as $exact_id |
  [.regions[] | select((.name | normalize) == $search)] as $exact_name |
  [.regions[] | select((.name | normalize | contains($search)) or (.id | normalize | contains($search)))] as $fuzzy |
  (if ($exact_id|length) > 0 then $exact_id[0] elif ($exact_name|length) > 0 then $exact_name[0]
   elif ($fuzzy|length) > 0 then $fuzzy[0] else null end)
  | if . then "\(.id)|\(.name)" else "|" end' /pia/data.json 2>/dev/null)
region_id=$(echo "$region_match" | cut -d'|' -f1)
region_name=$(echo "$region_match" | cut -d'|' -f2)
[ -n "$region_id" ] || die 1 "PIA_REGION '$PIA_REGION' not found in the PIA server list"
log INFO "Region: $region_name ($region_id), client: $VPN_CLIENT"

# PIA rate-limits logins per account: one token per start, reused by reconnects.
piatoken=""
r=$(curl --connect-timeout 8 --max-time 15 -s --location --request POST \
      'https://www.privateinternetaccess.com/api/client/v2/token' \
      --form "username=$(sed '1!d' /auth.conf)" --form "password=$(sed '2!d' /auth.conf)")
piatoken=$(echo "$r" | jq -r '.token // empty' 2>/dev/null)

############################################
# VPN configuration
############################################
if [ "$VPN_CLIENT" = "wireguard" ]; then
  [ -n "$piatoken" ] || die 3 "PIA would not issue a token ($(echo "$r" | jq -r '.message // .code // "no response"' 2>/dev/null)) - check the username/password"
  log INFO "Got PIA token"
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1

  regiondata=$(jq -e --arg RID "$region_id" '.regions[] | select(.id == $RID)' /pia/data.json) || die 1 "No region data"
  WG_SERVERS=$(echo "$regiondata" | jq -r '.servers.wg[]? | "\(.ip) \(.cn)"')
  [ -n "$WG_SERVERS" ] || die 1 "Region '$region_name' has no WireGuard servers - try VPN_CLIENT=openvpn or another region"
  wg_port=$(jq -r '.groups.wg[0].ports[0]' /pia/data.json)

  # Register a fresh key, trying each server in the region (failover).
  wg_register() {
    WG_PK="$(wg genkey)"; wg_pub="$(echo "$WG_PK" | wg pubkey)"
    rm -f /tmp/.wg.json /tmp/.wg.srv
    echo "$WG_SERVERS" | while read -r s_ip s_cn; do
      [ -z "$s_ip" ] && continue
      out=$(curl -s --connect-timeout 8 --max-time 20 -G --connect-to "$s_cn::$s_ip:" \
        --cacert /pia/ca.rsa.4096.crt --data-urlencode "pt=$piatoken" \
        --data-urlencode "pubkey=$wg_pub" "https://$s_cn:$wg_port/addKey")
      if [ "$(echo "$out" | jq -r '.status' 2>/dev/null)" = "OK" ]; then
        printf '%s\n' "$out" > /tmp/.wg.json; printf '%s %s\n' "$s_ip" "$s_cn" > /tmp/.wg.srv; break
      fi
      log INFO "Server $s_ip did not register the key - trying next"
    done
    [ -s /tmp/.wg.json ] || return 1
    j=$(cat /tmp/.wg.json); WG_IP=$(cut -d' ' -f1 /tmp/.wg.srv); WG_CN=$(cut -d' ' -f2 /tmp/.wg.srv)
    rm -f /tmp/.wg.json /tmp/.wg.srv
    mkdir -p /etc/wireguard
    umask 077
    cat > /etc/wireguard/pia.conf <<EOF
[Interface]
PrivateKey = ${WG_PK}
Address = $(echo "$j" | jq -r '.peer_ip')
Table = off

[Peer]
PublicKey = $(echo "$j" | jq -r '.server_key')
AllowedIPs = 0.0.0.0/0
Endpoint = ${WG_IP}:$(echo "$j" | jq -r '.server_port')
PersistentKeepalive = 25
EOF
    umask 022
    PORT=$(echo "$j" | jq -r '.server_port')
    return 0
  }
  wg_register || die 5 "No server in '$region_name' would register our key - PIA trouble, or try another region"
  log INFO "Registered with $WG_CN ($WG_IP)"
  # All region servers are allowed so reconnect can fail over without firewall changes.
  VPNIPS=$(echo "$WG_SERVERS" | cut -d' ' -f1)
  VPN_DEVICE=pia
else
  [ -e /dev/net/tun ] || { mkdir -p /dev/net; mknod /dev/net/tun c 10 200 && chmod 0600 /dev/net/tun; } || die 1 "No TUN device - add --device /dev/net/tun"
  ovpn_profile=$(printf '%s' "$region_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
  [ -f "/openvpn/nextgen/$ovpn_profile.ovpn" ] || die 1 "No OpenVPN profile for '$region_name' - try VPN_CLIENT=wireguard"
  CONNECTIONSTRING=$(grep 'privacy.network' "/openvpn/nextgen/$ovpn_profile.ovpn")
  PORT=$(echo "$CONNECTIONSTRING" | cut -d' ' -f3)
  PIADOMAIN=$(echo "$CONNECTIONSTRING" | cut -d' ' -f2)
  VPNIPS=$(dig "$PIADOMAIN" +short | grep '^[.0-9]*$')
  [ -n "$VPNIPS" ] || die 3 "Unable to resolve $PIADOMAIN"
  rm -rf "$TARGET_PATH"; mkdir -p "$TARGET_PATH"
  cp -f /openvpn/nextgen/*.crt /openvpn/nextgen/*.pem "$TARGET_PATH"/ 2>/dev/null
  grep -v -e 'privacy.network' -e 'resolv-retry' "/openvpn/nextgen/$ovpn_profile.ovpn" > "$TARGET_PATH/config.ovpn"
  for ip in $VPNIPS; do echo "remote $ip $PORT" >> "$TARGET_PATH/config.ovpn"; done
  cat >> "$TARGET_PATH/config.ovpn" <<EOF
auth-user-pass /auth.conf
auth-retry nointeract
pull-filter ignore "auth-token"
pull-filter ignore "dhcp-option"
mssfix 1300
EOF
  VPN_DEVICE=$(grep '^dev ' "$TARGET_PATH/config.ovpn" | cut -d' ' -f2)0
fi

############################################
# Network discovery
############################################
DEFAULT_GATEWAY=$(ip r | grep 'default via' | cut -d' ' -f3)
INTERFACE=$(ip r | grep 'default via' | cut -d' ' -f5)
SUBNET=$(ip r | grep -v 'default via' | grep "$INTERFACE" | tail -n 1 | cut -d' ' -f1)
[ -n "$DEFAULT_GATEWAY" ] && [ -n "$INTERFACE" ] || die 1 "Cannot detect the container network"
log INFO "Interface $INTERFACE, subnet $SUBNET, gateway $DEFAULT_GATEWAY"

############################################
# Kill switch
############################################
[ "${LEGACY_IPTABLES:-false}" = "true" ] && ln -sf /usr/sbin/xtables-legacy-multi /sbin/iptables
log INFO "Building the kill switch"
# Policies BEFORE flush: never an open moment.
out=$(iptables -P INPUT DROP 2>&1) || die 1 "$out (add --cap-add=NET_ADMIN)"
iptables -P OUTPUT DROP; iptables -P FORWARD DROP
iptables -F; iptables -X; iptables -t nat -F; iptables -t nat -X
iptables -t mangle -F 2>/dev/null
if ip6tables -P INPUT DROP 2>/dev/null && ip6tables -P OUTPUT DROP 2>/dev/null && ip6tables -P FORWARD DROP 2>/dev/null && ip6tables -F 2>/dev/null; then
  :
elif [ -f /proc/net/if_inet6 ]; then
  sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1
  sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1
  [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = "1" ] && [ "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" = "1" ] ||
    die 1 "Cannot block IPv6 - create the container with --sysctl net.ipv6.conf.all.disable_ipv6=1 --sysctl net.ipv6.conf.default.disable_ipv6=1"
fi

iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# LAN -> app ports: INPUT only. Replies leave via ESTABLISHED above, so there is no
# OUTPUT rule that a process could use to egress on $INTERFACE.
for p in $(echo "$LAN_PORTS" | tr ',' ' '); do
  if [ -n "$LAN_NETWORK" ]; then
    for net in $(echo "$LAN_NETWORK" | tr ',' ' '); do
      iptables -A INPUT -i "$INTERFACE" -s "$net" -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT
    done
  else
    iptables -A INPUT -i "$INTERFACE" -p tcp --dport "$p" -m conntrack --ctstate NEW -j ACCEPT
  fi
  log INFO "LAN port $p open${LAN_NETWORK:+ to $LAN_NETWORK}"
done

# Route replies to the container address out of the physical interface (table 128).
src=$(ip route get 1 | sed -n 's/.*src \([^ ]*\).*/\1/p')
ip rule add from "$src" table 128
ip route add table 128 to "$src/32" dev "$INTERFACE"
ip route add table 128 default via "$DEFAULT_GATEWAY"

for ip in $VPNIPS; do
  iptables -A OUTPUT -d "$ip" -o "$INTERFACE" -p udp --dport "$PORT" -j ACCEPT
  iptables -A OUTPUT -d "$ip" -o "$INTERFACE" -p tcp --dport "$PORT" -j ACCEPT
done
iptables -A OUTPUT -o "$VPN_DEVICE" -j ACCEPT
iptables -t mangle -A POSTROUTING -o "$VPN_DEVICE" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true

############################################
# Tunnel
############################################
wg_up() {
  wg-quick up pia > "$VPN_LOG_DIR/wireguard.log" 2>&1
  # Only WireGuard's own transport leaves via eth0 (fwmark -> table 128).
  wg set pia fwmark 51820
  ip rule add fwmark 51820 table 128 priority 100 2>/dev/null
  ip route add 0.0.0.0/1 dev pia 2>/dev/null
  ip route add 128.0.0.0/1 dev pia 2>/dev/null
  ip route flush cache 2>/dev/null
}
ovpn_up() {
  ( cd "$TARGET_PATH" && openvpn --config config.ovpn --daemon --log "$VPN_LOG_DIR/openvpn.log" --status "$OVPN_STATUS" 10 )
}

tunnel_alive() {
  if [ "$VPN_CLIENT" = "wireguard" ]; then
    hs=$(wg show pia latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
    [ -n "$hs" ] && [ "$hs" -gt 0 ] 2>/dev/null || return 1
    [ $(( $(date +%s) - hs )) -lt "$WG_STALE_LOOP" ]
  else
    pgrep -x openvpn > /dev/null || return 1
    ip link show "$VPN_DEVICE" > /dev/null 2>&1 || return 1
    [ -f "$OVPN_STATUS" ] || return 0
    [ $(( $(date +%s) - $(stat -c %Y "$OVPN_STATUS" 2>/dev/null || echo 0) )) -lt "$OVPN_STATUS_LOOP" ]
  fi
}

wait_tunnel() {
  n=0
  while [ $n -lt "${1:-45}" ]; do tunnel_alive && return 0; sleep 1; n=$((n + 1)); done
  return 1
}

reconnect_vpn() {
  log WARNING "Reconnecting VPN in place"
  if [ "$VPN_CLIENT" = "wireguard" ]; then
    wg-quick down pia > /dev/null 2>&1
    # The server may have dropped our key; addKey goes to a region server the kill
    # switch already allows, so this works with the tunnel down. A dead token cannot
    # be renewed here (the token host is blocked) - only a restart can.
    wg_register && log INFO "Re-registered WireGuard key with $WG_CN"
    wg_up
  else
    pkill -x openvpn 2>/dev/null; sleep 3; ovpn_up
  fi
  wait_tunnel 45
}

log INFO "Connecting to PIA"
if [ "$VPN_CLIENT" = "wireguard" ]; then wg_up; else ovpn_up; fi
wait_tunnel 60 || die 5 "Tunnel did not come up - see $VPN_LOG_DIR"
pub=$(curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null)
log INFO "Tunnel up on $VPN_DEVICE - public IP ${pub:-unknown (lookup failed)}"
touch /run/pia-iptv.ready

# One-line VPN summary. Printed again once the app is up (so it is in the last lines
# of the log, which is all Unraid's log window shows) and after every reconnect.
vpn_status() {
  st_ip=$(curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null)
  log INFO "VPN up: ${region_name}${WG_CN:+ ($WG_CN)}, $VPN_CLIENT, exit IP ${st_ip:-unknown}${1:+ - $1}"
}

############################################
# Monitor loop (same cadence and budget as pia-qbittorrent)
############################################
monitor() {
i=1; fail=0; state=up; down_samples=0; down_since=0
while :; do
  sleep 1
  if [ $((i % 30)) -eq 0 ]; then
    if tunnel_alive; then
      if [ "$state" = down ]; then log INFO "Tunnel recovered (was down ~$(( $(date +%s) - down_since ))s)"; state=up; down_samples=0; fi
    else
      if [ "$state" = up ]; then
        state=down; down_since=$(date +%s); down_samples=1; log WARNING "Tunnel went down"
      else
        down_samples=$((down_samples + 1))
        # Second confirming sample: let WireGuard self-heal first, then force recovery.
        [ "$down_samples" -eq 2 ] && i=$((MONITOR_TICK + 1))
      fi
    fi
  fi
  if [ $i -gt "$MONITOR_TICK" ]; then
    i=1
    if ! tunnel_alive; then
      if reconnect_vpn; then
        fail=0; log INFO "Reconnected - tunnel is back up"; vpn_status "after reconnect"
      else
        fail=$((fail + 1))
        if [ "$fail" -ge "$RECONNECT_MAX_FAILURES" ]; then
          log ERROR "In-place reconnect failed ${fail}x - stopping the container for a full restart (fresh token). Needs a restart policy."
          # In all-in-one mode PID 1 is the app's supervisor, not this script:
          # stop it so the whole container exits and the restart policy starts it fresh.
          [ "$$" != 1 ] && kill -TERM 1 2>/dev/null
          exit 5
        fi
        log WARNING "Reconnect attempt $fail failed - retrying in ${RECONNECT_RETRY_GAP}s"
        i=$((MONITOR_TICK - RECONNECT_RETRY_GAP + 1))
      fi
    fi
  fi
  i=$((i + 1))
done
}

############################################
# Hand over
############################################
if command -v start-container > /dev/null 2>&1; then
  # All-in-one: m3u-editor runs in this container, behind the tunnel and kill switch.
  # Its internal secrets are generated once and kept in its config volume.
  secrets=/var/www/config/.pia-iptv-secrets
  mkdir -p /var/www/config
  if [ ! -s "$secrets" ]; then
    umask 077
    printf 'PIA_IPTV_PG_PASSWORD=%s\nPIA_IPTV_PROXY_TOKEN=%s\n' \
      "$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
      "$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')" > "$secrets"
    umask 022
    log INFO "Generated m3u-editor internal secrets in $secrets"
  fi
  # shellcheck disable=SC1090
  . "$secrets"
  export PG_PASSWORD="${PG_PASSWORD:-$PIA_IPTV_PG_PASSWORD}"
  export DB_PASSWORD="${DB_PASSWORD:-$PG_PASSWORD}"
  export M3U_PROXY_TOKEN="${M3U_PROXY_TOKEN:-$PIA_IPTV_PROXY_TOKEN}"
  export REDIS_PASSWORD="${REDIS_PASSWORD:-$M3U_PROXY_TOKEN}"
  unset PIA_IPTV_PG_PASSWORD PIA_IPTV_PROXY_TOKEN

  monitor &
  # Repeat the VPN summary once m3u-editor answers, after its long startup output.
  (
    n=0
    while [ $n -lt 120 ]; do
      curl -fs --max-time 5 "http://127.0.0.1:${APP_PORT:-36400}/up" > /dev/null 2>&1 && break
      sleep 5; n=$((n + 1))
    done
    sleep 5
    vpn_status "m3u-editor ready on port ${APP_PORT:-36400}"
  ) &
  log INFO "Starting m3u-editor on port ${APP_PORT:-36400}"
  exec start-container "$@"
fi

# Gateway only: other containers join this one's network.
shutdown() {
  log INFO "Stopping"
  if [ "$VPN_CLIENT" = "wireguard" ]; then wg-quick down pia > /dev/null 2>&1; else pkill -x openvpn; fi
  exit 0
}
trap shutdown TERM INT
monitor &
wait $!
