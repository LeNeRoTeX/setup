#!/usr/bin/env bash
set -e

echo "=== Safe NIC rename preparation for Rocky Linux 9 (Hetzner) ==="

# Detect active interface
PRIMARY_IF=$(ip route get 1.1.1.1 | awk '/dev/ {print $5; exit}')
if [[ -z "$PRIMARY_IF" ]]; then
    echo "ERROR: Could not detect active NIC."
    exit 1
fi

MAC=$(cat /sys/class/net/$PRIMARY_IF/address)

echo "Active NIC  : $PRIMARY_IF"
echo "MAC Address : $MAC"
echo

# Create systemd .link file safely
mkdir -p /etc/systemd/network

cat > /etc/systemd/network/10-eth0.link <<EOF
[Match]
MACAddress=$MAC

[Link]
Name=eth0
EOF

echo "Created /etc/systemd/network/10-eth0.link"
echo

# Create new NetworkManager profile for eth0 WITHOUT touching the active one
echo "Creating NetworkManager eth0 profile (safe, non-destructive)..."
nmcli con add type ethernet ifname eth0 con-name eth0 autoconnect yes || true
echo "NM profile created."
echo

# DO NOT DOWN NM
# DO NOT RESTART NM
# DO NOT MODIFY ACTIVE CONNECTION

# Rebuild initramfs so rename applies at next boot
echo "Rebuilding initramfs..."
dracut -f
echo

echo "=== SAFE STAGE COMPLETE ==="
echo "Your current SSH session is untouched."
echo "Reboot the machine when ready to apply the eth0 rename."
echo "Run manually: sudo reboot"
