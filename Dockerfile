FROM alpine:3.24

LABEL org.opencontainers.image.title="pia-iptv" \
      org.opencontainers.image.description="PIA VPN gateway (WireGuard/OpenVPN) with kill switch, for routing an IPTV proxy such as m3u-editor through PIA" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

ENV PIA_REGION="netherlands" \
    VPN_CLIENT="wireguard" \
    LAN_PORTS="36400" \
    DNS_SERVERS="9.9.9.9,149.112.112.112" \
    LEGACY_IPTABLES="false"

RUN apk add --no-cache bash ca-certificates curl jq bind-tools iproute2 iptables iptables-legacy \
        openvpn wireguard-tools tzdata unzip && \
    mkdir -p /openvpn/nextgen && \
    curl -sSL --retry 5 https://www.privateinternetaccess.com/openvpn/openvpn.zip -o /tmp/ovpn.zip && \
    unzip -q /tmp/ovpn.zip -d /openvpn/nextgen && rm -f /tmp/ovpn.zip && \
    apk del unzip

COPY entrypoint.sh healthcheck.sh vpn-thresholds.sh ca.rsa.4096.crt LICENSE NOTICE /app/

# Bake a server list; refreshed again at every start before the firewall goes up.
RUN curl -sSL --max-time 30 --retry 3 https://serverlist.piaservers.net/vpninfo/servers/v6 | head -n 1 > /app/data.json && \
    jq -e '.regions | length > 0' /app/data.json > /dev/null && \
    chmod 500 /app/entrypoint.sh /app/healthcheck.sh && chmod 400 /app/vpn-thresholds.sh

ARG VERSION=unknown
ENV CONTAINER_VERSION=$VERSION

ENTRYPOINT ["/app/entrypoint.sh"]
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 CMD /app/healthcheck.sh
