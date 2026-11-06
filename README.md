# pia-iptv

A Private Internet Access VPN gateway container with a kill switch, built to route an IPTV
proxy such as [m3u-editor](https://github.com/m3ue/m3u-editor) through PIA.

```
TiviMate ──LAN──▶ :36400  m3u-editor ─┐  (shares pia-iptv's network)
                                       ▼
                 pia-iptv: WireGuard/OpenVPN + kill switch ──PIA──▶ IPTV provider
```

The app container joins this one's network namespace, so its playlist and EPG syncs and every
proxied stream leave through PIA. If the tunnel drops, the kill switch blocks them instead of
letting them out with your real IP.

The VPN layer is adapted from [pia-qbittorrent-docker](https://github.com/GeorgeAL78/pia-qbittorrent-docker):

- PIA token login, region matching (exact id, then name, then substring), server list refreshed at start
- WireGuard (default) with key registration and failover across the region's servers; OpenVPN fallback
- Kill switch: policies set to DROP before the flush, every `eth0` ACCEPT pinned to a PIA server, IPv6 blocked
- LAN access is INPUT-only, for the ports in `LAN_PORTS`, optionally limited to `LAN_NETWORK`
- Tunnel monitoring and in-place reconnect with a fresh key; exits for a full restart after about an hour of failures

## Docker Compose

```sh
cp .env.example .env    # fill in PIA login, secrets, APP_URL
docker compose up -d
```

`docker-compose.yml` runs pia-iptv, m3u-editor in its network, and autoheal, which restarts
m3u-editor if a pia-iptv restart leaves it without a network. Autoheal needs the Docker socket,
which amounts to root on the host. Remove it if you'd rather restart m3u-editor yourself.

Instead of `PIA_USERNAME`/`PIA_PASSWORD` you can mount a file as `/auth.conf:ro`, with the username
on line 1 and the password on line 2.

## Unraid

Templates are in [`unraid/`](unraid/), and also in
[GeorgeAL78/unraid-templates](https://github.com/GeorgeAL78/unraid-templates):

1. Install **pia-iptv** and fill in the PIA login. It publishes port 36400 for the app.
2. Install **m3u-editor (via pia-iptv)**. Network Type stays *None*: its network comes from
   `--net=container:pia-iptv`.
3. After you update or recreate pia-iptv, also update/apply m3u-editor, so it rejoins the new network.

## TiviMate

In m3u-editor, add your provider, build a playlist, set the playlist's auth, and **enable stream
proxying**. Without proxying, TiviMate is given the provider's direct URLs and plays outside the VPN.

TiviMate: *Add playlist → Xtream Codes*, server `http://<host>:36400`, with the playlist's username and password.

## Variables

| Variable | Default | |
|---|---|---|
| `PIA_USERNAME`, `PIA_PASSWORD` | | PIA login, or mount `/auth.conf` |
| `PIA_REGION` | `netherlands` | Region id or name |
| `VPN_CLIENT` | `wireguard` | `wireguard` or `openvpn` |
| `LAN_PORTS` | `36400` | Ports reachable from the LAN (comma-separated) |
| `LAN_NETWORK` | | Only these source ranges may connect, e.g. `192.168.1.0/24` |
| `DNS_SERVERS` | `9.9.9.9,149.112.112.112` | Resolvers, used through the tunnel |
| `LEGACY_IPTABLES` | `false` | Use iptables-legacy |
| `TZ` | | Timezone |

Each start logs in to PIA once. PIA rate-limits logins per account, so avoid restart loops.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
