#!/bin/sh
# Healthy = the tunnel is up and passing handshakes (local reads, no network),
# and, in the all-in-one image, m3u-editor answers on its port.
# shellcheck source=vpn-thresholds.sh
. /pia/vpn-thresholds.sh

[ -f /run/pia-iptv.ready ] || { echo "Tunnel not established yet" >&2; exit 1; }

if ip link show pia > /dev/null 2>&1; then
  HS=$(wg show pia latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
  if [ -z "$HS" ] || ! [ "$HS" -gt 0 ] 2>/dev/null; then echo "WireGuard never completed a handshake" >&2; exit 1; fi
  AGE=$(( $(date +%s) - HS ))
  [ "$AGE" -lt "$WG_STALE_HEALTH" ] || { echo "WireGuard handshake ${AGE}s old" >&2; exit 1; }
elif ip -o link show | grep -qE ': tun[0-9]'; then
  pgrep -x openvpn > /dev/null || { echo "openvpn process gone" >&2; exit 1; }
  if [ -f /run/openvpn.status ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y /run/openvpn.status 2>/dev/null || echo 0) ))
    [ "$AGE" -lt "$OVPN_STATUS_HEALTH" ] || { echo "openvpn status ${AGE}s stale" >&2; exit 1; }
  fi
else
  echo "No VPN interface" >&2
  exit 1
fi

# All-in-one: the app must answer too.
if command -v start-container > /dev/null 2>&1; then
  curl -fs --max-time 8 "http://127.0.0.1:${APP_PORT:-36400}/up" > /dev/null || { echo "m3u-editor not answering" >&2; exit 1; }
fi
exit 0
