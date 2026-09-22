#!/bin/bash
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$DIR/tarasec-opennds-local-access" ] || { echo "Missing tarasec-opennds-local-access" >&2; exit 1; }

install -m 0755 "$DIR/tarasec-opennds-local-access" /usr/local/sbin/tarasec-opennds-local-access
install -d /etc/systemd/system/opennds.service.d
cat >/etc/systemd/system/opennds.service.d/20-tarasec-captive-login.conf <<'EOF'
[Service]
ExecStartPost=/usr/local/sbin/tarasec-opennds-local-access
EOF
systemctl daemon-reload

# Apply immediately without restarting openNDS.
/usr/local/sbin/tarasec-opennds-local-access

echo "=== openNDS captive-login rule ==="
nft list chain ip nds_filter ndsRTR | grep -E '8080|2050|reject' || true
