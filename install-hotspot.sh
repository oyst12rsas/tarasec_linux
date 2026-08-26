#!/bin/bash
set -euo pipefail

# TaraSec Linux hotspot installer
# Targets Raspberry Pi OS / Debian / Ubuntu with systemd.
# Rule: interfaces currently carrying a default Internet route are preserved.
# Other usable physical interfaces become client-facing TaraSec interfaces.

SSID="${TARASEC_SSID:-TaraSec}"
BRIDGE="${TARASEC_BRIDGE:-br-tarasec}"
HOTSPOT_ADDR="${TARASEC_HOTSPOT_ADDR:-192.168.50.1}"
HOTSPOT_CIDR="${TARASEC_HOTSPOT_CIDR:-24}"
DHCP_START="${TARASEC_DHCP_START:-192.168.50.50}"
DHCP_END="${TARASEC_DHCP_END:-192.168.50.200}"
COUNTRY="${TARASEC_COUNTRY:-NO}"
CHANNEL="${TARASEC_CHANNEL:-6}"
UPSTREAM_OVERRIDE="${TARASEC_UPSTREAM_IFACES:-}"
CLIENT_OVERRIDE="${TARASEC_CLIENT_IFACES:-}"
ASSUME_YES="${TARASEC_ASSUME_YES:-0}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
THEME_SRC="$REPO_DIR/theme_tarasec.sh"
ACCESS_CHECK_SRC="$REPO_DIR/tarasec-access-check"
ACCESS_ENFORCE_SRC="$REPO_DIR/tarasec-access-enforce"
UPSTREAM_IFACES=()
CLIENT_IFACES=()
WIFI_CLIENT_IFACES=()
WIRED_CLIENT_IFACES=()
PLATFORM="Linux"

log(){ echo "[TaraSec] $*"; }
warn(){ echo "[TaraSec WARNING] $*" >&2; }
die(){ echo "[TaraSec ERROR] $*" >&2; exit 1; }
contains(){ local x="$1"; shift; local y; for y in "$@"; do [ "$x" = "$y" ] && return 0; done; return 1; }

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash install-hotspot.sh"
command -v systemctl >/dev/null || die "systemd is required"

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y hostapd dnsmasq iptables iw curl ca-certificates python3 default-mysql-client
}

detect_platform() {
  if grep -qi 'raspberry pi' /proc/device-tree/model 2>/dev/null; then
    PLATFORM="Raspberry Pi"
  elif [ -r /etc/os-release ]; then
    . /etc/os-release
    PLATFORM="${PRETTY_NAME:-${NAME:-Linux}}"
  fi
}

is_wireless() {
  [ -d "/sys/class/net/$1/wireless" ] || { command -v iw >/dev/null 2>&1 && iw dev "$1" info >/dev/null 2>&1; }
}

is_physical_iface() {
  [ -e "/sys/class/net/$1/device" ]
}

detect_upstreams() {
  local i
  if [ -n "$UPSTREAM_OVERRIDE" ]; then
    read -r -a UPSTREAM_IFACES <<<"$UPSTREAM_OVERRIDE"
  else
    while read -r i; do
      [ -n "$i" ] && ! contains "$i" "${UPSTREAM_IFACES[@]:-}" && UPSTREAM_IFACES+=("$i")
    done < <(ip -o route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1)}}')
  fi
  [ "${#UPSTREAM_IFACES[@]}" -gt 0 ] || die "No active default-route interface found. Connect this machine to the Internet first."
  for i in "${UPSTREAM_IFACES[@]}"; do
    ip link show "$i" >/dev/null 2>&1 || die "Configured upstream interface '$i' does not exist"
  done
}

detect_clients() {
  local p i
  if [ -n "$CLIENT_OVERRIDE" ]; then
    read -r -a CLIENT_IFACES <<<"$CLIENT_OVERRIDE"
  else
    for p in /sys/class/net/*; do
      i="${p##*/}"
      [ "$i" = lo ] && continue
      [ "$i" = "$BRIDGE" ] && continue
      contains "$i" "${UPSTREAM_IFACES[@]}" && continue
      is_physical_iface "$i" || continue
      CLIENT_IFACES+=("$i")
    done
  fi
  [ "${#CLIENT_IFACES[@]}" -gt 0 ] || die "No spare physical interface found for hotspot clients. Add another Ethernet/Wi-Fi adapter or set TARASEC_CLIENT_IFACES explicitly."
  for i in "${CLIENT_IFACES[@]}"; do
    contains "$i" "${UPSTREAM_IFACES[@]}" && die "Refusing to repurpose active Internet interface '$i' as a client interface"
    ip link show "$i" >/dev/null 2>&1 || die "Client interface '$i' does not exist"
    if is_wireless "$i"; then WIFI_CLIENT_IFACES+=("$i"); else WIRED_CLIENT_IFACES+=("$i"); fi
  done
}

show_topology_and_confirm() {
  local i kind state answer
  echo
  echo "============================================================"
  echo " TaraSec hotspot proposed setup"
  echo "============================================================"
  echo "Platform:              $PLATFORM"
  echo "Internet/upstream:     ${UPSTREAM_IFACES[*]}"
  echo "Client-facing:         ${CLIENT_IFACES[*]}"
  echo "TaraSec bridge:        $BRIDGE ($HOTSPOT_ADDR/$HOTSPOT_CIDR)"
  echo "Wi-Fi AP interface(s): ${WIFI_CLIENT_IFACES[*]:-(none)}"
  echo "Wired client port(s):  ${WIRED_CLIENT_IFACES[*]:-(none)}"
  echo "Wi-Fi SSID:            $SSID"
  echo
  echo "Detected physical interfaces:"
  for i in "${UPSTREAM_IFACES[@]}" "${CLIENT_IFACES[@]}"; do
    if is_wireless "$i"; then kind="Wi-Fi"; else kind="Ethernet/other"; fi
    state="$(cat "/sys/class/net/$i/operstate" 2>/dev/null || echo unknown)"
    if contains "$i" "${UPSTREAM_IFACES[@]}"; then
      printf '  %-16s %-15s %-10s %s\n' "$i" "$kind" "$state" "KEEP AS INTERNET"
    else
      printf '  %-16s %-15s %-10s %s\n' "$i" "$kind" "$state" "USE FOR CLIENTS"
    fi
  done
  echo
  echo "TaraSec will NOT reconfigure the interface(s) currently carrying"
  echo "the default Internet route. Client-facing interfaces WILL be"
  echo "reconfigured and attached to the TaraSec client bridge."
  echo
  echo "You can change this later. For example, after adding a USB Ethernet"
  echo "or Wi-Fi adapter, rerun this installer and confirm the newly detected"
  echo "topology. For an unusual layout, set TARASEC_UPSTREAM_IFACES and/or"
  echo "TARASEC_CLIENT_IFACES before rerunning."
  echo "============================================================"
  echo
  if [ "$ASSUME_YES" = "1" ]; then
    log "TARASEC_ASSUME_YES=1: accepting proposed topology."
    return
  fi
  [ -t 0 ] || die "Interactive confirmation required. Run from a terminal, or use TARASEC_ASSUME_YES=1 after reviewing the topology."
  read -r -p "Use this setup and continue installation? [y/N] " answer
  case "$answer" in y|Y|yes|YES|Yes) ;; *) echo "Installation cancelled. No TaraSec network changes were made."; exit 0 ;; esac
}

install_opennds_if_needed() {
  command -v opennds >/dev/null 2>&1 && return
  log "openNDS is not installed; trying distribution package..."
  apt-get install -y opennds && return
  die "openNDS package was not available. Install openNDS 10.x or newer, then rerun this installer."
}

save_topology() {
  install -d -m 0755 /etc/tarasec
  {
    printf 'TARASEC_BRIDGE=%q\n' "$BRIDGE"
    printf 'TARASEC_HOTSPOT_ADDR=%q\n' "$HOTSPOT_ADDR"
    printf 'TARASEC_UPSTREAM_IFACES=%q\n' "${UPSTREAM_IFACES[*]}"
    printf 'TARASEC_CLIENT_IFACES=%q\n' "${CLIENT_IFACES[*]}"
    printf 'TARASEC_WIFI_CLIENT_IFACES=%q\n' "${WIFI_CLIENT_IFACES[*]}"
    printf 'TARASEC_WIRED_CLIENT_IFACES=%q\n' "${WIRED_CLIENT_IFACES[*]}"
  } >/etc/tarasec/hotspot.env
}

configure_networkmanager() {
  command -v nmcli >/dev/null 2>&1 || return
  install -d /etc/NetworkManager/conf.d
  {
    echo '[keyfile]'
    printf 'unmanaged-devices=interface-name:%s' "$BRIDGE"
    local i
    for i in "${CLIENT_IFACES[@]}"; do printf ';interface-name:%s' "$i"; done
    echo
  } >/etc/NetworkManager/conf.d/90-tarasec-hotspot.conf
  local i
  for i in "${CLIENT_IFACES[@]}"; do nmcli dev set "$i" managed no 2>/dev/null || true; done
}

configure_interface() {
  local wired_q="" i
  for i in "${WIRED_CLIENT_IFACES[@]}"; do wired_q+=" $(printf '%q' "$i")"; done
  cat >/usr/local/sbin/tarasec-hotspot-interface <<EOF
#!/bin/bash
set -e
BRIDGE=$(printf '%q' "$BRIDGE")
HOTSPOT_ADDR=$(printf '%q' "$HOTSPOT_ADDR")
HOTSPOT_CIDR=$(printf '%q' "$HOTSPOT_CIDR")
ip link show "\$BRIDGE" >/dev/null 2>&1 || ip link add name "\$BRIDGE" type bridge
ip link set "\$BRIDGE" up
ip addr flush dev "\$BRIDGE" || true
ip addr add "\$HOTSPOT_ADDR/\$HOTSPOT_CIDR" dev "\$BRIDGE"
for iface in$wired_q; do
  ip link set "\$iface" down || true
  ip addr flush dev "\$iface" || true
  ip link set "\$iface" master "\$BRIDGE"
  ip link set "\$iface" up
done
EOF
  chmod 755 /usr/local/sbin/tarasec-hotspot-interface
  cat >/etc/systemd/system/tarasec-hotspot-interface.service <<EOF
[Unit]
Description=TaraSec client bridge
After=network.target
Before=tarasec-hotspot-dnsmasq.service tarasec-hotspot-hostapd.service opennds.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tarasec-hotspot-interface
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
  systemctl enable tarasec-hotspot-interface.service
}

configure_hostapd() {
  local i
  systemctl disable --now hostapd.service 2>/dev/null || true
  rm -rf /etc/tarasec/hostapd
  mkdir -p /etc/tarasec/hostapd
  if [ "${#WIFI_CLIENT_IFACES[@]}" -eq 0 ]; then
    rm -f /etc/systemd/system/tarasec-hotspot-hostapd.service
    log "No spare Wi-Fi interface: clients will connect through wired interface(s)/external APs."
    return
  fi
  for i in "${WIFI_CLIENT_IFACES[@]}"; do
    cat >"/etc/tarasec/hostapd/$i.conf" <<EOF
interface=$i
bridge=$BRIDGE
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
  done
  cat >/usr/local/sbin/tarasec-hotspot-hostapd <<'EOF'
#!/bin/bash
set -e
shopt -s nullglob
configs=(/etc/tarasec/hostapd/*.conf)
[ "${#configs[@]}" -gt 0 ] || exit 0
exec /usr/sbin/hostapd "${configs[@]}"
EOF
  chmod 755 /usr/local/sbin/tarasec-hotspot-hostapd
  cat >/etc/systemd/system/tarasec-hotspot-hostapd.service <<EOF
[Unit]
Description=TaraSec Wi-Fi access point(s)
After=tarasec-hotspot-interface.service
Requires=tarasec-hotspot-interface.service
Before=opennds.service
[Service]
Type=simple
ExecStart=/usr/local/sbin/tarasec-hotspot-hostapd
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
  systemctl enable tarasec-hotspot-hostapd.service
}

configure_dnsmasq() {
  systemctl disable --now dnsmasq.service 2>/dev/null || true
  cat >/etc/tarasec/dnsmasq-hotspot.conf <<EOF
interface=$BRIDGE
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
Before=opennds.service
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
  local upstream_q="" i
  for i in "${UPSTREAM_IFACES[@]}"; do upstream_q+=" $(printf '%q' "$i")"; done
  cat >/usr/local/sbin/tarasec-hotspot-firewall <<EOF
#!/bin/bash
set -e
BRIDGE=$(printf '%q' "$BRIDGE")
SUBNET=$(printf '%q' "${HOTSPOT_ADDR%.*}.0/24")
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -N TARASEC-HOTSPOT-FWD 2>/dev/null || true
iptables -F TARASEC-HOTSPOT-FWD
iptables -C FORWARD -j TARASEC-HOTSPOT-FWD 2>/dev/null || iptables -I FORWARD 1 -j TARASEC-HOTSPOT-FWD
for upstream in$upstream_q; do
  iptables -A TARASEC-HOTSPOT-FWD -i "\$BRIDGE" -o "\$upstream" -s "\$SUBNET" -j ACCEPT
  iptables -A TARASEC-HOTSPOT-FWD -i "\$upstream" -o "\$BRIDGE" -d "\$SUBNET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
done
iptables -N TARASEC-HOTSPOT-NAT 2>/dev/null || true
iptables -t nat -F TARASEC-HOTSPOT-NAT
iptables -t nat -C POSTROUTING -j TARASEC-HOTSPOT-NAT 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j TARASEC-HOTSPOT-NAT
for upstream in$upstream_q; do iptables -t nat -A TARASEC-HOTSPOT-NAT -s "\$SUBNET" -o "\$upstream" -j MASQUERADE; done
iptables -t nat -A TARASEC-HOTSPOT-NAT -j RETURN
iptables -C INPUT -i "\$BRIDGE" -p tcp --dport 2050 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "\$BRIDGE" -p tcp --dport 2050 -j ACCEPT
iptables -C INPUT -i "\$BRIDGE" -p tcp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "\$BRIDGE" -p tcp --dport 53 -j ACCEPT
iptables -C INPUT -i "\$BRIDGE" -p udp --dport 53 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "\$BRIDGE" -p udp --dport 53 -j ACCEPT
iptables -C INPUT -i "\$BRIDGE" -p udp --dport 67 -j ACCEPT 2>/dev/null || iptables -I INPUT -i "\$BRIDGE" -p udp --dport 67 -j ACCEPT
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
  if command -v uci >/dev/null 2>&1 && [ -f /etc/config/opennds ]; then
    uci -q set opennds.@opennds[0].gatewayinterface="$BRIDGE" || true
    uci -q set opennds.@opennds[0].gatewayname='TaraSec' || true
    uci -q set opennds.@opennds[0].login_option_enabled='3' || true
    uci -q set opennds.@opennds[0].themespec_path='/usr/lib/opennds/theme_tarasec.sh' || true
    uci -q set opennds.@opennds[0].allow_preemptive_authentication='1' || true
    uci -q commit opennds || true
  fi
  if [ -f /etc/opennds/opennds.conf ]; then
    cp -n /etc/opennds/opennds.conf /etc/opennds/opennds.conf.tarasec-original || true
    sed -i '/^GatewayInterface /d;/^login_option_enabled /d;/^ThemeSpecPath /d' /etc/opennds/opennds.conf
    cat >>/etc/opennds/opennds.conf <<EOF
GatewayInterface $BRIDGE
login_option_enabled 3
ThemeSpecPath /usr/lib/opennds/theme_tarasec.sh
EOF
  fi
  if [ -f /usr/lib/opennds/dnsconfig.sh ]; then
    cp -n /usr/lib/opennds/dnsconfig.sh /usr/lib/opennds/dnsconfig.sh.tarasec-original || true
    sed -i 's#systemctl restart dnsmasq \&#systemctl --no-block restart tarasec-hotspot-dnsmasq.service >/dev/null 2>\&1#' /usr/lib/opennds/dnsconfig.sh
  fi
  systemctl enable opennds
}

install_access_control() {
  [ -f "$ACCESS_CHECK_SRC" ] || die "Missing $ACCESS_CHECK_SRC"
  [ -f "$ACCESS_ENFORCE_SRC" ] || die "Missing $ACCESS_ENFORCE_SRC"
  install -m 0755 "$ACCESS_CHECK_SRC" /usr/local/sbin/tarasec-access-check
  install -m 0755 "$ACCESS_ENFORCE_SRC" /usr/local/sbin/tarasec-access-enforce

  # Older pilot installs used a separate access timer. The normal installer
  # now runs enforcement inside the existing one-minute health loop.
  systemctl disable --now tarasec-access-enforce.timer 2>/dev/null || true
  rm -f /etc/systemd/system/tarasec-access-enforce.timer
  rm -f /etc/systemd/system/tarasec-access-enforce.service
}

install_health_check() {
  cat >/usr/local/sbin/tarasec-hotspot-health <<'EOF'
#!/bin/bash
set -u
. /etc/tarasec/hotspot.env
bool(){ if eval "$1" >/dev/null 2>&1; then printf true; else printf false; fi; }

# Access enforcement is part of the same per-minute health cycle.
ACCESS_OK=false
ACCESS_CHECKED=0
ACCESS_REVOKED=0
ACCESS_ERRORS=1
if /usr/local/sbin/tarasec-access-enforce >/dev/null 2>&1; then ACCESS_OK=true; fi
if [ -r /run/tarasec-access-enforcement.json ]; then
  ACCESS_CHECKED=$(sed -n 's/.*"checked":\([0-9]*\).*/\1/p' /run/tarasec-access-enforcement.json | head -1); ACCESS_CHECKED=${ACCESS_CHECKED:-0}
  ACCESS_REVOKED=$(sed -n 's/.*"revoked":\([0-9]*\).*/\1/p' /run/tarasec-access-enforcement.json | head -1); ACCESS_REVOKED=${ACCESS_REVOKED:-0}
  ACCESS_ERRORS=$(sed -n 's/.*"errors":\([0-9]*\).*/\1/p' /run/tarasec-access-enforcement.json | head -1); ACCESS_ERRORS=${ACCESS_ERRORS:-1}
fi

DHCP=$(bool "systemctl is-active --quiet tarasec-hotspot-dnsmasq.service")
NDS=$(bool "systemctl is-active --quiet opennds")
IFACE=$(bool "ip -4 addr show dev $TARASEC_BRIDGE | grep -q '$TARASEC_HOTSPOT_ADDR/'")
PORTAL=$(bool "ss -lnt | grep -q ':2050 '")
UP=true
for u in $TARASEC_UPSTREAM_IFACES; do ip route show default dev "$u" | grep -q . || UP=false; done
if [ -n "$TARASEC_WIFI_CLIENT_IFACES" ]; then AP=$(bool "systemctl is-active --quiet tarasec-hotspot-hostapd.service"); else AP=true; fi
WIFI_CLIENTS=0
for w in $TARASEC_WIFI_CLIENT_IFACES; do n=$(iw dev "$w" station dump 2>/dev/null | grep -c '^Station ' || true); WIFI_CLIENTS=$((WIFI_CLIENTS+n)); done
NDS_CLIENTS=$(ndsctl json 2>/dev/null | sed -n 's/.*"client_list_length":"\([0-9]*\)".*/\1/p' | head -1); NDS_CLIENTS=${NDS_CLIENTS:-0}
STATE=OK
[ "$AP" = true ] && [ "$DHCP" = true ] && [ "$NDS" = true ] && [ "$IFACE" = true ] && [ "$UP" = true ] && [ "$PORTAL" = true ] && [ "$ACCESS_ERRORS" -eq 0 ] || STATE=FAILED
[ "$STATE" = OK ] && [ "$WIFI_CLIENTS" -gt 0 ] && [ "$NDS_CLIENTS" -eq 0 ] && STATE=DEGRADED
printf '{"status":"%s","ap_up":%s,"dhcp_ok":%s,"opennds_ok":%s,"interface_ok":%s,"upstream_ok":%s,"portal_listener_ok":%s,"wifi_associated":%s,"opennds_clients":%s,"access_ok":%s,"access_checked":%s,"access_revoked":%s,"access_errors":%s,"upstreams":"%s","clients":"%s"}\n' "$STATE" "$AP" "$DHCP" "$NDS" "$IFACE" "$UP" "$PORTAL" "$WIFI_CLIENTS" "$NDS_CLIENTS" "$ACCESS_OK" "$ACCESS_CHECKED" "$ACCESS_REVOKED" "$ACCESS_ERRORS" "$TARASEC_UPSTREAM_IFACES" "$TARASEC_CLIENT_IFACES"
EOF
  chmod 755 /usr/local/sbin/tarasec-hotspot-health
  cat >/etc/systemd/system/tarasec-hotspot-health.service <<EOF
[Unit]
Description=TaraSec hotspot health and access enforcement snapshot
After=opennds.service
[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/local/sbin/tarasec-hotspot-health > /run/tarasec-hotspot-health.json'
EOF
  cat >/etc/systemd/system/tarasec-hotspot-health.timer <<EOF
[Unit]
Description=Run TaraSec hotspot health/access check every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s
[Install]
WantedBy=timers.target
EOF
  systemctl enable tarasec-hotspot-health.timer
}

restart_opennds_clean() {
  systemctl stop opennds.service 2>/dev/null || true
  # openNDS can briefly report itself as running after systemd considers it stopped.
  # Give its helper/lock cleanup time to finish, then retry startup if necessary.
  local n
  for n in $(seq 1 20); do
    pgrep -x opennds >/dev/null 2>&1 || break
    sleep 0.5
  done
  for n in 1 2 3; do
    if systemctl start opennds.service; then return 0; fi
    sleep 5
  done
  return 1
}

main() {
  detect_platform
  detect_upstreams
  detect_clients
  show_topology_and_confirm

  # Nothing above this point intentionally changes network configuration.
  apt_install
  install_opennds_if_needed
  log "Preserving Internet interface(s): ${UPSTREAM_IFACES[*]}"
  log "Using client interface(s): ${CLIENT_IFACES[*]}"
  [ "${#WIFI_CLIENT_IFACES[@]}" -gt 0 ] && log "Wi-Fi AP interface(s): ${WIFI_CLIENT_IFACES[*]}"
  [ "${#WIRED_CLIENT_IFACES[@]}" -gt 0 ] && log "Wired client interface(s): ${WIRED_CLIENT_IFACES[*]}"
  save_topology
  configure_networkmanager
  configure_interface
  configure_hostapd
  configure_dnsmasq
  configure_firewall
  configure_opennds
  install_access_control
  install_health_check
  systemctl daemon-reload
  systemctl restart tarasec-hotspot-interface.service
  systemctl restart tarasec-hotspot-firewall.service
  systemctl restart tarasec-hotspot-dnsmasq.service
  if [ "${#WIFI_CLIENT_IFACES[@]}" -gt 0 ]; then systemctl restart tarasec-hotspot-hostapd.service; fi
  restart_opennds_clean
  systemctl restart tarasec-hotspot-health.timer
  sleep 3
  /usr/local/sbin/tarasec-hotspot-health || true
  echo
  log "Installation complete. Gateway=$HOTSPOT_ADDR bridge=$BRIDGE"
  log "Upstream preserved: ${UPSTREAM_IFACES[*]}"
  log "Client side: ${CLIENT_IFACES[*]}"
  log "Access enforcement: synchronized with TaraSec access table every minute"
  log "Health: cat /run/tarasec-hotspot-health.json"
}

main "$@"
