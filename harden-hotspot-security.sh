#!/bin/bash
# TaraSec hotspot security hardening - batch 1.
# - isolate hotspot PHP onto an external least-privilege DB credential
# - make the deployed legacy CDb read that credential outside the web root
# - remove SSH/admin HTTP(S) access from unauthenticated hotspot clients
# This script deliberately does not rotate/revoke the older shared DB account;
# other TaraSec web components may still use it and must be migrated separately.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }

DB_NAME="${TARASEC_HOTSPOT_DB:-taransvar}"
DB_USER="${TARASEC_HOTSPOT_DB_USER:-tarasec_hotspot_web}"
DB_HOST="localhost"
DB_CLASS="${TARASEC_HOTSPOT_DB_CLASS:-/var/www/html/hotspot/class/Db.class.php}"
DB_CONF="/etc/tarasec/hotspot-db.php"
OPENNDS_CONF="/etc/opennds/opennds.conf"

command -v mysql >/dev/null 2>&1 || { echo "mysql client is required" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
[ -f "$DB_CLASS" ] || { echo "Missing $DB_CLASS" >&2; exit 1; }

mkdir -p /etc/tarasec

# Reuse the generated password on repeated runs so the script is idempotent.
if [ -r "$DB_CONF" ]; then
  DB_PASS=$(php -r '$c=include $argv[1]; if(is_array($c)&&isset($c["password"])) echo $c["password"];' "$DB_CONF" 2>/dev/null || true)
else
  DB_PASS=""
fi
if [ -z "$DB_PASS" ]; then
  DB_PASS=$(openssl rand -base64 36 | tr -d '\n' | tr '/+' '_-')
fi

# Escape SQL single quotes even though generated values currently contain none.
sql_user=${DB_USER//\'/\'\'}
sql_pass=${DB_PASS//\'/\'\'}
mysql <<SQL
CREATE USER IF NOT EXISTS '$sql_user'@'localhost' IDENTIFIED BY '$sql_pass';
ALTER USER '$sql_user'@'localhost' IDENTIFIED BY '$sql_pass';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`$DB_NAME\`.* TO '$sql_user'@'localhost';
FLUSH PRIVILEGES;
SQL

umask 027
cat >"$DB_CONF" <<EOF
<?php
// Generated locally by TaraSec. Keep outside the web document root.
return array(
    'host' => '$DB_HOST',
    'database' => '$DB_NAME',
    'username' => '$DB_USER',
    'password' => '$DB_PASS',
);
EOF
chown root:www-data "$DB_CONF"
chmod 0640 "$DB_CONF"

# Patch only the credential-selection block in the deployed legacy CDb. Keep a
# backup and validate PHP syntax before accepting the change.
cp -a "$DB_CLASS" "$DB_CLASS.tarasec-pre-hardening"
python3 - "$DB_CLASS" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
replacement='''$tarasecDbConfigFile = "/etc/tarasec/hotspot-db.php";
        if (!is_readable($tarasecDbConfigFile)) {
            throw new RuntimeException("TaraSec hotspot DB configuration is missing or unreadable");
        }
        $tarasecDbConfig = include $tarasecDbConfigFile;
        if (!is_array($tarasecDbConfig)) {
            throw new RuntimeException("Invalid TaraSec hotspot DB configuration");
        }
        $szDBHost = isset($tarasecDbConfig['host']) ? $tarasecDbConfig['host'] : 'localhost';
        $szDBDBName = isset($tarasecDbConfig['database']) ? $tarasecDbConfig['database'] : 'taransvar';
        $szDBUserName = isset($tarasecDbConfig['username']) ? $tarasecDbConfig['username'] : '';
        $szDBPass = isset($tarasecDbConfig['password']) ? $tarasecDbConfig['password'] : '';
        unset($tarasecDbConfig);\n\n            try {'''
pattern=r'if \(file_exists\("system\.txt"\)\).*?\n\s*try \{'
new,n=re.subn(pattern,replacement,s,count=1,flags=re.S)
if n != 1:
    # Already hardened is fine; anything else is unsafe to guess.
    if '/etc/tarasec/hotspot-db.php' in s:
        sys.exit(0)
    raise SystemExit('Could not locate legacy CDb credential block; no change made')
p.write_text(new,encoding='utf-8')
PY

if ! php -l "$DB_CLASS" >/dev/null; then
  cp -a "$DB_CLASS.tarasec-pre-hardening" "$DB_CLASS"
  echo "PHP validation failed; restored original CDb" >&2
  exit 1
fi

# Remove management ports from openNDS' users-to-router rules. Captive clients
# only need the portal/DNS/DHCP paths. Management remains available through the
# host's non-hotspot interfaces (eg. TaraSec/NetBird management network).
if [ -f "$OPENNDS_CONF" ]; then
  python3 - "$OPENNDS_CONF" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
lines=p.read_text(encoding='utf-8').splitlines(True)
out=[]
in_users=False
for line in lines:
    if re.match(r'^\s*FirewallRuleSet\s+users-to-router\s*\{', line):
        in_users=True
        out.append(line)
        continue
    if in_users and re.match(r'^\s*}', line):
        in_users=False
        out.append(line)
        continue
    if in_users and re.search(r'FirewallRule\s+allow\s+tcp\s+port\s+(22|80|443)\b', line):
        continue
    out.append(line)
p.write_text(''.join(out),encoding='utf-8')
PY
fi

# Apply the management-port restriction immediately to the live openNDS nft
# chain without restarting openNDS. Delete only exact tcp dport 22/80/443 rules.
if command -v nft >/dev/null 2>&1 && nft list chain ip nds_filter ndsRTR >/dev/null 2>&1; then
  while read -r handle; do
    [ -n "$handle" ] && nft delete rule ip nds_filter ndsRTR handle "$handle" || true
  done < <(nft -a list chain ip nds_filter ndsRTR | awk '/tcp dport (22|80|443)/ {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
fi

echo "=== hotspot DB config ==="
ls -l "$DB_CONF"
echo "DB user: $DB_USER (password intentionally not displayed)"
echo
echo "=== PHP syntax ==="
php -l "$DB_CLASS"
echo
echo "=== hotspot DB connectivity ==="
php -r '$c=include "/etc/tarasec/hotspot-db.php"; new PDO("mysql:host=".$c["host"].";dbname=".$c["database"].";charset=utf8",$c["username"],$c["password"]); echo "ok\n";'
echo
echo "=== openNDS users-to-router config ==="
grep -n -A14 'FirewallRuleSet users-to-router' "$OPENNDS_CONF" 2>/dev/null || true
echo
echo "=== live openNDS router rules ==="
nft list chain ip nds_filter ndsRTR 2>/dev/null || true
