#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$DIR/tarasec-payment-agent" ] || { echo "Missing tarasec-payment-agent" >&2; exit 1; }

install -m 0755 "$DIR/tarasec-payment-agent" /usr/local/sbin/tarasec-payment-agent
mkdir -p /etc/tarasec

if [ ! -f /etc/tarasec/payment-client.php ]; then
cat >/etc/tarasec/payment-client.php <<'EOF'
<?php
// Fill these values when the hotspot is registered with TaraSec Payment.
return [
    'base_url' => 'https://payments.tarasec.org',
    'hotspot_id' => 'CHANGE_ME',
    'api_token' => 'CHANGE_ME',
];
EOF
fi
chown root:www-data /etc/tarasec/payment-client.php
chmod 0640 /etc/tarasec/payment-client.php

cat >/etc/systemd/system/tarasec-payment-agent.service <<'EOF'
[Unit]
Description=TaraSec hotspot payment entitlement sync
After=network-online.target mariadb.service mysql.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tarasec-payment-agent
EOF

cat >/etc/systemd/system/tarasec-payment-agent.timer <<'EOF'
[Unit]
Description=Check TaraSec paid hotspot entitlements every minute

[Timer]
OnBootSec=45s
OnUnitActiveSec=60s
AccuracySec=5s
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now tarasec-payment-agent.timer

echo "TaraSec payment agent installed."
echo "Configure: /etc/tarasec/payment-client.php"
systemctl status tarasec-payment-agent.timer --no-pager || true
