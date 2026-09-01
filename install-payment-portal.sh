#!/bin/bash
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }

THEME=/usr/lib/opennds/theme_tarasec.sh
PORTAL=/var/www/html/hotspot/portal_pay.php
SRC_URL='https://raw.githubusercontent.com/oyst12rsas/taransvar/feature/hotspot-captive-login-access/html/hotspot/portal_pay.php'

command -v curl >/dev/null 2>&1 || { echo "curl required" >&2; exit 1; }
[ -f "$THEME" ] || { echo "Missing $THEME" >&2; exit 1; }

curl -fsSL "$SRC_URL" -o "$PORTAL.tmp"
php -l "$PORTAL.tmp"
install -m 0644 "$PORTAL.tmp" "$PORTAL"
rm -f "$PORTAL.tmp"

cp -a "$THEME" "$THEME.pre-payment"
python3 - "$THEME" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
needle='<div class=\\"note\\"><b>Need access?</b><br>If this hotspot charges for access, use the hotspot\'s payment or access instructions. After a payment or account change has been registered, return here and check access again.</div>'
replacement='<div class=\\"note\\"><b>Need access?</b><br>Choose an available Internet plan and pay securely online, or ask the hotspot owner for a manual payment/access option.</div>\n<a class=\\"btn btn2\\" href=\\"$loginbase/portal_pay.php\\">View plans / Pay online</a>'
if 'portal_pay.php' not in s:
    if needle not in s:
        raise SystemExit('Could not find captive Need access block; theme left unchanged')
    s=s.replace(needle,replacement,1)
p.write_text(s)
PY

bash -n "$THEME"

echo "=== captive payment link ==="
grep -n -A3 -B2 'portal_pay.php' "$THEME" || true
echo
echo "=== payment bridge PHP ==="
php -l "$PORTAL"
echo
echo "No openNDS restart is required for ThemeSpec script changes."
