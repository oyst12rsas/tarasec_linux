#!/bin/bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)"
ACTION_SRC="$DIR/tarasec-hostapd-disconnect"
ACTION_DST="/usr/local/sbin/tarasec-hostapd-disconnect"
SERVICE="/etc/systemd/system/tarasec-hostapd-events.service"
IFACE="${TARASEC_HOTSPOT_IFACE:-wlan0}"

command -v hostapd_cli >/dev/null 2>&1 || { echo "hostapd_cli is required" >&2; exit 1; }
command -v ndsctl >/dev/null 2>&1 || { echo "ndsctl is required" >&2; exit 1; }
[ -f "$ACTION_SRC" ] || { echo "Missing $ACTION_SRC" >&2; exit 1; }

install -o root -g root -m 0755 "$ACTION_SRC" "$ACTION_DST"

cat >"$SERVICE" <<EOF
[Unit]
Description=TaraSec hostapd station event listener
After=hostapd.service opennds.service
Wants=hostapd.service opennds.service

[Service]
Type=simple
ExecStart=/usr/sbin/hostapd_cli -i $IFACE -a $ACTION_DST
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tarasec-hostapd-events.service

echo "=== HOSTAPD EVENT SERVICE ==="
systemctl status tarasec-hostapd-events.service --no-pager

echo
echo "=== NOTE ==="
echo "Wi-Fi disconnects now deauthenticate openNDS only; TaraSec subscriber sessions remain active."
