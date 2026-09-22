#!/bin/bash
# Repair captive-login reachability after hotspot hardening and add safe
# username remembering to the openNDS theme. Does not store passwords.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }

DIR="$(cd "$(dirname "$0")" && pwd)"
THEME="/usr/lib/opennds/theme_tarasec.sh"
HELPER_SRC="$DIR/tarasec-opennds-local-access"
HELPER_DST="/usr/local/sbin/tarasec-opennds-local-access"
DROPIN_DIR="/etc/systemd/system/opennds.service.d"
DROPIN="$DROPIN_DIR/20-tarasec-captive-login.conf"

[ -f "$THEME" ] || { echo "Missing $THEME" >&2; exit 1; }

# Keep TCP 8080 reachable through openNDS now and after every future restart.
if [ -f "$HELPER_SRC" ]; then
  install -m 0755 "$HELPER_SRC" "$HELPER_DST"
elif [ ! -x "$HELPER_DST" ]; then
  echo "Missing tarasec-opennds-local-access helper" >&2
  exit 1
fi

install -d "$DROPIN_DIR"
cat >"$DROPIN" <<'EOF'
[Service]
ExecStartPost=/usr/local/sbin/tarasec-opennds-local-access
EOF
systemctl daemon-reload
"$HELPER_DST"

# Safely remember only the username. The password remains controlled by the
# phone/browser password manager via autocomplete=current-password.
cp -a "$THEME" "$THEME.tarasec-pre-remember-user"
python3 - "$THEME" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')

if 'tarasec_hotspot_username' not in s:
    old='<form action=\\"$loginbase/portal_login.php\\" method=\\"post\\">'
    new='<form id=\\"tslogin\\" action=\\"$loginbase/portal_login.php\\" method=\\"post\\">'
    if old not in s:
        raise SystemExit('Could not find TaraSec login form')
    s=s.replace(old,new,1)

    old2='<label for=\\"tspass\\"><b>Password</b></label><input id=\\"tspass\\" class=\\"field\\" name=\\"pass\\" type=\\"password\\" autocomplete=\\"current-password\\" required>\n<input class=\\"btn\\" type=\\"submit\\" value=\\"Log in\\"></form>'
    new2='''<label for=\\"tspass\\"><b>Password</b></label><input id=\\"tspass\\" class=\\"field\\" name=\\"pass\\" type=\\"password\\" autocomplete=\\"current-password\\" required>\n<label class=\\"small\\" style=\\"display:block;margin:0 0 12px\\"><input id=\\"tsremember\\" type=\\"checkbox\\" checked> Remember username on this device</label>\n<input class=\\"btn\\" type=\\"submit\\" value=\\"Log in\\"></form>\n<script>(function(){try{var f=document.getElementById('tslogin'),u=document.getElementById('tsuser'),r=document.getElementById('tsremember'),k='tarasec_hotspot_username';var v=localStorage.getItem(k);if(v){u.value=v;}f.addEventListener('submit',function(){if(r.checked){localStorage.setItem(k,u.value);}else{localStorage.removeItem(k);}});}catch(e){}})();</script>'''
    if old2 not in s:
        raise SystemExit('Could not find TaraSec password/login controls')
    s=s.replace(old2,new2,1)

p.write_text(s,encoding='utf-8')
PY

if ! bash -n "$THEME"; then
  cp -a "$THEME.tarasec-pre-remember-user" "$THEME"
  echo "Theme syntax validation failed; restored original" >&2
  exit 1
fi

echo "=== openNDS captive-login rule ==="
nft list chain ip nds_filter ndsRTR | grep -E '8080|2050|reject' || true

echo
echo "=== persistent openNDS hook ==="
systemctl cat opennds | grep -A3 -B2 tarasec-opennds-local-access || true

echo
echo "=== username remembering ==="
grep -n -A7 -B3 'tsremember\|tarasec_hotspot_username' "$THEME" || true

echo
echo "No openNDS restart was performed."
