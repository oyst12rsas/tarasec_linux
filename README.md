# TaraSec Linux Hotspot

Generic TaraSec hotspot installer for **Raspberry Pi OS, Debian and Ubuntu** systems using a Wi-Fi interface for guests and another interface for upstream Internet.

This is the Linux/computer hotspot implementation. It is separate from `taraSec_openWRT`.

## What it installs/configures

- hostapd with an open `TaraSec` SSID
- a dedicated TaraSec dnsmasq DHCP/DNS service
- hotspot gateway address `192.168.50.1/24` by default
- DHCP option 114 (`http://status.client`) for captive-portal discovery
- forwarding/NAT to the detected upstream interface
- openNDS on the hotspot Wi-Fi interface
- the TaraSec ThemeSpec captive portal
- a compatibility patch so openNDS restarts the **dedicated TaraSec dnsmasq service**, not the distribution-wide `dnsmasq.service`
- a one-minute local health snapshot at `/run/tarasec-hotspot-health.json`

The installer intentionally disables the generic `dnsmasq.service` because TaraSec runs its own isolated instance. This avoids the port-53 conflict found during Raspberry Pi testing.

## Install

```bash
sudo bash install-hotspot.sh
```

The installer defaults to `wlan0` if present and otherwise selects the first Wi-Fi interface. It derives the upstream interface from the default route.

For a typical Raspberry Pi with Wi-Fi hotspot on `wlan0` and Ethernet upstream on `eth0`:

```bash
sudo TARASEC_HOTSPOT_IFACE=wlan0 \
     TARASEC_WAN_IFACE=eth0 \
     bash install-hotspot.sh
```

For an Ubuntu computer whose interfaces are named differently:

```bash
sudo TARASEC_HOTSPOT_IFACE=wlp2s0 \
     TARASEC_WAN_IFACE=enp3s0 \
     TARASEC_COUNTRY=NO \
     bash install-hotspot.sh
```

Optional environment settings include `TARASEC_SSID`, `TARASEC_HOTSPOT_ADDR`, `TARASEC_DHCP_START`, `TARASEC_DHCP_END`, `TARASEC_COUNTRY`, and `TARASEC_CHANNEL`.

## Captive portal

The current test portal is a local openNDS ThemeSpec page. It provides a click-through authentication path. TaraSec access-table/payment decisions will replace the unconditional test grant as the central access system is integrated.

## Health

Every minute a systemd timer writes a JSON health snapshot:

```bash
cat /run/tarasec-hotspot-health.json
```

Example:

```json
{"status":"OK","ap_up":true,"dhcp_ok":true,"opennds_ok":true,"interface_ok":true,"upstream_ok":true,"portal_listener_ok":true,"wifi_associated":1,"opennds_clients":1}
```

If Wi-Fi stations are associated but openNDS reports no clients, the local state becomes `DEGRADED`. This is intended to feed TaraSec's central per-minute hotspot status reporting later.

## Current status

The service layout and captive-portal discovery path have been exercised on the Raspberry Pi test hotspot. Generic Ubuntu support uses the same systemd/hostapd/dnsmasq/openNDS architecture but should still be validated on each Wi-Fi chipset/driver before relying on it for production access.
