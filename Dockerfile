# pia-iptv: m3u-editor with a built-in PIA VPN tunnel and kill switch, in one container.
# The VPN comes up first; m3u-editor then starts exactly as in its own image.
ARG M3U_EDITOR_TAG=latest
FROM sparkison/m3u-editor:${M3U_EDITOR_TAG}

LABEL org.opencontainers.image.title="pia-iptv" \
      org.opencontainers.image.description="m3u-editor with a built-in Private Internet Access VPN (WireGuard/OpenVPN) and kill switch" \
      org.opencontainers.image.source="https://github.com/GeorgeAL78/pia-iptv" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

RUN apk add --no-cache bind-tools iproute2 iptables iptables-legacy jq openvpn wireguard-tools && \
    mkdir -p /openvpn/nextgen && \
    curl -sSL --retry 5 https://www.privateinternetaccess.com/openvpn/openvpn.zip -o /tmp/ovpn.zip && \
    unzip -q /tmp/ovpn.zip -d /openvpn/nextgen && rm -f /tmp/ovpn.zip

COPY entrypoint.sh healthcheck.sh vpn-thresholds.sh ca.rsa.4096.crt LICENSE NOTICE /pia/

# Bake a server list; refreshed again at every start before the firewall goes up.
RUN curl -sSL --max-time 30 --retry 3 https://serverlist.piaservers.net/vpninfo/servers/v6 | head -n 1 > /pia/data.json && \
    jq -e '.regions | length > 0' /pia/data.json > /dev/null && \
    chmod 500 /pia/entrypoint.sh /pia/healthcheck.sh && chmod 400 /pia/vpn-thresholds.sh

# VPN defaults
ENV PIA_REGION="us-newjersey" \
    VPN_CLIENT="wireguard" \
    DNS_SERVERS="9.9.9.9,149.112.112.112" \
    LEGACY_IPTABLES="false"

# m3u-editor defaults: everything embedded, as in its all-in-one setup.
# PG_PASSWORD and M3U_PROXY_TOKEN are generated on first start unless you set them.
ENV APP_PORT="36400" \
    ENABLE_POSTGRES="true" \
    PG_DATABASE="m3ue" PG_USER="m3ue" PG_PORT="5432" \
    DB_CONNECTION="pgsql" DB_HOST="localhost" DB_PORT="5432" DB_DATABASE="m3ue" DB_USERNAME="m3ue" \
    REDIS_ENABLED="true" REDIS_SERVER_PORT="36790" REDIS_HOST="localhost" \
    M3U_PROXY_ENABLED="true" M3U_PROXY_PORT="38085" M3U_PROXY_HOST="localhost"

EXPOSE 36400

ARG VERSION=unknown
ENV CONTAINER_VERSION=$VERSION

ENTRYPOINT ["/pia/entrypoint.sh"]
HEALTHCHECK --interval=30s --timeout=12s --start-period=180s --retries=3 CMD /pia/healthcheck.sh
