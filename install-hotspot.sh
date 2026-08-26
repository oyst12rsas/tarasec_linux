#!/bin/bash
set -euo pipefail

# TaraSec Linux hotspot installer
# Tested design target: Raspberry Pi OS / Debian / Ubuntu with systemd.
# Existing LAN/WAN interfaces are preserved; the selected Wi-Fi interface is
# dedicated to the TaraSec AP.

SSID="${TARASEC_SSID:-TaraSec}"
HOTSPOT_IFACE="${TARASEC_HOTSPOT_IFACE:-}"
WAN_IFACE="${TARASEC_WAN_IFACE:-}"
HOTSPOT_ADDR="${TARASEC_HOTSPOT_ADDR:-192.168.50.1}"
HOTSPOT_CIDR="${TARASEC_HOTSPOT_CIDR:-24}"
DHCP_START="${TARASEC_DHCP_START:-192.168.50.50}"
DHCP_END="${TARASEC_DHCP_END:-192.168.50.200}"
COUNTRY="${TARASEC_COUNTRY:-NO}"
CHANNEL="${TARASEC_CHANNEL:-6}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
THEME_SRC="$REPO_DIR/theme_tarasec.sh"

log(){ echo "[TaraSec] $*"; }
die(){ echo "[TaraSec ERROR] $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash install-hotspot.sh"
command -v systemctl >/dev/null || die "systemd is required"

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y hostapd dnsmasq iptables iw curl ca-certificates
}

find_hotspot_iface() {
  [ -n "$HOTSPOT_IFACE" ] && return
  if ip link show wlan0 >/dev/null 2>&1; then HOTSPOT_IFACE=wlan0; return; fi
  HOTSPOT_IFACE="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')"
  [ -n "$HOTSPOT_IFACE" ] || die "No Wi-Fi interface found. Set TARASEC_HOTSPOT_IFACE=wlanX"
}

find_wan_iface() {
  [ -n "$WAN_IFACE" ] && return
  WAN_IFACE="$(ip route show default | awk -v h="$HOTSPOT_IFACE" '$0 ~ / dev / {for(i=1;i<=NF;i++) if($i=="dev" && $(i+1)!=h){print $(i+1); exit}}')"
  [ -n "$WAN_IFACE" ] || die "No upstream interface found. Set TARASEC_WAN_IFACE=eth0"
}

install_opennds_if_needed() {
  if command -v opennds >/dev/null 2>&1; then return; fi
  log "openNDS is not installed; trying distribution package..."
  if apt-get install -y opennds; then return; fi
  die "openNDS package was not available. Install openNDS 10.x or newer, then rerun this installer."
}

configure_interface() {
  install -d -m 0755 /etc/tarasec
  cat >/usr/local/sbin/tarasec-hotspot-interface <<EOF
#!/bin/bash
set -e
ip link set "$HOTSPOT_IFACE" down || true
ip addr flush dev "$HOTSPOT_IFACE" || true
ip addr add "$HOTSPOT_ADDR/$HOTSPOT_CIDR" dev "$HOTSPOT_IFACE"
ip link set "$HOTSPOT_IFACE" up
EOF
  chmod 755 /usr/local/sbin/tarasec-hotspot-interface

  cat >/etc/systemd/system/tarasec-hotspot-interface.service <<EOF
[Unit]
Description=TaraSec hotspot interface
After=network.target
Before=hostapd.service tarasec-hotspot-dnsmasq.service opennds.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tarasec-hotspot-interface
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
}

configure_networkmanager() {
  if command -v nmcli >/dev/null 2>&1; then
    install -d /etc/NetworkManager/conf.d
    cat >/etc/NetworkManager/conf.d/90-tarasec-hotspot.conf <<EOF
[keyfile]
unmanaged-devices=interface-name:$HOTSPOT_IFACE
EOF
    nmcli dev set "$HOTSPOT_IFACE" managed no 2>/dev/null || true
  fi
}

configure_hostapd() {
  cat >/etc/hostapd/hostapd.conf <<EOF
interface=$HOTSPOT_IFACE
driver=nl80211
ssid=$SSID
country_code=$COUNTRY
hw_mode=g
channel=$CHANNEL
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=0
EOF
  if [ -f /etc/default/hostapd ]; then
    sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
  fi
  systemctl unmask hostapd 2>/dev/null || true
  systemctl enable hostapd
}

configure_dnsmasq() {
  # Use one dedicated dnsmasq instance. The generic distro service must not
  # compete for 192.168.50.1:53.
  systemctl disable --now dnsmasq.service 2>/dev/null || true
  cat >/etc/tarasec/dnsmasq-hotspot.conf <<EOF
interface=$HOTSPOT_IFACE
bind-interfaces
listen-address=$HOTSPOT_ADDR
dhcp-range=$DHCP_START,$DHCP_END,255.255.255.0,12h
dhcp-option=3,$HOTSPOT_ADDR
dhcp-option=6,$HOTSPOT_ADDR
dhcp-authoritative
server=1.1.1.1
server=8.8.8.8
dhcp-option-force=114,http://status.client
EOF
  cat >/etc/systemd/system/tarasec-hotspot-dnsmasq.service <<EOF
[Unit]
Description=TaraSec hotspot DHCP/DNS
After=tarasec-hotspot-interface.service
Requires=tarasec-hotspot-interface.service
Before=hostapd.service opennds.service
[Service]
Type=simple
ExecStart=/usr/sbin/dnsmasq --keep-in-foreground --conf-file=/etc/tarasec/dnsmasq-hotspot.conf --pid-file=/run/tarasec-hotspot-dnsmasq.pid
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
  systemctl enable tarasec-hotspot-dnsmasq.service
}

configure_firewall() {
  cat >/usr/local/sbin/tarasec-hotspot-firewall <<EOF
#!/bin/bash
set -e
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -N TARASEC-HOTSPOT-FWD 2>/dev/null || true
iptables -F TARASEC-HOTSPOT-FWD
iptables -C FORWARD -j TARASEC-HOTSPOT-FWD 2>/dev/null || iptables -I FORWARD 1 -j TARASEC-HOTSPOT-FWD
iptables -A TARASEC-HOTSPOT-FWD -i "$HOTSPOT_IFACE" -o "$WAN_IFACE" -s ${HOTSPOT_ADDR%.*}.0/24 -j ACCEPT
iptables -A TARASEC-HOTSPOT-FWD -i "$WAN_IFACE" -o "$HOTSPOT_IFACE" -d ${HOTSPOT_ADDR%.*}.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -N TARASEC-HOTSPOT-NAT 2>/dev/null || true
iptables -t nat -F TARASEC-HOTSPOT-NAT
iptables -t nat -C POSTROUTING -j TARASEC-HOTSPOT-NAT 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j TARASEC-HOTSPOT-NAT
iptables -t nat -A TARASEC-HOTSPOT-NAT -s ${HOTSPOT_ADDR%.*}.0/24 -o "$WAN_IFACE" -j MASQUERADE
iptables -t nat -A TARASEC-HOTSPOT-NAT -j RETURN
iptables -C INPUT -i "$HOTSPOT_IFACE" -p tcp --dport 2050 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "$HOTSPOT_IFACE" -p tcp --dport 2050 -j ACCEPT
iptables -C INPUT -i "$HOTSPOT_IFACE" -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "$HOTSPOT_IFACE" -p tcp --dport 53 -j ACCEPT
iptables -C INPUT -i "$HOTSPOT_IFACE" -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "$HOTSPOT_IFACE" -p udp --dport 53 -j ACCEPT
iptables -C INPUT -i "$HOTSPOT_IFACE" -p udp --dport 67 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "$HOTSPOT_IFACE" -p udp --dport 67 -j ACCEPT
EOF
  chmod 755 /usr/local/sbin/tarasec-hotspot-firewall
  cat >/etc/systemd/system/tarasec-hotspot-firewall.service <<EOF
[Unit]
Description=TaraSec hotspot firewall
After=tarasec-hotspot-interface.service
Requires=tarasec-hotspot-interface.service
Before=opennds.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tarasec-hotspot-firewall
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl enable tarasec-hotspot-firewall.service
}

configure_opennds() {
  install -m 0755 "$THEME_SRC" /usr/lib/opennds/theme_tarasec.sh

  # Support the UCI-style config used on cigar and the legacy generic-Linux
  # config used by some Ubuntu/openNDS installations.
  if command -v uci >/dev/null 2>&1 && [ -f /etc/config/opennds ]; then
    uci -q set opennds.@opennds[0].gatewayinterface="$HOTSPOT_IFACE" || true
    uci -q set opennds.@opennds[0].gatewayname='TaraSec' || true
    uci -q set opennds.@opennds[0].login_option_enabled='3' || true
    uci -q set opennds.@opennds[0].themespec_path='/usr/lib/opennds/theme_tarasec.sh' || true
    uci -q set opennds.@opennds[0].allow_preemptive_authentication='1' || true
    uci -q commit opennds || true
  fi

  if [ -f /etc/opennds/opennds.conf ]; then
    cp /etc/opennds/opennds.conf /etc/opennds/opennds.conf.tarasec-backup 2>/dev/null || true
    sed -i '/^GatewayInterface /d;/^login_option_enabled /d;/^ThemeSpecPath /d' /etc/opennds/opennds.conf
    cat >>/etc/opennds/opennds.conf <<EOF
GatewayInterface $HOTSPOT_IFACE
login_option_enabled 3
ThemeSpecPath /usr/lib/opennds/theme_tarasec.sh
EOF
  fi

  # openNDS generic-Linux helper normally restarts dnsmasq.service. TaraSec
  # intentionally runs an isolated dnsmasq instance, so point the helper at it.
  if [ -f /usr/lib/opennds/dnsconfig.sh ]; then
    cp -n /usr/lib/opennds/dnsconfig.sh /usr/lib/opennds/dnsconfig.sh.tarasec-original || true
    sed -i 's#systemctl restart dnsmasq \&#systemctl --no-block restart tarasec-hotspot-dnsmasq.service >/dev/null 2>\&1#' /usr/lib/opennds/dnsconfig.sh
  fi

  systemctl enable opennds
}

install_health_check() {
  cat >/usr/local/sbin/tarasec-hotspot-health <<EOF
#!/bin/bash
set -u
bool(){ if eval "$1" >/dev/null 2>&1; then printf true; else printf false; fi; }
AP=\$(bool "systemctl is-active --quiet hostapd")
DHCP=\$(bool "systemctl is-active --quiet tarasec-hotspot-dnsmasq.service")
NDS=\$(bool "systemctl is-active --quiet opennds")
IFACE=\$(bool "ip -4 addr show dev $HOTSPOT_IFACE | grep -q '$HOTSPOT_ADDR/'")
UP=\$(bool "ip route get 1.1.1.1 | grep -q 'dev $WAN_IFACE'")
PORTAL=\$(bool "ss -lnt | grep -q ':2050 '")
WIFI_CLIENTS=\$(iw dev $HOTSPOT_IFACE station dump 2>/dev/null | grep -c '^Station ' || true)
NDS_CLIENTS=\$(ndsctl json 2>/dev/null | sed -n 's/.*\"client_list_length\":\"\([0-9]*\)\".*/\1/p' | head -1); NDS_CLIENTS=\${NDS_CLIENTS:-0}
STATE=OK
[ "$AP" = true ] && [ "$DHCP" = true ] && [ "$NDS" = true ] && [ "$IFACE" = true ] && [ "$UP" = true ] && [ "$PORTAL" = true ] || STATE=FAILED
[ "$STATE" = OK ] && [ "$WIFI_CLIENTS" -gt 0 ] && [ "$NDS_CLIENTS" -eq 0 ] && STATE=DEGRADED
printf '{"status":"%s","ap_up":%s,"dhcp_ok":%s,"opennds_ok":%s,"interface_ok":%s,"upstream_ok":%s,"portal_listener_ok":%s,"wifi_associated":%s,"opennds_clients":%s}\n' "$STATE" "$AP" "$DHCP" "$NDS" "$IFACE" "$UP" "$PORTAL" "$WIFI_CLIENTS" "$NDS_CLIENTS"
EOF
  chmod 755 /usr/local/sbin/tarasec-hotspot-health
  cat >/etc/systemd/system/tarasec-hotspot-health.service <<EOF
[Unit]
Description=TaraSec hotspot health snapshot
After=opennds.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/local/sbin/tarasec-hotspot-health > /run/tarasec-hotspot-health.json'
EOF
  cat >/etc/systemd/system/tarasec-hotspot-health.timer <<EOF
[Unit]
Description=Run TaraSec hotspot health check every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
  systemctl enable tarasec-hotspot-health.timer
}

main() {
  apt_install
  find_hotspot_iface
  find_wan_iface
  install_opennds_if_needed
  log "Hotspot interface: $HOTSPOT_IFACE; upstream: $WAN_IFACE"
  configure_networkmanager
  configure_interface
  configure_hostapd
  configure_dnsmasq
  configure_firewall
  configure_opennds
  install_health_check
  systemctl daemon-reload
  systemctl restart tarasec-hotspot-interface.service
  systemctl restart tarasec-hotspot-firewall.service
  systemctl restart tarasec-hotspot-dnsmasq.service
  systemctl restart hostapd.service
  systemctl restart opennds.service
  systemctl start tarasec-hotspot-health.timer
  sleep 3
  echo
  systemctl --no-pager --full status tarasec-hotspot-dnsmasq.service opennds.service | cat || true
  echo
  /usr/local/sbin/tarasec-hotspot-health || true
  echo
  log "Installation complete. SSID=$SSID gateway=$HOTSPOT_ADDR"
  log "Health: cat /run/tarasec-hotspot-health.json"
}

main "$@"
