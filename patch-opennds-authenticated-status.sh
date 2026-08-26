#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash patch-opennds-authenticated-status.sh" >&2
  exit 1
fi

LIB=/usr/lib/opennds/libopennds.sh
BACKUP=/usr/lib/opennds/libopennds.sh.tarasec-original
HOTSPOT_ADDR=192.168.50.1

if [[ -r /etc/tarasec/hotspot.env ]]; then
  # shellcheck disable=SC1091
  . /etc/tarasec/hotspot.env || true
  HOTSPOT_ADDR="${TARASEC_HOTSPOT_ADDR:-$HOTSPOT_ADDR}"
fi

[[ -f "$LIB" ]] || { echo "Missing $LIB" >&2; exit 1; }

if [[ ! -f "$BACKUP" ]]; then
  cp -a "$LIB" "$BACKUP"
fi

python3 - "$LIB" "$HOTSPOT_ADDR" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
host=sys.argv[2]
s=p.read_text(encoding='utf-8')
marker='TARASEC_AUTH_STATUS_LOGOUT'
if marker in s:
    print('TaraSec authenticated-status link already installed.')
    raise SystemExit(0)

needle='You are already logged in and have access to the Internet.'
if needle not in s:
    raise SystemExit('Could not find openNDS authenticated-status text; refusing to patch unknown version')

replacement=(
    needle + '\n'
    '                    <br><br><!-- TARASEC_AUTH_STATUS_LOGOUT -->\n'
    f'                    <a href="http://{host}:8080/hotspot/portal_status.php" '
    'style="display:inline-block;padding:12px 18px;background:#a43737;color:#fff;'
    'text-decoration:none;border-radius:8px;font-weight:bold">Hotspot status / Log out</a>'
)
s=s.replace(needle,replacement,1)
p.write_text(s,encoding='utf-8')
print(f'Added TaraSec logout link using hotspot address {host}.')
PY

if ! bash -n "$LIB"; then
  cp -a "$BACKUP" "$LIB"
  echo "Patched libopennds.sh failed syntax check; original restored." >&2
  exit 1
fi

echo "=== PATCHED OPENNDS AUTHENTICATED STATUS ==="
grep -n -A6 -B3 'TARASEC_AUTH_STATUS_LOGOUT' "$LIB" || true

echo
echo "No openNDS restart is normally required because libopennds.sh is invoked per request."
echo "If the phone still shows cached content, close the captive window and reopen http://status.client."
