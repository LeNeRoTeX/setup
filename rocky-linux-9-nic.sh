#!/usr/bin/env bash
set -e

echo "=== Detecting primary network interface ==="

PRIMARY_IF=$(ip route | awk '/default/ {print $5; exit}')
if [[ -z "$PRIMARY_IF" ]]; then
    echo "ERROR: Could not detect primary interface. Aborting."
    exit 1
fi

echo "Primary detected NIC: $PRIMARY_IF"

MAC=$(cat /sys/class/net/$PRIMARY_IF/address)
echo "MAC address: $MAC"

echo "=== Ensuring systemd network directory exists ==="
mkdir -p /etc/systemd/network

echo "=== Creating systemd .link override ==="
LINK_FILE="/etc/systemd/network/10-eth0.link"

cat > "$LINK_FILE" <<EOF
[Match]
MACAddress=$MAC

[Link]
Name=eth0
EOF

echo "Created $LINK_FILE"

echo "=== Updating NetworkManager connection profiles ==="

# FIXED AWK VARIABLE NAME
CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v DEV="$PRIMARY_IF" '$2==DEV {print $1}')

if [[ -z "$CON_NAME" ]]; then
    echo "WARNING: No matching NetworkManager connection found for $PRIMARY_IF"
    echo "Available profiles:"
    nmcli connection show
    echo
    echo "You may need to modify the correct profile manually."
else
    echo "NetworkManager connection found: $CON_NAME"

    echo " - Setting interface-name to eth0"
    nmcli con mod "$CON_NAME" connection.interface-name eth0

    echo " - Renaming profile to 'eth0'"
    nmcli con mod "$CON_NAME" connection.id eth0 || true
fi

echo "=== Rebuilding initramfs ==="
dracut -f

echo "=== Restarting NetworkManager ==="
systemctl restart NetworkManager || true

echo
echo "===================================================="
echo " NIC renaming is configured!"
echo " After reboot, your interface will be: eth0"
echo "===================================================="
echo

read -p "Reboot now? (y/n): " ANSWER
if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
    reboot
else
    echo "Please reboot manually when ready."
fi
