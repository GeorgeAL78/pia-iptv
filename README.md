# pia-iptv

[m3u-editor](https://github.com/m3ue/m3u-editor) with a built-in Private Internet Access (PIA)
VPN and kill switch, in one container.

The container connects to PIA first, then starts m3u-editor exactly as its own image does.
Everything m3u-editor does online (playlist and guide syncs, proxied streams, logos when the
logo proxy is on) uses the VPN. If the tunnel drops, that traffic stops instead of falling back
to your regular connection. Players connect to m3u-editor over your LAN.

```
player ──LAN──▶ :36400 ──▶ ┌ pia-iptv ───────────────────────────┐
                           │ m3u-editor                          │
                           │ WireGuard/OpenVPN + kill switch ────┼──PIA──▶ internet
                           └─────────────────────────────────────┘
```

## Features

- m3u-editor with its embedded PostgreSQL, Redis and stream proxy, unchanged
- WireGuard (default) or OpenVPN, any PIA region
- Region matched by id or name, with PIA's server list refreshed at every start
- WireGuard key registration with failover across the region's servers
- **Kill switch:** all traffic is blocked unless it goes through the tunnel. The only exceptions
  are the PIA servers themselves, and IPv6 is blocked entirely
- From the LAN, only m3u-editor's port is reachable, optionally only from the networks you list.
  Its database, Redis and internal ports are not
- Tunnel monitoring with in-place reconnect. After about an hour of failed reconnects the
  container stops so the restart policy can start it fresh
- One health check for both the tunnel and m3u-editor

The VPN layer is adapted from
[pia-qbittorrent-docker](https://github.com/GeorgeAL78/pia-qbittorrent-docker).

## Requirements

- A PIA subscription
- Docker with `/dev/net/tun` available on the host (`ls -l /dev/net/tun`)
- `NET_ADMIN` for the container

## Docker Compose

```sh
git clone https://github.com/GeorgeAL78/pia-iptv.git && cd pia-iptv
cp .env.example .env    # fill in your PIA login, region and APP_URL
docker compose up -d
```

Open `APP_URL` (by default `http://<docker-host-ip>:36400`). m3u-editor's default login is
`admin` / `admin`; change it.

Instead of `PIA_USERNAME`/`PIA_PASSWORD` you can mount a file as `/auth.conf:ro`, with the
username on line 1 and the password on line 2.

## Unraid

Install **pia-iptv** from the template in [`unraid/`](unraid/) or in
[GeorgeAL78/unraid-templates](https://github.com/GeorgeAL78/unraid-templates). Fill in your PIA
login, pick a region, set *App URL* to `http://<your-unraid-ip>:36400`, and start it.

## Setting up your player

In m3u-editor:

1. **Playlists → New playlist**, type **Xtream**. Enter the source's server URL, username and
   password, choose what to import (live, movies, series, guide), and save.
2. **Enable proxying** for the playlist (the *Proxy* toggle). Without it, players connect to the
   source directly instead of through the VPN. Turn on the *Logo Proxy* too.
3. **Groups**: select the groups you want, then *Enable Group Channels*. Imported channels start
   disabled.
4. The playlist's **Xtream API** tab shows the server, username and password for your players.
   Or create a **Playlist Auth** with your own username and password.

In the player (TiviMate, IPTV Smarters, VLC, Kodi, ...), add an *Xtream Codes* playlist with
server `http://<docker-host-ip>:36400` and those credentials.

Browser-based players often can't play raw MPEG-TS, AC3 audio or HEVC. If a channel fails only
in a browser, try the playlist's `m3u8` output or a native player.

## Variables

VPN:

| Variable | Default | |
|---|---|---|
| `PIA_USERNAME`, `PIA_PASSWORD` | | PIA login, or mount `/auth.conf` |
| `PIA_REGION` | `us-newjersey` | Region id or name, e.g. `us_chicago`, `ca_toronto`, `uk`, `de-frankfurt` |
| `VPN_CLIENT` | `wireguard` | `wireguard` or `openvpn` |
| `LAN_NETWORK` | | Only these source ranges may connect (comma-separated), e.g. `192.168.0.0/24`. Empty = any |
| `LAN_PORTS` | `APP_PORT` | Ports reachable from the LAN. Defaults to m3u-editor's port (plus `XTREAM_PORT` if set) |
| `DNS_SERVERS` | `9.9.9.9,149.112.112.112` | Resolvers, used through the tunnel |
| `LEGACY_IPTABLES` | `false` | Use iptables-legacy, if the firewall fails to build on your kernel |
| `TZ` | | Timezone |

m3u-editor:

| Variable | Default | |
|---|---|---|
| `APP_URL` | | How browsers and players reach it, e.g. `http://192.168.0.10:36400` |
| `APP_PORT` | `36400` | Web UI and Xtream port |
| `AUTO_LOGIN` | `false` | `true` opens the web UI without signing in. Anyone allowed by `LAN_NETWORK` gets admin |
| `PG_PASSWORD`, `M3U_PROXY_TOKEN` | generated | Internal secrets. Generated on first start and kept in `/var/www/config` |

Other m3u-editor variables work as documented in its own repository.

Volumes: `/var/www/config` (settings), `/var/lib/postgresql/data` (database),
`/var/www/html/storage/app/public` (uploads).

## Choosing a region

Pick a PIA region close to you or to the servers m3u-editor connects to. Distance adds latency,
which can cause buffering at high bitrates such as 4K.

## Notes

- **Logins:** each start logs in to PIA once, and PIA rate-limits logins per account. Avoid restart
  loops, especially if the account is shared with other containers.
- **Throughput:** WireGuard is much lighter than OpenVPN. Use it for 4K.
- **m3u-editor version:** each pia-iptv release is built on the m3u-editor release current at
  the time.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE) and [NOTICE](NOTICE). m3u-editor is a separate
project by sparkison under its own license.
