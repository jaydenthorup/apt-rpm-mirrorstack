#!/bin/bash
# Minimal entrypoint for rpm-mirror: ensure cron always starts and prevent duplicate runs via flock.
set -u

# create lock dir
mkdir -p /var/lock

# Load schedule settings if provided
if [ -f /etc/mirror-schedules.env ]; then
	# shellcheck disable=SC1091
	. /etc/mirror-schedules.env
fi

RPM_CRON_SCHEDULE="${RPM_CRON_SCHEDULE:-15 */6 * * *}"

# Disable SSL verification for AlmaLinux repos (TLS interception in restricted networks)
mkdir -p /etc/dnf/vars
echo "1" > /etc/dnf/vars/protect_packages || true
echo "1" > /etc/dnf/vars/skip_unavailable || true

# Install packages if needed (non-fatal; disable SSL check to work in restricted networks)
dnf -y install dnf-utils createrepo_c cronie --setopt=sslverify=False || true

# Ensure mirror directories exist
mkdir -p /mirror/alma/9/BaseOS/x86_64/os /mirror/alma/9/AppStream/x86_64/os /mirror/alma/9/CRB/x86_64/os /mirror/alma/9/extras/x86_64/os || true

# Wrapper that runs reposync and refreshes repodata safely.
cat >/usr/local/bin/run-rpm-sync.sh <<'EOF'
#!/bin/bash
set -eu

sync_repo() {
	local repoid="$1"
	local target="$2"
	/usr/bin/reposync --download-metadata --delete --norepopath --repoid="${repoid}" --download-path="${target}"
}

refresh_repo() {
	local target="$1"
	if [ -d "${target}/.repodata" ]; then
		rm -rf "${target}/.repodata"
	fi
	/usr/bin/createrepo_c --update "${target}"
}

sync_repo almalinux-baseos /mirror/alma/9/BaseOS/x86_64/os
sync_repo almalinux-appstream /mirror/alma/9/AppStream/x86_64/os
sync_repo almalinux-crb /mirror/alma/9/CRB/x86_64/os
sync_repo almalinux-extras /mirror/alma/9/extras/x86_64/os

refresh_repo /mirror/alma/9/BaseOS/x86_64/os
refresh_repo /mirror/alma/9/AppStream/x86_64/os
refresh_repo /mirror/alma/9/CRB/x86_64/os
refresh_repo /mirror/alma/9/extras/x86_64/os
EOF
chmod +x /usr/local/bin/run-rpm-sync.sh

# Start an initial reposync+createrepo under flock in the background if lock is free.
# This prevents cron from starting a second concurrent run while the initial sync runs.
/usr/bin/flock -n /var/lock/reposync.lock -c "/usr/local/bin/run-rpm-sync.sh" &

# Write the cron file with a flock wrapper to avoid overlapping scheduled runs.
cat >/etc/cron.d/reposync <<CRON
${RPM_CRON_SCHEDULE} /usr/bin/flock -n /var/lock/reposync.lock -c "/usr/local/bin/run-rpm-sync.sh"
CRON

chmod 0644 /etc/cron.d/reposync || true
crontab /etc/cron.d/reposync || true

# Start crond in foreground so docker logs capture it
exec /usr/sbin/crond -n
