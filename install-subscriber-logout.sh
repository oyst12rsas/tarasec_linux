#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo bash install-subscriber-logout.sh" >&2
  exit 1
fi

HELPER=/usr/local/sbin/tarasec-subscriber-logout
CUSTOM=/usr/lib/opennds/custombinauth.sh
STATUS=/var/www/html/hotspot/portal_status.php
SUDOERS=/etc/sudoers.d/tarasec-subscriber-logout
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
  exit 2
fi

mysql taransvar <<SQL
UPDATE session
SET active=0,
    logouttime=COALESCE(logouttime,NOW()),
    lastrequest=NOW()
WHERE ip='$IP' AND active=1;
DELETE FROM access WHERE ip='$IP';
SQL

MAC="$(ip neigh show "$IP" 2>/dev/null | awk '/lladdr/{print $5; exit}')"
if [[ "$MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
  ndsctl deauth "$MAC" >/dev/null 2>&1 || true
fi
logger -t tarasec-logout "subscriber logout closed TaraSec session/access for $IP${MAC:+/$MAC}"
SH
install -o root -g root -m 0755 "$HELPER" "$HELPER"

cat > "$SUDOERS" <<EOF
www-data ALL=(root) NOPASSWD: $HELPER *
EOF
chmod 0440 "$SUDOERS"
visudo -cf "$SUDOERS" >/dev/null

cat > "$STATUS" <<'PHP'
<?php
declare(strict_types=1);
session_start();
header('Cache-Control: no-store');
$ip=(string)($_SERVER['REMOTE_ADDR'] ?? '');
if (!preg_match('/^192\.168\.50\.(?:[1-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])$/D',$ip)) {
    http_response_code(403); exit('Hotspot clients only');
}
if (empty($_SESSION['ts_logout_csrf'])) $_SESSION['ts_logout_csrf']=bin2hex(random_bytes(32));
$msg='';
if ($_SERVER['REQUEST_METHOD']==='POST' && isset($_POST['logout'])) {
    $csrf=(string)($_POST['csrf'] ?? '');
    if (!$csrf || !hash_equals((string)$_SESSION['ts_logout_csrf'],$csrf)) {
        http_response_code(400); exit('Invalid request');
    }
    $cmd='sudo /usr/local/sbin/tarasec-subscriber-logout '.escapeshellarg($ip).' 2>&1';
    exec($cmd,$out,$rc);
    if ($rc!==0) { http_response_code(500); $msg='Unable to log out. Please try again.'; }
    else {
        $_SESSION=[]; session_destroy();
        echo '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="1;url=http://neverssl.com/"><title>TaraSec WiFi</title><style>body{font-family:Arial;background:#eef3f8;margin:0}.card{max-width:560px;margin:40px auto;background:white;padding:24px;border-radius:14px}.ok{color:#168b4a}</style></head><body><div class="card"><h2 class="ok">Logged out</h2><p>Your TaraSec hotspot session has been closed. The captive portal will appear again when you continue browsing.</p></div></body></html>';
        exit;
    }
}
$cfg=require '/etc/tarasec/hotspot-db.php';
$pdo=new PDO('mysql:host='.$cfg['host'].';dbname='.$cfg['database'].';charset=utf8mb4',$cfg['username'],$cfg['password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
$st=$pdo->prepare('SELECT s.username,r.subscriptionType,r.expirytime,r.mbquota,COALESCE(r.mbusage,0) mbusage FROM session s LEFT JOIN radcheck r ON r.username=s.username WHERE s.ip=? AND s.active=1 ORDER BY s.sessionid DESC LIMIT 1');
$st->execute([$ip]); $row=$st->fetch();
function h($s){return htmlspecialchars((string)$s,ENT_QUOTES|ENT_SUBSTITUTE,'UTF-8');}
?><!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>TaraSec WiFi</title><style>*{box-sizing:border-box}body{margin:0;font-family:Arial;background:#eef3f8;color:#172233}.top{background:#17212d;color:white;padding:16px 20px;font-size:20px;font-weight:700}.card{max-width:620px;margin:28px auto;background:white;padding:24px;border-radius:14px;box-shadow:0 3px 14px #0002}.ok{color:#168b4a}.btn{width:100%;padding:13px;border:0;border-radius:8px;background:#a43737;color:white;font-size:16px;font-weight:700}.note{background:#eef7ff;padding:12px;border-left:4px solid #268bc7;margin:15px 0}</style></head><body><div class="top">TaraSec <span style="font-weight:400;font-size:13px">Hotspot</span></div><div class="card"><h2 class="ok">Internet access active</h2><?php if($row):?><p>Signed in as <b><?=h($row['username'])?></b>.</p><div class="note"><?php if($row['subscriptionType']==='expiry'):?>Access until <?=h($row['expirytime'])?>.<?php elseif($row['subscriptionType']==='quota'):?>Used <?=h(round((float)$row['mbusage'],1))?> MB of <?=h(round((float)$row['mbquota'],1))?> MB.<?php else:?>Subscription: <?=h($row['subscriptionType'])?>.<?php endif?></div><form method="post"><input type="hidden" name="csrf" value="<?=h($_SESSION['ts_logout_csrf'])?>"><button class="btn" name="logout" value="1">Log out of this hotspot</button></form><?php else:?><p>No active TaraSec subscriber session was found for this device.</p><?php endif?><?php if($msg):?><p><?=h($msg)?></p><?php endif?></div></body></html>
PHP
chown root:www-data "$STATUS"
chmod 0644 "$STATUS"
php -l "$STATUS"

# Keep the native openNDS client_deauth hook as a fallback if an old openNDS
# logout page is reached. Normal TaraSec logout now uses portal_status.php.
TMP=$(mktemp)
awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
  $0==b {skip=1; next}
  $0==e {skip=0; next}
  !skip {print}
' "$CUSTOM" > "$TMP"
cat >> "$TMP" <<'SH'

# BEGIN TARASEC SUBSCRIBER LOGOUT
if [ "${action:-}" = "client_deauth" ] && [ -n "${clientip:-}" ]; then
    /usr/local/sbin/tarasec-subscriber-logout "$clientip" >/dev/null 2>&1 || true
fi
# END TARASEC SUBSCRIBER LOGOUT
SH
install -o root -g root -m 0755 "$TMP" "$CUSTOM"
rm -f "$TMP"

echo "=== TaraSec subscriber status/logout ==="
echo "http://192.168.50.1:8080/hotspot/portal_status.php"
php -l "$STATUS"
ls -l "$HELPER" "$STATUS" "$SUDOERS"
echo
echo "Native openNDS logout remains only as a fallback."
