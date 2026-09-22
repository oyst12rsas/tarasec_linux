#!/bin/bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"

for f in tarasec-management-firewall tarasec-mgmt-client; do
  [ -f "$DIR/$f" ] || { echo "Missing $DIR/$f" >&2; exit 1; }
done

install -d -m 0755 /etc/tarasec
[ -e /etc/tarasec/management-clients ] || install -m 0600 /dev/null /etc/tarasec/management-clients
install -o root -g root -m 0755 "$DIR/tarasec-management-firewall" /usr/local/sbin/tarasec-management-firewall
install -o root -g root -m 0755 "$DIR/tarasec-mgmt-client" /usr/local/sbin/tarasec-mgmt-client

cat >/etc/systemd/system/tarasec-management-firewall.service <<'EOF'
[Unit]
Description=TaraSec selective hotspot owner access to management VPN
After=network-online.target netbird.service tarasec-hotspot-firewall.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tarasec-management-firewall
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tarasec-management-firewall.service
systemctl restart tarasec-management-firewall.service

echo "=== TARASEC MANAGEMENT ACCESS ==="
systemctl status tarasec-management-firewall.service --no-pager || true
echo
echo "Grant a verified owner/admin device with:"
echo "  sudo tarasec-mgmt-client add <hotspot-client-ip>"
echo "Revoke it with:"
echo "  sudo tarasec-mgmt-client remove <hotspot-client-ip>"
