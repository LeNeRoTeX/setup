#!/usr/bin/env bash
set -euo pipefail

echo "=== SAFE NIC RENAME (Hetzner Rocky 9) ==="

# Detect active interface
PRIMARY_IF=$(ip route get 1.1.1.1 | awk '/dev/ {print $5; exit}')
if [[ -z "$PRIMARY_IF" ]]; then
    echo "ERROR: Could not detect active NIC."
    exit 1
fi

MAC=$(cat /sys/class/net/${PRIMARY_IF}/address)

# Detect network config of primary interface
IP_ADDR=$(ip -4 -o addr show dev "$PRIMARY_IF" | awk '{print $4}')
GATEWAY=$(ip route | awk '/default/ {print $3}')
DNS=$(grep -E '^nameserver' /etc/resolv.conf | head -n1 | awk '{print $2}')

if [[ -z "$IP_ADDR" || -z "$GATEWAY" ]]; then
    echo "ERROR: Could not detect full IP configuration."
    exit 1
fi

echo "Active NIC : $PRIMARY_IF"
echo "MAC        : $MAC"
echo "IP         : $IP_ADDR"
echo "Gateway    : $GATEWAY"
echo "DNS        : $DNS"
echo

mkdir -p /etc/systemd/network

# Systemd link file for rename
cat > /etc/systemd/network/10-eth0.link <<EOF
[Match]
MACAddress=$MAC

[Link]
Name=eth0
EOF

echo "Created NIC rename file: /etc/systemd/network/10-eth0.link"
echo

# Create *correct* NetworkManager profile for eth0
echo "Creating eth0 NetworkManager profile with current IP..."
nmcli con add type ethernet ifname eth0 con-name eth0 autoconnect yes \
    ip4 "$IP_ADDR" gw4 "$GATEWAY"

if [[ -n "$DNS" ]]; then
    nmcli con mod eth0 ipv4.dns "$DNS"
fi

# Make it manual (static IP)
nmcli con mod eth0 ipv4.method manual

echo "eth0 NetworkManager profile created:"
nmcli con show eth0
echo

# Rebuild initramfs with rename rule included
echo "Rebuilding initramfs..."
dracut -f
echo

echo "=== DONE ==="
echo "Reboot now to switch NIC from $PRIMARY_IF → eth0"
echo "Run: sudo reboot"
