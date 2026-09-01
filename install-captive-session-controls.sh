#!/bin/bash
# TaraSec captive session controls:
# - allow Apache to request a safe, no-argument access-enforcement pass
# - install logout helper allowed only for the connecting hotspot IP
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }

cat >/usr/local/sbin/tarasec-captive-logout <<'EOF'
#!/bin/bash
set -euo pipefail
IP="${1:-}"
[[ "$IP" =~ ^192\.168\.50\.[0-9]{1,3}$ ]] || { echo "invalid hotspot ip" >&2; exit 2; }

mysql taransvar <<SQL
UPDATE session
   SET active=0, logouttime=NOW(), lastrequest=NOW()
 WHERE ip='$IP' AND active=1;
DELETE FROM access WHERE ip='$IP';
SQL

# Deauthenticate only this client if openNDS currently knows it.
MAC=$(ndsctl json 2>/dev/null | python3 -c 'import json,sys; ip=sys.argv[1]; d=json.load(sys.stdin); print(next((m for m,c in d.get("clients",{}).items() if c.get("ip")==ip),""))' "$IP" || true)
if [ -n "$MAC" ]; then
    ndsctl deauth "$MAC" >/dev/null 2>&1 || true
fi
logger -t tarasec-access "subscriber logout $IP${MAC:+/$MAC}"
EOF
chmod 0755 /usr/local/sbin/tarasec-captive-logout

cat >/etc/sudoers.d/tarasec-captive <<'EOF'
# Captive PHP may only request TaraSec's fixed enforcement command, or logout a
# client from the hotspot IPv4 range. The helper itself validates the address.
www-data ALL=(root) NOPASSWD: /usr/local/sbin/tarasec-access-enforce
www-data ALL=(root) NOPASSWD: /usr/local/sbin/tarasec-captive-logout 192.168.50.*
EOF
chmod 0440 /etc/sudoers.d/tarasec-captive
visudo -cf /etc/sudoers.d/tarasec-captive >/dev/null

echo "=== captive sudo policy ==="
visudo -cf /etc/sudoers.d/tarasec-captive
