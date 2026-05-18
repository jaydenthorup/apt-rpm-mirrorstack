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
ARCH_CRON_SCHEDULE="$(printf '%s' "$ARCH_CRON_SCHEDULE" | tr -d '\r' | sed "s/^'//;s/'$//;s/^\"//;s/\"$//")"
ARCH_RSYNC_SOURCE="${ARCH_RSYNC_SOURCE:-rsync://mirror.accum.se/mirror/archlinux}"

MIN_FREE_KIB=104857600

validate_arch_schedule() {
    # Keep this intentionally simple and predictable:
    # require a standard 5-field cron expression after normalization.
    fields="$(printf '%s\n' "$1" | awk '{print NF}')"
    [ "$fields" -eq 5 ]
}

random_minute() {
    raw="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$raw" ]; then
        date +%M
        return
    fi
    echo $((raw % 60))
}

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

# Ensure at least 100 GiB free before mirroring.
FREE_KIB="$(df -Pk /mirror | awk 'NR==2 {print $4}')"
if [ -z "${FREE_KIB}" ] || [ "${FREE_KIB}" -lt "${MIN_FREE_KIB}" ]; then
    echo "[ARCH-SYNC] ERROR: At least 100 GiB free space is required under /mirror." >&2
    echo "[ARCH-SYNC] ERROR: Available KiB: ${FREE_KIB:-unknown}, required KiB: ${MIN_FREE_KIB}." >&2
    exit 1
fi

# Wrapper that mirrors the full Arch tree from a known-good rsync mirror.
cat >/usr/local/bin/run-arch-rsync-logged.sh <<'EOF'
#!/bin/sh
set -eu

TS() { date '+%Y-%m-%d %H:%M:%S'; }
ARCH_RSYNC_SOURCE="${ARCH_RSYNC_SOURCE:-rsync://mirror.accum.se/mirror/archlinux}"
root="${ARCH_RSYNC_SOURCE%/}"

echo "[ARCH-SYNC] START $(TS) - source: ${root}/"
rsync -rlptH --safe-links --delete-delay --delay-updates "${root}/" /mirror/arch/
echo "[ARCH-SYNC] DONE $(TS)"

exit 0
EOF
chmod +x /usr/local/bin/run-arch-rsync-logged.sh

# Logged flock wrapper: prints SKIPPED when a run is already in progress.
cat >/usr/local/bin/flock-arch-rsync.sh <<'EOF'
#!/bin/sh
TS() { date '+%Y-%m-%d %H:%M:%S'; }
flock -n /tmp/archrsync.lock -c /usr/local/bin/run-arch-rsync-logged.sh
rc=$?
if [ $rc -eq 1 ]; then
    echo "[ARCH-SYNC] SKIPPED $(TS) - sync already running"
fi
exit $rc
EOF
chmod +x /usr/local/bin/flock-arch-rsync.sh

# Ensure lock file exists with proper permissions before flock tries to use it
touch "${LOCK_FILE}"
chmod 666 "${LOCK_FILE}"

# Start an initial rsync under flock in the background if lock is free.
/usr/local/bin/flock-arch-rsync.sh &

# Install cron entry with a flock wrapper to avoid overlapping scheduled runs.
mkdir -p /etc/crontabs
if ! validate_arch_schedule "${ARCH_CRON_SCHEDULE}"; then
    ARCH_CRON_SCHEDULE="$(random_minute) */6 * * *"
    echo "[ARCH-SYNC] Invalid ARCH_CRON_SCHEDULE; using compliant default ${ARCH_CRON_SCHEDULE}"
elif [ "${ARCH_CRON_SCHEDULE}" = "30 */6 * * *" ]; then
    ARCH_CRON_SCHEDULE="$(random_minute) */6 * * *"
    echo "[ARCH-SYNC] Randomized default ARCH_CRON_SCHEDULE to ${ARCH_CRON_SCHEDULE}"
fi
printf '%s\n' "${ARCH_CRON_SCHEDULE} /usr/local/bin/flock-arch-rsync.sh" > /etc/crontabs/root

# Start cron in foreground so docker logs capture it
if command -v crond >/dev/null 2>&1; then
    exec "$(command -v crond)" -f -l 2
elif command -v cron >/dev/null 2>&1; then
    exec "$(command -v cron)" -f
else
    echo "No cron daemon found in container" >&2
    exit 1
fi
