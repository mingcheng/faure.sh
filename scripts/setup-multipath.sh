#!/bin/bash
#
# Setup multipath routing for load balancing between two interfaces
#

# Exit on error
set -e

# --- Configuration ---
IF1="eth0"
IF2="eth1"
LAN_NET="172.16.1.0/24"

# Gateway IPs (Adjust these if your gateways are different)
GW1="172.16.1.1"
GW2="192.168.66.1"

# Routing Table Names (Ensure these are defined in /etc/iproute2/rt_tables)
# Or use numeric IDs (e.g., 101, 102)
TABLE1="100"
TABLE2="101"

# --- Execution ---

echo "Configuring multipath routing..."

# Get IP addresses
# Using awk for better portability than grep -oP
IP1=$(ip -4 addr show $IF1 | awk '/inet / {print $2}' | cut -d/ -f1)
IP2=$(ip -4 addr show $IF2 | awk '/inet / {print $2}' | cut -d/ -f1)

if [ -z "$IP1" ]; then
    echo "Error: Could not detect IP address for $IF1"
    exit 1
fi

if [ -z "$IP2" ]; then
    echo "Error: Could not detect IP address for $IF2"
    exit 1
fi

echo "$IF1 IP: $IP1"
echo "$IF2 IP: $IP2"

# Detect Gateway for IF2 if possible (DHCP)
DETECTED_GW2=$(ip route show dev $IF2 | grep default | awk '{print $3}')
if [ -n "$DETECTED_GW2" ]; then
    GW2=$DETECTED_GW2
    echo "Detected GW2: $GW2"
fi

# Flush old routing table rules (preserve tproxy rules)
echo "Flushing old routing tables..."
ip route flush table $TABLE1 || true
ip route flush table $TABLE2 || true

# Configure Table 1 ($IF1)
echo "Configuring route table $TABLE1..."
ip route add 172.16.1.0/24 dev $IF1 src $IP1 table $TABLE1
ip route add 192.168.66.0/24 dev $IF2 table $TABLE1
ip route add default via $GW1 dev $IF1 table $TABLE1

# Configure Table 2 ($IF2)
echo "Configuring route table $TABLE2..."
ip route add 172.16.1.0/24 dev $IF1 table $TABLE2
ip route add 192.168.66.0/24 dev $IF2 src $IP2 table $TABLE2
ip route add default via $GW2 dev $IF2 table $TABLE2

# Cleanup old policy routing rules
# We use '|| true' to ignore errors if rules don't exist
echo "Cleaning up old policy rules..."
ip rule del from $IP1 table $TABLE1 priority 100 2>/dev/null || true
ip rule del from $IP2 table $TABLE2 priority 101 2>/dev/null || true
# Remove the rule that forced LAN traffic to Table 1 (preventing load balancing)
ip rule del from $LAN_NET table $TABLE1 priority 100 2>/dev/null || true
ip rule del from 192.168.66.0/24 table $TABLE2 priority 101 2>/dev/null || true

# Add new policy routing rules
# Priority 100-101 ensures they run after TProxy rules (usually priority 99)
echo "Adding new policy rules..."
ip rule add from $IP1 table $TABLE1 priority 100
# We DO NOT add a rule for LAN_NET here, to allow it to fall through to main table for load balancing.

ip rule add from $IP2 table $TABLE2 priority 101
ip rule add from 192.168.66.0/24 table $TABLE2 priority 101

# --- Docker/NAT Compatibility (Connection Marking) ---
# This ensures traffic entering via a specific interface leaves via the same interface.
# Crucial for Docker port mappings and other DNAT scenarios.

echo "Configuring connection marking for Docker/NAT compatibility..."

# Define marks (using hex for iptables)
MARK1="0x100"
MARK2="0x200"

# Create a chain for multipath marking if it doesn't exist
iptables -t mangle -N MULTIPATH_MARK 2>/dev/null || true
iptables -t mangle -F MULTIPATH_MARK

# 1. Restore connection mark to packet mark
iptables -t mangle -A MULTIPATH_MARK -j CONNMARK --restore-mark

# 2. Mark packets coming from WAN interfaces (if new connection)
# Exclude LAN traffic from being marked as "WAN incoming" on IF1
iptables -t mangle -A MULTIPATH_MARK -i $IF1 ! -s $LAN_NET -m conntrack --ctstate NEW -j MARK --set-mark $MARK1
iptables -t mangle -A MULTIPATH_MARK -i $IF2 -m conntrack --ctstate NEW -j MARK --set-mark $MARK2

# 3. Save packet mark to connection mark (if mark is set)
iptables -t mangle -A MULTIPATH_MARK -m mark ! --mark 0 -j CONNMARK --save-mark

# 4. If packet has a routing mark, stop processing (ACCEPT) to prevent TPROXY from overwriting it
#    This ensures return traffic bypasses TPROXY
iptables -t mangle -A MULTIPATH_MARK -m mark --mark $MARK1 -j ACCEPT
iptables -t mangle -A MULTIPATH_MARK -m mark --mark $MARK2 -j ACCEPT

# Ensure the jump rule exists in PREROUTING at the top
# Remove existing jump to avoid duplicates
iptables -t mangle -D PREROUTING -j MULTIPATH_MARK 2>/dev/null || true
# Insert at position 1 to run before TPROXY
iptables -t mangle -I PREROUTING 1 -j MULTIPATH_MARK

# Add ip rules for the marks (Priority 90/91, higher than TPROXY's 99)
echo "Adding fwmark rules..."
ip rule del fwmark $MARK1 table $TABLE1 2>/dev/null || true
ip rule del fwmark $MARK2 table $TABLE2 2>/dev/null || true

ip rule add fwmark $MARK1 table $TABLE1 priority 90
ip rule add fwmark $MARK2 table $TABLE2 priority 91

# Remove default route from main table
echo "Updating main routing table..."
ip route del default 2>/dev/null || true

# Ensure local network routes exist in main table
# Using 'replace' to ensure idempotency
ip route replace 172.17.0.0/16 dev docker0 || true
ip route replace 172.16.1.0/24 dev $IF1 src $IP1
ip route replace 192.168.66.0/24 dev $IF2 src $IP2

# Add multipath default route (Load Balancing)
# Weights are set to 1:1
echo "Adding multipath default route..."
ip route add default scope global \
    nexthop via $GW1 dev $IF1 weight 1 \
    nexthop via $GW2 dev $IF2 weight 1

# --- NAT / Masquerade ---
# Required for:
# 1. Traffic going out eth1 (GW2 likely doesn't know LAN route)
# 2. Traffic going out eth0 (To ensure symmetric routing for TProxy if GW1 is on same subnet)
echo "Configuring NAT (Masquerade)..."
# Clean up old rules first to prevent duplicates
iptables -t nat -D POSTROUTING -o $IF1 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -o $IF2 -j MASQUERADE 2>/dev/null || true

# Add new rules
iptables -t nat -A POSTROUTING -o $IF1 -j MASQUERADE
iptables -t nat -A POSTROUTING -o $IF2 -j MASQUERADE

# Flush routing cache to apply changes immediately
ip route flush cache

echo "Multipath routing configured successfully"
