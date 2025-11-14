#!/usr/bin/env bash
set -e

echo "=== Preparing safe NIC rename for Rocky Linux 9 ==="

# Detect active interface
PRIMARY_IF=$(ip route get 8.8.8.8 | awk '/dev/ {print $5; exit}')
MAC=$(cat /sys/class/net/$PRIMARY_IF/address)

echo "Detected active NIC: $PRIMARY_IF"
echo "MAC: $MAC"

echo "Creating systemd .link file..."
mkdir -p /etc/systemd/network

cat > /etc/systemd/network/10-eth0.link <<EOF
[Match]
MACAddress=$MAC

[Link]
Name=eth0
EOF

echo "Creating NEW NetworkManager profile for eth0 (does NOT touch current one)..."

# Create a new profile for eth0 but don't activate it
nmcli con add type ethernet ifname eth0 con-name eth0 autoconnect yes || true

echo "Rebuilding initramfs (safe)..."
dracut -f

echo "=== SAFE STAGE COMPLETE ==="
echo "Your current SSH session is untouched."
echo
echo "After REBOOT, the system will:"
echo "  ✔ Rename NIC to eth0"
echo "  ✔ Auto-connect using the new eth0 profile"
echo
echo "You can reboot when ready."
echo
echo "Run: sudo reboot"
