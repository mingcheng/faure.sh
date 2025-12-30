#!/usr/bin/env bash
# Copyright (c) 2025 mingcheng <mingcheng@apache.org>
#
# Monitor uplink status and update multipath routing
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: monitor-uplink.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-27 22:40:47
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2025-12-30 22:09:24
##

# Configuration
IF1="eth0"
IF2="eth1"
TABLE1="100"
TABLE2="101"
CHECK_TARGETS=("223.5.5.5" "119.29.29.29")
CHECK_TIMEOUT=2
WEIGHT1=1
WEIGHT2=1

# State file to avoid flapping/unnecessary updates
STATE_FILE="/run/uplink_status"

# Function to get IP address
get_ip() {
    ip -4 addr show $1 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1
}

# Function to get Gateway IP for an interface
get_gateway() {
    local iface=$1
    local gw=""

    # 1. Try specific tables first (most reliable)
    if [ "$iface" == "$IF1" ]; then
         gw=$(ip route show table $TABLE1 2>/dev/null | grep default | awk '{print $3}')
    elif [ "$iface" == "$IF2" ]; then
         gw=$(ip route show table $TABLE2 2>/dev/null | grep default | awk '{print $3}')
    fi

    # 2. If not found, try main table (handle simple 'default via')
    if [ -z "$gw" ]; then
         gw=$(ip route show dev $iface 2>/dev/null | grep "default via" | awk '{print $3}')
    fi

    # 3. DHCP fallback (Heuristic)
    if [ -z "$gw" ]; then
         # Get the subnet from scope link (e.g., 192.168.66.0/24)
         local subnet=$(ip route show dev $iface proto kernel scope link 2>/dev/null | awk '{print $1}' | head -n 1)
         if [ -n "$subnet" ]; then
             # Assume gateway is the .1 address of the subnet
             # This works for standard /24 networks commonly used in tethering/routers
             local prefix=$(echo "$subnet" | cut -d. -f1-3)
             gw="${prefix}.1"
         fi
    fi

    # 4. Fallback for eth0 (static)
    if [ -z "$gw" ] && [ "$iface" == "eth0" ]; then
        gw="172.16.1.1"
    fi

    echo "$gw"
}

# Function to check connectivity
check_connectivity() {
    local iface=$1
    local up=0

    # Check if interface exists
    if ! ip link show "$iface" >/dev/null 2>&1; then
        echo 0
        return
    fi

    for target in "${CHECK_TARGETS[@]}"; do
        # Use ping with interface binding.
        # We use -c 1 -W $CHECK_TIMEOUT.
        # We need to ensure the ping uses the correct source IP/interface routing.
        # ping -I $iface usually works if the interface has an IP and a route.
        if ping -I $iface -c 1 -W $CHECK_TIMEOUT $target >/dev/null 2>&1; then
            up=1
            break
        fi
    done

    echo $up
}

# --- Auto-Restore Logic ---
# Check if interfaces are up but missing routing tables (e.g. after reconnect)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEEDS_RESTORE=0

check_restore_needed() {
    local iface=$1
    local table=$2

    # Check if interface exists and is UP
    if ip link show "$iface" >/dev/null 2>&1; then
        # Check if it has an IP address
        if ip -4 addr show "$iface" | grep -q "inet"; then
            # Check if its routing table is empty
            if [ -z "$(ip route show table $table 2>/dev/null | grep default)" ]; then
                echo "Interface $iface is UP with IP, but Table $table is empty."
                return 0 # Needs restore
            fi
        else
            # Interface exists but no IP.
            # If it's eth1 (USB), it might be waiting for DHCP.
            # We can try to trigger DHCP if we are sure (optional, risky if network manager is active)
            echo "Interface $iface is UP but has no IP address."
        fi
    fi
    return 1 # No restore needed
}

# Wait for network initialization (up to 60 seconds)
MAX_RETRIES=30
RETRY_DELAY=2
count=0

while [ $count -lt $MAX_RETRIES ]; do
    IP1=$(get_ip $IF1)
    IP2=$(get_ip $IF2)

    if [ -n "$IP1" ] || [ -n "$IP2" ]; then
        break
    fi

    # Only log periodically to avoid spamming journal
    if [ $((count % 5)) -eq 0 ]; then
        echo "Waiting for network interfaces to obtain IP addresses... ($((count+1))/$MAX_RETRIES)"
    fi
    sleep $RETRY_DELAY
    count=$((count+1))
done

if check_restore_needed "$IF1" "$TABLE1"; then NEEDS_RESTORE=1; fi
if check_restore_needed "$IF2" "$TABLE2"; then NEEDS_RESTORE=1; fi

if [ "$NEEDS_RESTORE" -eq 1 ]; then
    echo "Detected missing routing tables. Attempting to restore multipath configuration..."
    systemctl restart multipath-routing.service
    sleep 5 # Wait a bit for routes to be set
    systemctl restart tproxy-routing.service
fi

# Main logic
GW1=$(get_gateway $IF1)
GW2=$(get_gateway $IF2)

# Check status
STATUS1=$(check_connectivity $IF1)
STATUS2=$(check_connectivity $IF2)

# Log status
echo "Interface $IF1 (GW: $GW1): $( [ "$STATUS1" -eq 1 ] && echo "UP" || echo "DOWN" )"
echo "Interface $IF2 (GW: $GW2): $( [ "$STATUS2" -eq 1 ] && echo "UP" || echo "DOWN" )"

# Determine desired state
if [ "$STATUS1" -eq 1 ] && [ "$STATUS2" -eq 1 ]; then
    NEW_STATE="BOTH"
elif [ "$STATUS1" -eq 1 ]; then
    NEW_STATE="IF1_ONLY"
elif [ "$STATUS2" -eq 1 ]; then
    NEW_STATE="IF2_ONLY"
else
    NEW_STATE="NONE"
fi

# Read previous state
if [ -f "$STATE_FILE" ]; then
    OLD_STATE=$(cat "$STATE_FILE")
else
    OLD_STATE=""
fi

# Apply changes if state changed
if [ "$NEW_STATE" != "$OLD_STATE" ]; then
    echo "State changed from '$OLD_STATE' to '$NEW_STATE'. Updating routing..."

    # Trigger the setup script to re-configure routing based on current availability
    systemctl restart multipath-routing.service

    # Restart TProxy to ensure rules priority and chains are correct
    systemctl restart tproxy-routing.service

    # Save new state
    echo "$NEW_STATE" > "$STATE_FILE"
else
    echo "State unchanged."
fi
