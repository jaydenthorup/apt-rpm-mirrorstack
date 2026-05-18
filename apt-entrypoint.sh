#!/bin/bash
# Minimal entrypoint for ubuntu-mirror: ensure cron always starts and prevent duplicate runs via flock.
set -u

# create lock dir
mkdir -p /var/lock

# Load schedule settings if provided
if [ -f /etc/mirror-schedules.env ]; then
	# shellcheck disable=SC1091
	. /etc/mirror-schedules.env
fi

APT_CRON_SCHEDULE="${APT_CRON_SCHEDULE:-0 */6 * * *}"
APT_CRON_SCHEDULE="$(printf '%s' "$APT_CRON_SCHEDULE" | tr -d '\r' | sed "s/^'//;s/'$//;s/^\"//;s/\"$//")"

# Install packages only if missing (non-fatal)
need_install=0
command -v apt-mirror >/dev/null 2>&1 || need_install=1
command -v cron >/dev/null 2>&1 || need_install=1

if [ "$need_install" -eq 1 ]; then
	echo "Installing required packages: apt-mirror cron"
	apt-get update || true
	DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold apt-mirror cron || true
else
	echo "apt-mirror and cron already present; skipping package install"
fi

# Ensure mirror directories exist
mkdir -p /mirror/apt/mirror/archive.ubuntu.com/ubuntu /mirror/apt/mirror/download.proxmox.com/debian/pve || true
mkdir -p /mirror/apt/var || true

# apt-mirror attempts to run /mirror/apt/var/postmirror.sh by default.
# Provide a no-op hook so runs don't fail when the file is absent.
if [ ! -f /mirror/apt/var/postmirror.sh ]; then
cat >/mirror/apt/var/postmirror.sh <<'EOF'
#!/bin/sh
exit 0
EOF
fi
chmod +x /mirror/apt/var/postmirror.sh || true

# Wrapper that runs apt-mirror and tails internal wget logs for live "Saving" lines.
cat >/usr/local/bin/run-apt-mirror-logged.sh <<'EOF'
#!/bin/bash
set -u

TS() { date '+%Y-%m-%d %H:%M:%S'; }
echo "[APT-SYNC] START $(TS)"

tail_pid=""

/usr/bin/apt-mirror &
mirror_pid=$!

while kill -0 "$mirror_pid" 2>/dev/null; do
	set -- /mirror/apt/var/*-log.*
	if [ -e "$1" ]; then
		tail -n0 -F /mirror/apt/var/*-log.* 2>/dev/null | grep --line-buffered -h "Saving" &
		tail_pid=$!
		break
	fi
	sleep 1
done

wait "$mirror_pid"
status=$?

if [ -n "$tail_pid" ]; then
	kill "$tail_pid" 2>/dev/null || true
	wait "$tail_pid" 2>/dev/null || true
fi

if [ "$status" -eq 0 ]; then
	echo "[APT-SYNC] DONE $(TS) (exit 0)"
else
	echo "[APT-SYNC] FAILED $(TS) (exit $status)"
fi
exit "$status"
EOF
chmod +x /usr/local/bin/run-apt-mirror-logged.sh

# Logged flock wrapper: prints SKIPPED when a run is already in progress.
cat >/usr/local/bin/flock-apt-mirror.sh <<'EOF'
#!/bin/bash
TS() { date '+%Y-%m-%d %H:%M:%S'; }
/usr/bin/flock -n /var/lock/aptmirror.lock -c "/usr/local/bin/run-apt-mirror-logged.sh"
rc=$?
if [ $rc -eq 1 ]; then
	echo "[APT-SYNC] SKIPPED $(TS) - sync already running"
fi
exit $rc
EOF
chmod +x /usr/local/bin/flock-apt-mirror.sh

# Start an initial apt-mirror under flock in the background if lock is free.
/usr/local/bin/flock-apt-mirror.sh &

# Write the cron file with a flock wrapper to avoid overlapping scheduled runs.
cat >/etc/cron.d/apt-mirror <<CRON
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
${APT_CRON_SCHEDULE} root /usr/local/bin/flock-apt-mirror.sh >> /proc/1/fd/1 2>> /proc/1/fd/2
CRON

chmod 0644 /etc/cron.d/apt-mirror || true

# Start cron in foreground so docker logs capture it
exec cron -f
