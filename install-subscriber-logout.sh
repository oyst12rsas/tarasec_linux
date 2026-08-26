#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash install-subscriber-logout.sh" >&2
  exit 1
fi

HELPER=/usr/local/sbin/tarasec-client-deauth
CUSTOM=/usr/lib/opennds/custombinauth.sh
MARK_BEGIN='# BEGIN TARASEC SUBSCRIBER LOGOUT'
MARK_END='# END TARASEC SUBSCRIBER LOGOUT'

if [[ ! -f "$CUSTOM" ]]; then
  echo "Missing openNDS custom BinAuth hook: $CUSTOM" >&2
  exit 1
fi

cat > "$HELPER" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

IP="${1:-}"
if [[ ! "$IP" =~ ^192\.168\.50\.([0-9]{1,3})$ ]]; then
  logger -t tarasec-logout "ignored invalid/non-hotspot client ip: $IP"
  exit 2
fi
OCTET=${BASH_REMATCH[1]}
if (( OCTET < 1 || OCTET > 254 )); then
  logger -t tarasec-logout "ignored invalid hotspot client ip: $IP"
  exit 2
fi

# This helper is called only for openNDS action=client_deauth, which means the
# subscriber deliberately used the captive/status page logout action.
mysql taransvar <<SQL
UPDATE session
SET active=0,
    logouttime=COALESCE(logouttime,NOW()),
    lastrequest=NOW()
WHERE ip='$IP'
  AND active=1;

DELETE FROM access
WHERE ip='$IP';
SQL

logger -t tarasec-logout "subscriber logout closed TaraSec session/access for $IP"
SH
chmod 0755 "$HELPER"
chown root:root "$HELPER"

# Remove any older TaraSec block, then append the current one. Do not replace
# openNDS's default binauth_log.sh: it owns auth_restore and other core state.
TMP=$(mktemp)
awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
  $0==b {skip=1; next}
  $0==e {skip=0; next}
  !skip {print}
' "$CUSTOM" > "$TMP"
cat >> "$TMP" <<'SH'

# BEGIN TARASEC SUBSCRIBER LOGOUT
# openNDS v10.1+ sources this file with action and clientip populated.
# Only an explicit client-side captive/status-page logout is allowed to end
# the TaraSec subscriber session. Idle/timeout/ndsctl/restart events do not.
if [ "${action:-}" = "client_deauth" ] && [ -n "${clientip:-}" ]; then
    /usr/local/sbin/tarasec-client-deauth "$clientip" >/dev/null 2>&1 || true
fi
# END TARASEC SUBSCRIBER LOGOUT
SH
install -o root -g root -m 0755 "$TMP" "$CUSTOM"
rm -f "$TMP"

echo "=== TaraSec subscriber logout hook ==="
grep -n -A9 -B2 'BEGIN TARASEC SUBSCRIBER LOGOUT' "$CUSTOM"

echo
echo "=== helper ==="
ls -l "$HELPER"

echo
echo "No openNDS restart required; custombinauth.sh is evaluated on BinAuth events."
echo "Test from an authenticated client by opening http://status.client and choosing Logout."
