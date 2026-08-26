#!/bin/bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

install -m 0755 "$REPO_DIR/tarasec-access-check" /usr/local/sbin/tarasec-access-check
install -m 0755 "$REPO_DIR/tarasec-access-enforce" /usr/local/sbin/tarasec-access-enforce

cat >/etc/systemd/system/tarasec-access-enforce.service <<'EOF'
[Unit]
Description=TaraSec synchronize openNDS clients with access table
After=opennds.service
Wants=opennds.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tarasec-access-enforce
EOF

cat >/etc/systemd/system/tarasec-access-enforce.timer <<'EOF'
[Unit]
Description=Check TaraSec hotspot access every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s
Unit=tarasec-access-enforce.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now tarasec-access-enforce.timer
systemctl start tarasec-access-enforce.service || true

echo "TaraSec access enforcement installed."
echo "State: /run/tarasec-access-enforcement.json"
