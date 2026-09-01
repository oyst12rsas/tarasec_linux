#!/bin/bash
# Make successful TaraSec subscriber login continue directly into openNDS
# authorization instead of rendering a separate confirmation layout.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo/root" >&2; exit 1; }

PORTAL="${TARASEC_PORTAL_LOGIN:-/var/www/html/hotspot/portal_login.php}"
BACKUP="${PORTAL}.tarasec-pre-auto-continue"

[ -f "$PORTAL" ] || { echo "Missing $PORTAL" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }
command -v php >/dev/null 2>&1 || { echo "php is required" >&2; exit 1; }

# Keep the first pre-change copy only.
[ -f "$BACKUP" ] || cp -a "$PORTAL" "$BACKUP"

python3 - "$PORTAL" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text(encoding='utf-8')
marker='TARASEC_AUTO_CONTINUE_SUCCESS'
if marker in s:
    sys.exit(0)
needle="""function portalReply($title, $message, $success = false, $fas = '')
{
    http_response_code($success ? 200 : 403);
"""
replacement="""function portalReply($title, $message, $success = false, $fas = '')
{
    // TARASEC_AUTO_CONTINUE_SUCCESS
    // A valid login should not stop on a second, differently-styled success
    // page. Continue directly back into the TaraSec/openNDS authorization
    // flow. Error replies still render locally below.
    if ($success && $fas !== '') {
        $target = 'http://status.client/opennds_preauth/?fas=' . rawurlencode($fas) . '&continue=clicked';
        header('Location: ' . $target, true, 303);
        exit;
    }

    http_response_code($success ? 200 : 403);
"""
if needle not in s:
    raise SystemExit('Could not find portalReply() header block; no change made')
s=s.replace(needle,replacement,1)
p.write_text(s,encoding='utf-8')
PY

if ! php -l "$PORTAL" >/dev/null; then
  cp -a "$BACKUP" "$PORTAL"
  echo "PHP validation failed; restored original portal_login.php" >&2
  exit 1
fi

echo "=== portal_login.php success flow ==="
grep -n -A13 -B2 'TARASEC_AUTO_CONTINUE_SUCCESS' "$PORTAL"
echo
echo "=== PHP syntax ==="
php -l "$PORTAL"
echo
echo "Successful subscriber login now redirects immediately into TaraSec/openNDS authorization."
echo "Login errors still render from portal_login.php."
