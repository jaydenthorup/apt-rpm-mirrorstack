# Changelog

All notable changes to this project will be documented in this file.

## [1.0.0] - 2026-05-14

### Added
- **Arch Linux mirror support** — Full rsync-based Arch repository mirror with automatic scheduling
- Alpine 3.20 base image for Arch mirror container (lightweight, stable)
- BusyBox crond for reliable cron scheduling in Alpine containers
- Arch mirror integration into web UI with control panel
- Arch mirror link added to public mirror index page
- `.gitattributes` file to enforce LF line endings across shell and config files

### Fixed
- UTF-8 BOM encoding issues in apt and rpm entrypoint scripts
- Line ending normalization (CRLF → LF) for all shell and config files
- SSL certificate verification bypass for dnf package installation in restricted/TLS-intercepted networks
- RPM mirror package installation failures in restricted network environments

### Features
- **Three mirror services:**
  - APT (Ubuntu + Proxmox VE) — metadata-only or full-tree with optional source packages
  - RPM (AlmaLinux 9) — BaseOS, AppStream, CRB, Extras repositories
  - Arch Linux — full repository tree with automatic pruning of deleted packages
- **Web UI** (`/control-ui`, port 8088):
  - View mirror service status
  - Configure cron schedules for sync operations
  - Edit configuration files (apt-mirror.list, nginx.conf, .repo files)
  - Trigger manual syncs
  - Monitor sync logs in real-time
- **NGINX reverse proxy** (port 8090) — serving all three mirrors with autoindex directory listings
- **Public mirror index page** — landing page with links to all available mirrors
- **Lock-based sync safety** — prevents concurrent sync runs using flock
- **Cron-based scheduling** — configurable sync intervals (defaults: apt@0h, rpm@1:15h, arch@0:30h UTC)

### Technical Details
- **Docker Compose orchestration** for all services (ubuntu:22.04, almalinux:9, alpine:3.20, nginx:alpine, custom control-ui)
- **Atomic operations:** `--delay-updates` and `--safe-links` for rsync; `--delete` for cleanup
- **Network resilience:** HTTP fallback for TLS-intercepted networks; no hardcoded mirror credentials
- **Data organization:** Dedicated `./data/` volume with mirror-specific subdirectories (`./data/apt/`, `./data/alma/`, `./data/arch/`)

### Deployment Notes
- First stable release ready for production deployment
- Designed for self-hosted, on-premise mirror deployments
- Suitable for lab environments, CI/CD farms, and enterprise networks with limited internet access
- Mirrors will grow over time; monitor disk space and consider retention policies

### Known Limitations
- APT mirror currently configured for Ubuntu Focal, Jammy, Noble, Questing with all architectures
- RPM mirror syncs AlmaLinux 9 only (no earlier or later major versions in this release)
- Arch mirror syncs full repository tree; no selective package filtering in this release
- Web UI editable configs are applied without syntax validation (except nginx.conf)

---

*For detailed setup instructions, see [README.md](README.md)*
