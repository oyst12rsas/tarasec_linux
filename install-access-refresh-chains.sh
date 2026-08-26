#!/bin/bash
# Apply the access-refresh + dedicated-chain update to an existing TaraSec Linux hotspot.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"

for f in tarasec-access-refresh tarasec-access-enforce tarasec-hotspot-firewall; do
  [ -f "$DIR/$f" ] || { echo "Missing $DIR/$f" >&2; exit 1; }
done

install -m 0755 "$DIR/tarasec-access-refresh" /usr/local/sbin/tarasec-access-refresh
install -m 0755 "$DIR/tarasec-access-enforce" /usr/local/sbin/tarasec-access-enforce
install -m 0755 "$DIR/tarasec-hotspot-firewall" /usr/local/sbin/tarasec-hotspot-firewall

# The local captive-portal name must be answered by the dedicated hotspot DNS server.
if [ -f /etc/tarasec/dnsmasq-hotspot.conf ]; then
  grep -q '^address=/status\.client/' /etc/tarasec/dnsmasq-hotspot.conf || \
    echo 'address=/status.client/192.168.50.1' >> /etc/tarasec/dnsmasq-hotspot.conf
fi

systemctl restart tarasec-hotspot-firewall.service
systemctl restart tarasec-hotspot-dnsmasq.service

# Refresh access immediately, then enforce it. No openNDS restart is required.
/usr/local/sbin/tarasec-access-refresh || true
/usr/local/sbin/tarasec-access-enforce || true

echo "=== access refresh ==="
cat /run/tarasec-access-refresh.json 2>/dev/null || true
echo
echo "=== access enforcement ==="
cat /run/tarasec-access-enforcement.json 2>/dev/null || true
echo
echo "=== TaraSec firewall chains ==="
iptables -S TARASEC-HOTSPOT-IN 2>/dev/null || true
iptables -S TARASEC-HOTSPOT-FWD 2>/dev/null || true
iptables -t nat -S TARASEC-HOTSPOT-PRE 2>/dev/null || true
iptables -t nat -S TARASEC-HOTSPOT-NAT 2>/dev/null || true
