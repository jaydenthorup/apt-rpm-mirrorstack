#!/bin/sh
# Arch mirror entrypoint: install required tools, perform an initial rsync, and keep cron running.
set -eu

LOCK_FILE="/tmp/archrsync.lock"

# create lock file with proper permissions
touch "${LOCK_FILE}"
chmod 666 "${LOCK_FILE}"

# Load schedule settings if provided
if [ -f /etc/mirror-schedules.env ]; then
    # shellcheck disable=SC1091
    . /etc/mirror-schedules.env
fi

ARCH_CRON_SCHEDULE="${ARCH_CRON_SCHEDULE:-30 */6 * * *}"
ARCH_RSYNC_SOURCE="${ARCH_RSYNC_SOURCE:-rsync://ftp.acc.umu.se/mirror/archlinux}"

# Install rsync, util-linux (provides flock), and CA roots if needed.
if ! command -v rsync >/dev/null 2>&1; then
    echo "Installing rsync, util-linux, and ca-certificates"
    if [ -f /etc/apk/repositories ]; then
        sed -i 's#https://#http://#g' /etc/apk/repositories
    fi
    apk add --no-cache rsync util-linux ca-certificates
    update-ca-certificates || true
fi

# Ensure mirror directory exists and is dedicated to Arch content only.
mkdir -p /mirror/arch || true

# Wrapper that mirrors the full Arch tree from a known-good rsync mirror.
cat >/usr/local/bin/run-arch-rsync-logged.sh <<'EOF'
#!/bin/sh
set -eu

# Mirror a complete Arch tree into a dedicated target directory.
# Keep /mirror/arch reserved for Arch content because --delete will remove
# anything that does not exist on the source mirror.
ARCH_RSYNC_SOURCE="${ARCH_RSYNC_SOURCE:-rsync://ftp.acc.umu.se/mirror/archlinux}"
root="${ARCH_RSYNC_SOURCE%/}"

echo "Syncing Arch mirror tree from ${root}/"
rsync -av --delete --no-o --no-g --delay-updates --safe-links --no-motd "${root}/" /mirror/arch/

exit 0
EOF
chmod +x /usr/local/bin/run-arch-rsync-logged.sh

# Ensure lock file exists with proper permissions before flock tries to use it
touch "${LOCK_FILE}"
chmod 666 "${LOCK_FILE}"

# Start an initial rsync under flock in the background if lock is free.
flock -n "${LOCK_FILE}" -c "/usr/local/bin/run-arch-rsync-logged.sh" &

# Install cron entry with a flock wrapper to avoid overlapping scheduled runs.
mkdir -p /etc/crontabs
printf '%s\n' "${ARCH_CRON_SCHEDULE} flock -n ${LOCK_FILE} -c /usr/local/bin/run-arch-rsync-logged.sh" > /etc/crontabs/root

# Start cron in foreground so docker logs capture it
if command -v crond >/dev/null 2>&1; then
    exec "$(command -v crond)" -f -l 2
elif command -v cron >/dev/null 2>&1; then
    exec "$(command -v cron)" -f
else
    echo "No cron daemon found in container" >&2
    exit 1
fi
