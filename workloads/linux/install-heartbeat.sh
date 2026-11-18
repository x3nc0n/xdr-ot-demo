#!/usr/bin/env bash
set -euo pipefail
[[ $EUID == 0 ]] || { printf '%s\n' 'Run as root.' >&2; exit 1; }
command -v logger >/dev/null
command -v systemctl >/dev/null
command -v rsyslogd >/dev/null || { printf '%s\n' 'Install staged rsyslog through the approved maintenance proxy first.' >&2; exit 1; }
systemctl is-active --quiet rsyslog.service || { printf '%s\n' 'Start rsyslog before installing the telemetry workload.' >&2; exit 1; }
source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$source_dir/heartbeat.sh" ]]
install -d -m 0755 /usr/local/lib/ot-lab
install -d -m 0700 /var/lib/ot-lab
install -m 0755 "$source_dir/heartbeat.sh" /usr/local/lib/ot-lab/heartbeat.sh
cat > /etc/systemd/system/ot-lab-heartbeat.service <<'UNIT'
[Unit]
Description=Benign local OT lab telemetry heartbeat
[Service]
Type=oneshot
ExecStart=/usr/local/lib/ot-lab/heartbeat.sh
User=root
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/ot-lab
PrivateTmp=true
UNIT
cat > /etc/systemd/system/ot-lab-heartbeat.timer <<'UNIT'
[Unit]
Description=Emit benign OT lab heartbeat each minute
[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=1
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now ot-lab-heartbeat.timer
systemctl start ot-lab-heartbeat.service
printf '%s\n' 'Heartbeat active. Verify journalctl -t OT-Lab and rsyslog/local0 routing to AMA; journald alone is not proof of syslog ingestion.'
