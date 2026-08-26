#!/bin/bash
# Apply access-refresh, usage accounting, dedicated firewall chains and captive-login listener
# to an existing TaraSec Linux hotspot.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }
DIR="$(cd "$(dirname "$0")" && pwd)"

for f in tarasec-access-refresh tarasec-access-enforce tarasec-usage-sync tarasec-hotspot-firewall theme_tarasec.sh; do
  [ -f "$DIR/$f" ] || { echo "Missing $DIR/$f" >&2; exit 1; }
done

install -m 0755 "$DIR/tarasec-access-refresh" /usr/local/sbin/tarasec-access-refresh
install -m 0755 "$DIR/tarasec-access-enforce" /usr/local/sbin/tarasec-access-enforce
install -m 0755 "$DIR/tarasec-usage-sync" /usr/local/sbin/tarasec-usage-sync
install -m 0755 "$DIR/tarasec-hotspot-firewall" /usr/local/sbin/tarasec-hotspot-firewall
install -m 0755 "$DIR/theme_tarasec.sh" /usr/lib/opennds/theme_tarasec.sh

HOTSPOT_ADDR=""
if [ -f /etc/tarasec/dnsmasq-hotspot.conf ]; then
  HOTSPOT_ADDR=$(sed -n 's/^listen-address=//p' /etc/tarasec/dnsmasq-hotspot.conf | head -1)
fi
if [ -z "$HOTSPOT_ADDR" ]; then
  CLIENT_IF=$(awk '$1=="GatewayInterface"{v=$2} END{print v}' /etc/opennds/opennds.conf 2>/dev/null || true)
  [ -n "$CLIENT_IF" ] && HOTSPOT_ADDR=$(ip -4 -o addr show dev "$CLIENT_IF" scope global | awk '{split($4,a,"/"); print a[1]; exit}')
fi
[ -n "$HOTSPOT_ADDR" ] || { echo "Unable to determine hotspot address" >&2; exit 1; }
HOTSPOT_SUBNET="${HOTSPOT_ADDR%.*}.0/24"

if [ -f /etc/tarasec/dnsmasq-hotspot.conf ]; then
  sed -i '/^address=\/status\.client\//d' /etc/tarasec/dnsmasq-hotspot.conf
  echo "address=/status.client/$HOTSPOT_ADDR" >> /etc/tarasec/dnsmasq-hotspot.conf
fi

if command -v apache2ctl >/dev/null 2>&1; then
  cat >/etc/apache2/conf-available/tarasec-captive-login.conf <<EOF
Listen 8080
<VirtualHost *:8080>
    DocumentRoot /var/www/html
    <Directory /var/www/html/hotspot>
        Require ip $HOTSPOT_SUBNET
        Options -Indexes
        AllowOverride None
    </Directory>
    ErrorLog \${APACHE_LOG_DIR}/tarasec-captive-login-error.log
    CustomLog \${APACHE_LOG_DIR}/tarasec-captive-login-access.log combined
</VirtualHost>
EOF
  a2enconf tarasec-captive-login >/dev/null
  apache2ctl configtest
  systemctl reload apache2
else
  echo "Apache is required for the captive login listener" >&2
  exit 1
fi

if [ -f /etc/opennds/opennds.conf ] && ! awk '
  /^FirewallRuleSet users-to-router[[:space:]]*\{/ {inside=1}
  inside && /FirewallRule allow tcp port 8080/ {found=1}
  inside && /^[[:space:]]*}/ {inside=0}
  END{exit !found}
' /etc/opennds/opennds.conf; then
  tmp=$(mktemp)
  awk '
    /^FirewallRuleSet users-to-router[[:space:]]*\{/ {inside=1}
    inside && /^[[:space:]]*}/ {print "   FirewallRule allow tcp port 8080"; inside=0}
    {print}
  ' /etc/opennds/opennds.conf >"$tmp"
  install -m 0644 "$tmp" /etc/opennds/opennds.conf
  rm -f "$tmp"
fi

systemctl restart tarasec-hotspot-firewall.service
systemctl restart tarasec-hotspot-dnsmasq.service

systemctl stop opennds.service 2>/dev/null || true
for n in $(seq 1 20); do pgrep -x opennds >/dev/null 2>&1 || break; sleep 0.5; done
if pgrep -x opennds >/dev/null 2>&1; then
  pkill -TERM -x opennds || true
  sleep 2
fi
rm -f /run/ndsctl.sock /run/ndsctl.lock
systemctl reset-failed opennds.service || true
for n in 1 2 3; do
  systemctl start opennds.service && break
  sleep 5
done
systemctl is-active --quiet opennds.service || { echo "openNDS failed to restart" >&2; exit 1; }

/usr/local/sbin/tarasec-usage-sync || true
/usr/local/sbin/tarasec-access-refresh || true
/usr/local/sbin/tarasec-access-enforce || true

echo "=== captive login listener ==="
ss -lntp | grep ':8080 ' || true
echo
echo "=== openNDS users-to-router 8080 ==="
grep -n -A12 'FirewallRuleSet users-to-router' /etc/opennds/opennds.conf | grep -E 'users-to-router|8080' || true
echo
echo "=== usage sync ==="
cat /run/tarasec-usage-sync.json 2>/dev/null || true
echo
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
