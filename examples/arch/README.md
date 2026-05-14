# Arch Linux mirror example

This directory contains an example for adding Arch Linux mirroring to the stack.

Files added by this project:

- `arch-entrypoint.sh` (placed at project root when created). This script uses rsync to mirror a full Arch Linux tree from a known-good public rsync mirror into `./data/arch/`.
- `config/nginx.arch.conf` (optional include) exposes `/arch/` to the web frontend.

## How to enable in `docker-compose.yml` (manual edit):

Add the following service block under services:

```yaml
  arch-mirror:
    image: alpine:3.20
    container_name: arch-mirror
    environment:
      - TZ=America/Denver
    volumes:
      - ./config/schedules.env:/etc/mirror-schedules.env:ro
      - ./data:/mirror
      - ./arch-entrypoint.sh:/usr/local/bin/arch-entrypoint.sh:ro
    command: /bin/sh /usr/local/bin/arch-entrypoint.sh
    restart: unless-stopped
```

NGINX: merge the contents of `config/nginx.arch.conf` into `config/nginx.conf` (see file) or include it.

## Rsync source

The script syncs from `rsync://ftp.acc.umu.se/mirror/archlinux/` by default.

This mirrors the full Arch tree into a dedicated local target with:

`rsync -av --delete --no-o --no-g rsync://ftp.acc.umu.se/mirror/archlinux/ /mirror/arch/`

You can customize the upstream source with `ARCH_RSYNC_SOURCE`.

Reference: https://wiki.archlinux.org/title/Mirroring

Notes:
- Initial rsync can be large; ensure you have enough disk space and bandwidth.
- Keep `./data/arch/` dedicated to Arch mirror content only, because `--delete` will remove anything not present upstream.
- To trigger a manual sync: `docker exec -it arch-mirror /usr/local/bin/run-arch-rsync-logged.sh`.

