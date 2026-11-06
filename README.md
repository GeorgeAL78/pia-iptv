# pia-iptv

A Private Internet Access (PIA) VPN gateway container with a kill switch. Other containers join
its network and reach the internet only through PIA.

It's made for IPTV proxies such as [m3u-editor](https://github.com/m3ue/m3u-editor). The proxy
runs inside pia-iptv's network, so its playlist and guide syncs and the streams it relays use the
VPN. Players connect to the proxy over your LAN.

```
player ──LAN──▶ :36400 ─┐
                        │  m3u-editor (shares pia-iptv's network)
                        ▼
              pia-iptv: WireGuard/OpenVPN + kill switch ──PIA──▶ IPTV provider
```

Any app can sit behind it the same way. Open its ports with `LAN_PORTS`.

## Features

- WireGuard (default) or OpenVPN, any PIA region
- Region matched by id or name, with PIA's server list refreshed at every start
- WireGuard key registration with failover across the region's servers
- **Kill switch:** all traffic is blocked unless it goes through the tunnel. The only exceptions
  are the PIA servers themselves, and IPv6 is blocked entirely
- LAN access only to the ports you list, optionally only from the networks you list
- Tunnel monitoring with in-place reconnect. After about an hour of failed reconnects the
  container exits so the restart policy can start it fresh
- DNS goes through the tunnel and is shared with the containers that join this one

The VPN layer is adapted from
[pia-qbittorrent-docker](https://github.com/GeorgeAL78/pia-qbittorrent-docker).

## Requirements

- A PIA subscription
- Docker with `/dev/net/tun` available on the host (`ls -l /dev/net/tun`)
- The container needs `NET_ADMIN`. The app containers behind it need no extra privileges.

## Docker Compose

```sh
git clone https://github.com/GeorgeAL78/pia-iptv.git && cd pia-iptv
cp .env.example .env    # fill in your PIA login, region, APP_URL and the two secrets
docker compose up -d
```

Open `APP_URL` (by default `http://<docker-host-ip>:36400`) for m3u-editor's web UI. Its default
login is `admin` / `admin`; change it.

The compose file runs three containers:

- **pia-iptv**: the gateway. m3u-editor's port is published here, because m3u-editor lives in this
  container's network.
- **m3u-editor**: `network_mode: service:pia-iptv`, with no capabilities of its own.
- **autoheal** (optional): restarts m3u-editor if a pia-iptv restart leaves it without a network.
  It needs the Docker socket, which amounts to root on the host. Remove it if you'd rather
  restart m3u-editor yourself.

Instead of `PIA_USERNAME`/`PIA_PASSWORD` you can mount a file as `/auth.conf:ro`, with the
username on line 1 and the password on line 2.

## Unraid

Templates are in [`unraid/`](unraid/) and in
[GeorgeAL78/unraid-templates](https://github.com/GeorgeAL78/unraid-templates).

1. Install **pia-iptv**. Fill in your PIA login and pick a region. Set *LAN network* to your
   LAN, e.g. `192.168.0.0/24`, or leave it empty.
2. Install **m3u-editor (via pia-iptv)**. Set *App URL* to `http://<your-unraid-ip>:36400`, and
   fill in the passwords. Network Type stays *None*: its network comes from
   `--net=container:pia-iptv`.
3. Optional: install **autoheal** (`willfarrell/autoheal`) from Community Applications.

## Setting up your player

In m3u-editor:

1. **Playlists → New playlist**, type **Xtream**. Enter your provider's server URL, username and
   password, choose what to import (live, movies, series, guide), and save.
2. **Enable proxying** for the playlist (the *Proxy* toggle). Without it, players are given the
   provider's direct URLs and stream outside the VPN.
3. **Groups**: select the groups you want, then *Enable Group Channels*. Imported channels start
   disabled.
4. The playlist's **Xtream API** tab shows the server, username and password for your players.
   Or create a **Playlist Auth** with your own username and password.

In the player, add an *Xtream Codes* playlist with server `http://<docker-host-ip>:36400` and
those credentials.

Browser-based players often can't play raw MPEG-TS, AC3 audio or HEVC. If a channel fails only
in a browser, try the playlist's `m3u8` output or a native player.

## Variables

| Variable | Default | |
|---|---|---|
| `PIA_USERNAME`, `PIA_PASSWORD` | | PIA login, or mount `/auth.conf` |
| `PIA_REGION` | `netherlands` | Region id or name, e.g. `us-newjersey`, `uk`, `de-frankfurt`, `ca_toronto` |
| `VPN_CLIENT` | `wireguard` | `wireguard` or `openvpn` |
| `LAN_PORTS` | `36400` | Ports reachable from the LAN (comma-separated). Publish the same ports on this container. |
| `LAN_NETWORK` | | Only these source ranges may connect (comma-separated). Empty = any source on the container network |
| `DNS_SERVERS` | `9.9.9.9,149.112.112.112` | Resolvers, used through the tunnel |
| `LEGACY_IPTABLES` | `false` | Use iptables-legacy, if the firewall fails to build on your kernel |
| `TZ` | | Timezone |

## Choosing a region

Pick a PIA region close to you or to your IPTV provider's servers; distance adds latency and can
cause buffering on 4K. PIA's *Streaming Optimized* regions are meant for services that block VPNs
(Netflix and similar). IPTV providers rarely do, so a regular region is usually best. PIA's
virtual locations (IP in one country, server in another) add latency.

## Notes

- **Logins:** each start logs in to PIA once, and PIA rate-limits logins per account. Avoid restart
  loops, especially if the account is shared with other containers.
- **Updating pia-iptv:** a recreated gateway gets a new network namespace. Recreate the app
  container too: `docker compose up -d`, or on Unraid, update/apply m3u-editor after pia-iptv.
  autoheal covers restarts, not recreates.
- **Throughput:** WireGuard is much lighter than OpenVPN. Use it for 4K.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
