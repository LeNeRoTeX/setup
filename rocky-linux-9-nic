#!/usr/bin/env bash
set -e

echo "=== Detecting primary network interface ==="

# Detect the main NIC (non-loopback, with default route)
PRIMARY_IF=$(ip route | awk '/default/ {print $5; exit}')
if [[ -z "$PRIMARY_IF" ]]; then
    echo "ERROR: Could not detect primary interface. Aborting."
    exit 1
fi

echo "Primary detected NIC: $PRIMARY_IF"

# Extract MAC address
MAC=$(cat /sys/class/net/$PRIMARY_IF/address)
echo "MAC address: $MAC"

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

# Find the NM connection that matches the current interface
CON_NAME=$(nmcli -t -f NAME,DEVICE connection show | awk -F: -v if="$PRIMARY_IF" '$2==if {print $1}')
if [[ -z "$CON_NAME" ]]; then
    echo "WARNING: No NetworkManager profile automatically matched. Showing available profiles:"
    nmcli connection show
    echo "You may need to edit manually."
else
    echo "NetworkManager connection found: $CON_NAME"

    # Set the interface name inside NM profile
    nmcli con mod "$CON_NAME" connection.interface-name eth0

    # Also rename the profile to eth0 if possible
    nmcli con mod "$CON_NAME" connection.id eth0 || true
fi

echo "=== Rebuilding initramfs ==="
dracut -f

echo "=== Enabling eth0 immediately (will rename after reboot) ==="

# Attempt graceful reload (not strictly required)
systemctl restart NetworkManager || true

echo "=== All done! ==="
echo "Your NIC will be renamed to eth0 after a reboot."
echo "Reboot now? (y/n)"
read -r ANSWER

if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
    reboot
else
    echo "Please reboot manually when ready."
fi
