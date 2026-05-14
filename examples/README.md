# Additional distro mirror examples

These are reference snippets for extending this stack beyond Ubuntu + AlmaLinux.

They are not enabled by default in `docker-compose.yml`.

## Included examples

- `apt/debian-mirror.list` (Debian APT via apt-mirror)
- `rpm/fedora.repo` (Fedora RPM via reposync)
- `rpm/rhel-ubi.repo` (RHEL UBI/CDN example, requires Red Hat entitlement)
- `rpm/rocky.repo` (Rocky Linux RPM via reposync)
- `rpm/opensuse.repo` (openSUSE Leap RPM repos)

## Usage pattern

1. Copy the desired `.repo` file into `config/rpm/`.
2. Add matching `--repoid` entries to the `reposync` command in `docker-compose.yml`.
3. Create target mirror paths under `./data/`.
4. Add NGINX alias routes in `config/nginx.conf` if you want public browsing.

For Debian, merge entries from `apt/debian-mirror.list` into `config/apt-mirror.list`.
