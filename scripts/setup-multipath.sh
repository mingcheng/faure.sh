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

# Routing Table Names
TABLE1="100"
TABLE2="101"

# --- Helper Functions ---
get_ip() {
    ip -4 addr show $1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1
}

get_subnet() {
    ip route show dev $1 scope link | grep -v "linkdown" | awk '{print $1}' | head -n 1
}

get_gateway() {
    # Try to find gateway in main table first
    local gw=$(ip route show dev $1 default | awk '/default/ {print $3}')
    # Fallback for static config if not in main table yet (e.g. defined in netplan but not applied to main)
    if [ -z "$gw" ] && [ "$1" == "eth0" ]; then
        echo "172.16.1.1" # Fallback for static WAN
    else
        echo "$gw"
    fi
}

# --- Execution ---

echo "Configuring multipath routing..."

IP1=$(get_ip $IF1)
IP2=$(get_ip $IF2)

if [ -z "$IP1" ]; then echo "Error: No IP for $IF1"; exit 1; fi
if [ -z "$IP2" ]; then echo "Error: No IP for $IF2"; exit 1; fi

echo "$IF1 IP: $IP1"
echo "$IF2 IP: $IP2"

# Detect Subnets
SUBNET1=$(get_subnet $IF1)
SUBNET2=$(get_subnet $IF2)
echo "$IF1 Subnet: $SUBNET1"
echo "$IF2 Subnet: $SUBNET2"

# Detect Gateways
GW1=$(get_gateway $IF1)
GW2=$(get_gateway $IF2)

if [ -z "$GW1" ]; then echo "Error: No Gateway for $IF1"; exit 1; fi
if [ -z "$GW2" ]; then echo "Error: No Gateway for $IF2"; exit 1; fi

echo "$IF1 Gateway: $GW1"
echo "$IF2 Gateway: $GW2"

# Flush old routing table rules
echo "Flushing old routing tables..."
ip route flush table $TABLE1 || true
ip route flush table $TABLE2 || true

# Configure Table 1 ($IF1)
echo "Configuring route table $TABLE1..."
# Add local subnet routes to table to ensure local traffic works
[ -n "$SUBNET1" ] && ip route add $SUBNET1 dev $IF1 table $TABLE1
[ -n "$SUBNET2" ] && ip route add $SUBNET2 dev $IF2 table $TABLE1
ip route add default via $GW1 dev $IF1 table $TABLE1

# Configure Table 2 ($IF2)
echo "Configuring route table $TABLE2..."
[ -n "$SUBNET1" ] && ip route add $SUBNET1 dev $IF1 table $TABLE2
[ -n "$SUBNET2" ] && ip route add $SUBNET2 dev $IF2 src $IP2 table $TABLE2
ip route add default via $GW2 dev $IF2 table $TABLE2

# Cleanup old policy routing rules
echo "Cleaning up old policy rules..."
ip rule del from $IP1 table $TABLE1 priority 100 2>/dev/null || true
ip rule del from $IP2 table $TABLE2 priority 101 2>/dev/null || true
# Remove old subnet rules if they exist
[ -n "$SUBNET2" ] && ip rule del from $SUBNET2 table $TABLE2 priority 101 2>/dev/null || true

# Add new policy routing rules
echo "Adding new policy rules..."
ip rule add from $IP1 table $TABLE1 priority 100
ip rule add from $IP2 table $TABLE2 priority 101
# Ensure traffic originating from eth2 subnet uses table 2
[ -n "$SUBNET2" ] && ip rule add from $SUBNET2 table $TABLE2 priority 101

# --- Docker/NAT Compatibility (Connection Marking) ---
echo "Configuring connection marking..."
MARK1="0x100"
MARK2="0x200"

iptables -t mangle -N MULTIPATH_MARK 2>/dev/null || true
iptables -t mangle -F MULTIPATH_MARK
iptables -t mangle -A MULTIPATH_MARK -j CONNMARK --restore-mark
# Exclude LAN traffic from being marked as "WAN incoming" on IF1
iptables -t mangle -A MULTIPATH_MARK -i $IF1 ! -s $LAN_NET -m conntrack --ctstate NEW -j MARK --set-mark $MARK1
iptables -t mangle -A MULTIPATH_MARK -i $IF2 -m conntrack --ctstate NEW -j MARK --set-mark $MARK2
iptables -t mangle -A MULTIPATH_MARK -m mark ! --mark 0 -j CONNMARK --save-mark
iptables -t mangle -A MULTIPATH_MARK -m mark --mark $MARK1 -j ACCEPT
iptables -t mangle -A MULTIPATH_MARK -m mark --mark $MARK2 -j ACCEPT

# Insert at position 1
iptables -t mangle -D PREROUTING -j MULTIPATH_MARK 2>/dev/null || true
iptables -t mangle -I PREROUTING 1 -j MULTIPATH_MARK

# Add ip rules for the marks
ip rule del fwmark $MARK1 table $TABLE1 2>/dev/null || true
ip rule del fwmark $MARK2 table $TABLE2 2>/dev/null || true
ip rule add fwmark $MARK1 table $TABLE1 priority 90
ip rule add fwmark $MARK2 table $TABLE2 priority 91

# Update main routing table
echo "Updating main routing table..."
ip route del default 2>/dev/null || true
# Ensure main table has routes to gateways (needed for nexthop)
ip route replace $GW1 dev $IF1 2>/dev/null || true
ip route replace $GW2 dev $IF2 2>/dev/null || true

echo "Adding multipath default route..."
ip route add default scope global \
    nexthop via $GW1 dev $IF1 weight 1 \
    nexthop via $GW2 dev $IF2 weight 1

# NAT
echo "Configuring NAT..."
iptables -t nat -D POSTROUTING -o $IF1 -j MASQUERADE 2>/dev/null || true
iptables -t nat -D POSTROUTING -o $IF2 -j MASQUERADE 2>/dev/null || true
iptables -t nat -A POSTROUTING -o $IF1 -j MASQUERADE
iptables -t nat -A POSTROUTING -o $IF2 -j MASQUERADE

ip route flush cache
echo "Multipath routing configured successfully"
