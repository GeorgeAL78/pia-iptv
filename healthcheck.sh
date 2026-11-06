#!/bin/sh
# Healthy = the tunnel is up and passing handshakes (local reads, no network).
# Deliberately does NOT check the app containers: they depend on this one being
# healthy before they start, so checking them here would deadlock startup.
# shellcheck source=vpn-thresholds.sh
. /app/vpn-thresholds.sh

[ -f /run/pia-iptv.ready ] || { echo "Tunnel not established yet" >&2; exit 1; }

if ip link show pia > /dev/null 2>&1; then
  HS=$(wg show pia latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
  if [ -z "$HS" ] || ! [ "$HS" -gt 0 ] 2>/dev/null; then echo "WireGuard never completed a handshake" >&2; exit 1; fi
  AGE=$(( $(date +%s) - HS ))
  [ "$AGE" -lt "$WG_STALE_HEALTH" ] || { echo "WireGuard handshake ${AGE}s old" >&2; exit 1; }
  exit 0
fi

if ip -o link show | grep -qE ': tun[0-9]'; then
  pgrep -x openvpn > /dev/null || { echo "openvpn process gone" >&2; exit 1; }
  if [ -f /run/openvpn.status ]; then
    AGE=$(( $(date +%s) - $(stat -c %Y /run/openvpn.status 2>/dev/null || echo 0) ))
    [ "$AGE" -lt "$OVPN_STATUS_HEALTH" ] || { echo "openvpn status ${AGE}s stale" >&2; exit 1; }
  fi
  exit 0
fi

echo "No VPN interface" >&2
exit 1
