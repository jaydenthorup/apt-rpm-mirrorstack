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

exit "$status"
EOF
chmod +x /usr/local/bin/run-apt-mirror-logged.sh

# Start an initial apt-mirror under flock in the background if lock is free.
/usr/bin/flock -n /var/lock/aptmirror.lock -c "/usr/local/bin/run-apt-mirror-logged.sh" &

# Write the cron file with a flock wrapper to avoid overlapping scheduled runs.
cat >/etc/cron.d/apt-mirror <<CRON
${APT_CRON_SCHEDULE} /usr/bin/flock -n /var/lock/aptmirror.lock -c "/usr/local/bin/run-apt-mirror-logged.sh"
CRON

chmod 0644 /etc/cron.d/apt-mirror || true
crontab /etc/cron.d/apt-mirror || true

# Start cron in foreground so docker logs capture it
exec cron -f
