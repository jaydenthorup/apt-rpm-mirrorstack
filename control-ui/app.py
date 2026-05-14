import json
import os
import subprocess
import tempfile
from pathlib import Path

from flask import Flask, jsonify, request, send_from_directory

app = Flask(__name__, static_folder="static", static_url_path="")

BASE_CONFIG_DIR = Path(os.getenv("CONFIG_DIR", "/workspace/config"))
APT_CONFIG_FILE = BASE_CONFIG_DIR / "apt-mirror.list"
RPM_CONFIG_DIR = BASE_CONFIG_DIR / "rpm"
NGINX_CONFIG_FILE = BASE_CONFIG_DIR / "nginx.conf"
SCHEDULES_FILE = BASE_CONFIG_DIR / "schedules.env"

DEFAULT_APT_CRON = "0 */6 * * *"
DEFAULT_RPM_CRON = "15 */6 * * *"
DEFAULT_ARCH_CRON = "30 */6 * * *"

APT_SERVICE = os.getenv("APT_SERVICE", "ubuntu-mirror")
RPM_SERVICE = os.getenv("RPM_SERVICE", "rpm-mirror")
ARCH_SERVICE = os.getenv("ARCH_SERVICE", "arch-mirror")
NGINX_SERVICE = os.getenv("NGINX_SERVICE", "mirror-nginx")

APT_SYNC_COMMAND = '/usr/bin/flock -n /var/lock/aptmirror.lock -c "/usr/local/bin/run-apt-mirror-logged.sh"'

RPM_SYNC_COMMAND = (
    '/usr/bin/flock -n /var/lock/reposync.lock -c "'
    '/usr/local/bin/run-rpm-sync.sh"'
)

ARCH_SYNC_COMMAND = 'flock -n /tmp/archrsync.lock -c "/usr/local/bin/run-arch-rsync-logged.sh"'


def run_command(command: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(command, text=True, capture_output=True, check=check)


def validate_rpm_filename(name: str) -> Path:
    if "/" in name or "\\" in name or not name.endswith(".repo"):
        raise ValueError("Invalid RPM repo filename")
    return RPM_CONFIG_DIR / name


def shell_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"

def parse_schedules() -> dict[str, str]:
    schedules = {
        "apt": DEFAULT_APT_CRON,
        "rpm": DEFAULT_RPM_CRON,
        "arch": DEFAULT_ARCH_CRON,
    }

    if not SCHEDULES_FILE.exists():
        return schedules

    for line in SCHEDULES_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip().strip("\"").strip("'")
        if key == "APT_CRON_SCHEDULE" and value:
            schedules["apt"] = value
        elif key == "RPM_CRON_SCHEDULE" and value:
            schedules["rpm"] = value
        elif key == "ARCH_CRON_SCHEDULE" and value:
            schedules["arch"] = value

    return schedules


def save_schedules(apt_schedule: str, rpm_schedule: str, arch_schedule: str):
    content = (
        "# Managed by control-ui\n"
        f"APT_CRON_SCHEDULE={shell_single_quote(apt_schedule)}\n"
        f"RPM_CRON_SCHEDULE={shell_single_quote(rpm_schedule)}\n"
        f"ARCH_CRON_SCHEDULE={shell_single_quote(arch_schedule)}\n"
    )
    SCHEDULES_FILE.write_text(content, encoding="utf-8")


def validate_cron_expression(expression: str) -> bool:
    parts = expression.strip().split()
    return len(parts) == 5 and all(part != "" for part in parts)


def apply_apt_schedule(schedule: str):
    line = f"{schedule} {APT_SYNC_COMMAND}"
    command = [
        "docker",
        "exec",
        APT_SERVICE,
        "sh",
        "-lc",
        f"printf %s\\n {shell_single_quote(line)} > /etc/cron.d/apt-mirror && chmod 0644 /etc/cron.d/apt-mirror && crontab /etc/cron.d/apt-mirror",
    ]
    run_command(command)


def apply_rpm_schedule(schedule: str):
    line = f"{schedule} {RPM_SYNC_COMMAND}"
    command = [
        "docker",
        "exec",
        RPM_SERVICE,
        "sh",
        "-lc",
        f"printf %s\\n {shell_single_quote(line)} > /etc/cron.d/reposync && chmod 0644 /etc/cron.d/reposync && crontab /etc/cron.d/reposync",
    ]
    run_command(command)


def apply_arch_schedule(schedule: str):
    line = f"{schedule} {ARCH_SYNC_COMMAND}"
    command = [
        "docker",
        "exec",
        ARCH_SERVICE,
        "sh",
        "-lc",
        f"printf %s\\n {shell_single_quote(line)} > /etc/cron.d/arch-rsync && chmod 0644 /etc/cron.d/arch-rsync && crontab /etc/cron.d/arch-rsync",
    ]
    run_command(command)


@app.route("/")
def index():
    return send_from_directory("static", "index.html")


@app.route("/api/health")
def health():
    return jsonify({"ok": True})


@app.route("/api/status")
def status():
    services = [APT_SERVICE, RPM_SERVICE, ARCH_SERVICE]
    status_by_service = {}

    for service in services:
        try:
            result = run_command([
                "docker",
                "inspect",
                "--format",
                "{{.State.Status}}",
                service,
            ], check=False)
            if result.returncode == 0:
                status_by_service[service] = result.stdout.strip()
            else:
                status_by_service[service] = "unknown (not running)"
        except subprocess.CalledProcessError:
            status_by_service[service] = "error"
        except Exception:
            status_by_service[service] = "unavailable"

    return jsonify(status_by_service)


@app.route("/api/config/apt", methods=["GET"])
def get_apt_config():
    try:
        if not APT_CONFIG_FILE.exists():
            # Return empty template if file doesn't exist yet
            return jsonify({"content": "# APT Mirror config not found. Edit and save to create.\n"})
        return jsonify({"content": APT_CONFIG_FILE.read_text(encoding="utf-8")})
    except Exception as e:
        return jsonify({"error": str(e), "content": ""}), 500


@app.route("/api/config/apt", methods=["PUT"])
def save_apt_config():
    payload = request.get_json(silent=True) or {}
    content = payload.get("content")
    if not isinstance(content, str):
        return jsonify({"error": "Field 'content' must be a string"}), 400

    APT_CONFIG_FILE.write_text(content, encoding="utf-8")
    return jsonify({"saved": True})


@app.route("/api/config/rpm", methods=["GET"])
def list_rpm_configs():
    RPM_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    files = sorted(path.name for path in RPM_CONFIG_DIR.glob("*.repo"))
    return jsonify({"files": files})


@app.route("/api/config/rpm/<name>", methods=["GET"])
def get_rpm_config(name: str):
    try:
        path = validate_rpm_filename(name)
    except ValueError as error:
        return jsonify({"error": str(error)}), 400

    try:
        if not path.exists():
            # Return empty template if file doesn't exist yet
            return jsonify({"content": f"# RPM config for {name} not found. Edit and save to create.\n"})
        return jsonify({"content": path.read_text(encoding="utf-8")})
    except Exception as e:
        return jsonify({"error": str(e), "content": ""}), 500


@app.route("/api/config/rpm/<name>", methods=["PUT"])
def save_rpm_config(name: str):
    payload = request.get_json(silent=True) or {}
    content = payload.get("content")
    if not isinstance(content, str):
        return jsonify({"error": "Field 'content' must be a string"}), 400

    try:
        path = validate_rpm_filename(name)
    except ValueError as error:
        return jsonify({"error": str(error)}), 400

    RPM_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    return jsonify({"saved": True})


@app.route("/api/jobs/run", methods=["POST"])
def run_job():
    payload = request.get_json(silent=True) or {}
    target = payload.get("target")

    if target == "apt":
        command = [
            "docker",
            "exec",
            "-d",
            APT_SERVICE,
            "sh",
            "-lc",
            APT_SYNC_COMMAND,
        ]
    elif target == "rpm":
        command = [
            "docker",
            "exec",
            "-d",
            RPM_SERVICE,
            "sh",
            "-lc",
            RPM_SYNC_COMMAND,
        ]
    elif target == "arch":
        command = [
            "docker",
            "exec",
            "-d",
            ARCH_SERVICE,
            "sh",
            "-lc",
            ARCH_SYNC_COMMAND,
        ]
    else:
        return jsonify({"error": "target must be one of: apt, rpm, arch"}), 400

    try:
        result = run_command(command)
        return jsonify({"started": True, "target": target, "exec_id": result.stdout.strip()})
    except subprocess.CalledProcessError as error:
        return (
            jsonify(
                {
                    "started": False,
                    "target": target,
                    "error": error.stderr.strip() or error.stdout.strip(),
                }
            ),
            500,
        )


@app.route("/api/logs/<target>", methods=["GET"])
def get_logs(target: str):
    service_map = {
        "apt": APT_SERVICE,
        "rpm": RPM_SERVICE,
        "arch": ARCH_SERVICE,
        "ubuntu-mirror": APT_SERVICE,
        "rpm-mirror": RPM_SERVICE,
        "arch-mirror": ARCH_SERVICE,
    }

    service = service_map.get(target)
    if not service:
        return jsonify({"error": "Unknown target. Use apt, rpm, or arch."}), 400

    tail = request.args.get("tail", "300")
    if not tail.isdigit():
        return jsonify({"error": "tail must be numeric"}), 400

    try:
        result = run_command(["docker", "logs", "--tail", tail, service], check=False)
        output = (result.stdout or "") + (result.stderr or "")
        return jsonify({"target": target, "service": service, "logs": output})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


@app.route("/api/config/export", methods=["GET"])
def export_config_snapshot():
    RPM_CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    schedules = parse_schedules()
    snapshot = {
        "apt": APT_CONFIG_FILE.read_text(encoding="utf-8") if APT_CONFIG_FILE.exists() else "",
        "rpm": {
            path.name: path.read_text(encoding="utf-8")
            for path in sorted(RPM_CONFIG_DIR.glob("*.repo"))
        },
        "schedules": schedules,
    }
    return app.response_class(
        json.dumps(snapshot, indent=2),
        mimetype="application/json",
    )


@app.route("/api/schedule", methods=["GET"])
def get_schedules():
    return jsonify(parse_schedules())


@app.route("/api/schedule", methods=["PUT"])
def set_schedules():
    payload = request.get_json(silent=True) or {}
    apt_schedule = str(payload.get("apt", "")).strip()
    rpm_schedule = str(payload.get("rpm", "")).strip()
    arch_schedule = str(payload.get("arch", "")).strip()
    apply_now = bool(payload.get("applyNow", True))

    if not validate_cron_expression(apt_schedule):
        return jsonify({"error": "Invalid APT cron expression. Use 5-field cron format."}), 400
    if not validate_cron_expression(rpm_schedule):
        return jsonify({"error": "Invalid RPM cron expression. Use 5-field cron format."}), 400
    if not validate_cron_expression(arch_schedule):
        return jsonify({"error": "Invalid Arch cron expression. Use 5-field cron format."}), 400

    save_schedules(apt_schedule, rpm_schedule, arch_schedule)

    if apply_now:
        errors = {}
        try:
            apply_apt_schedule(apt_schedule)
        except subprocess.CalledProcessError as error:
            errors["apt"] = error.stderr.strip() or error.stdout.strip()

        try:
            apply_rpm_schedule(rpm_schedule)
        except subprocess.CalledProcessError as error:
            errors["rpm"] = error.stderr.strip() or error.stdout.strip()

        try:
            apply_arch_schedule(arch_schedule)
        except subprocess.CalledProcessError as error:
            errors["arch"] = error.stderr.strip() or error.stdout.strip()

        if errors:
            return jsonify({"saved": True, "applied": False, "errors": errors}), 207

    return jsonify({"saved": True, "applied": apply_now})


def validate_nginx_config(content: str) -> tuple[bool, str]:
    """Validate NGINX config syntax by writing to temp file and testing in container."""
    try:
        with tempfile.NamedTemporaryFile(mode="w", suffix=".conf", delete=False, text=True) as f:
            f.write(content)
            temp_path = f.name
        
        # Use docker run with nginx image to validate
        result = run_command(
            ["docker", "run", "--rm", "-v", f"{temp_path}:/etc/nginx/conf.d/test.conf:ro", "nginx:alpine", "nginx", "-t"],
            check=False,
        )
        
        # Clean up temp file
        os.unlink(temp_path)
        
        if result.returncode == 0:
            return True, "NGINX config is valid"
        else:
            error_msg = result.stderr.strip() if result.stderr else result.stdout.strip()
            return False, f"NGINX config invalid: {error_msg}"
    except Exception as e:
        return False, f"Validation error: {str(e)}"


def reload_nginx() -> tuple[bool, str]:
    """Reload NGINX config in running container."""
    try:
        result = run_command(
            ["docker", "exec", NGINX_SERVICE, "nginx", "-s", "reload"],
            check=False,
        )
        if result.returncode == 0:
            return True, "NGINX reloaded successfully"
        else:
            error_msg = result.stderr.strip() if result.stderr else result.stdout.strip()
            return False, f"NGINX reload failed: {error_msg}"
    except Exception as e:
        return False, f"Reload error: {str(e)}"


@app.route("/api/config/nginx", methods=["GET"])
def get_nginx_config():
    try:
        if not NGINX_CONFIG_FILE.exists():
            # Return empty template if file doesn't exist yet
            return jsonify({"content": "# NGINX config not found. Edit and save to create.\n"})
        return jsonify({"content": NGINX_CONFIG_FILE.read_text(encoding="utf-8")})
    except Exception as e:
        return jsonify({"error": str(e), "content": ""}), 500


@app.route("/api/config/nginx", methods=["PUT"])
def save_nginx_config():
    payload = request.get_json(silent=True) or {}
    content = payload.get("content")
    if not isinstance(content, str):
        return jsonify({"error": "Field 'content' must be a string"}), 400
    
    # Validate syntax before saving
    valid, msg = validate_nginx_config(content)
    if not valid:
        return jsonify({"error": msg}), 400
    
    NGINX_CONFIG_FILE.write_text(content, encoding="utf-8")
    
    # Try to reload NGINX if running
    reload_ok, reload_msg = reload_nginx()
    if not reload_ok:
        return jsonify({"saved": True, "reloaded": False, "reload_error": reload_msg}), 207
    
    return jsonify({"saved": True, "reloaded": True})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8088)



if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8088)
