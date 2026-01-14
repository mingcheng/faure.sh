#!/usr/bin/env bash
# Copyright (c) 2025-2026 mingcheng <mingcheng@apache.org>
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
# Last Modified: 2026-01-09 16:32:59
##

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# Configuration
IF1="eth0"
IF2="eth1"
TABLE1="100"
TABLE2="101"
WEIGHT1=1
WEIGHT2=1

# State file to avoid flapping/unnecessary updates
STATE_FILE="/run/uplink_status"

# --- Auto-Restore Logic ---
# Check if interfaces are up but missing routing tables (e.g. after reconnect)
NEEDS_RESTORE=0

check_restore_needed() {
    local iface=$1
    local table=$2

    # Check if interface exists and is UP
    if ip link show "$iface" >/dev/null 2>&1; then
        # Check if it has an IP address
        if ip -4 addr show "$iface" | grep -q "inet\b"; then
            local route_entry
            route_entry=$(ip route show table "$table" 2>/dev/null | grep default)

            # Check if its routing table is empty
            if [ -z "$route_entry" ]; then
                log_warn "Interface $iface is UP with IP, but Table $table is empty."
                return 0 # Needs restore
            fi

            # Check if the gateway in the table is reachable (valid subnet)
            # Assumes format: default via <GW> ...
            local gw_in_table
            gw_in_table=$(echo "$route_entry" | awk '{print $3}')

            # If format is "default dev ...", gw_in_table is "dev"
            if [ "$gw_in_table" != "dev" ] && [ -n "$gw_in_table" ]; then
                 if ! ip route get "$gw_in_table" dev "$iface" >/dev/null 2>&1; then
                     log_warn "Interface $iface is UP, but gateway $gw_in_table in Table $table is unreachable."
                     return 0 # Needs restore
                 fi
            fi
        else
            # Interface exists but no IP.
            # If it's eth1 (USB), it might be waiting for DHCP.
            # We can try to trigger DHCP if we are sure (optional, risky if network manager is active)
            log_info "Interface $iface is UP but has no IP address."
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
        log_info "Waiting for network interfaces to obtain IP addresses... ($((count+1))/$MAX_RETRIES)"
    fi
    sleep $RETRY_DELAY
    count=$((count+1))
done

if check_restore_needed "$IF1" "$TABLE1"; then NEEDS_RESTORE=1; fi
if check_restore_needed "$IF2" "$TABLE2"; then NEEDS_RESTORE=1; fi

if [ "$NEEDS_RESTORE" -eq 1 ]; then
    log_warn "Detected missing routing tables. Attempting to restore multipath configuration..."
    systemctl restart multipath-routing.service
    sleep 5 # Wait a bit for routes to be set
    systemctl restart tproxy-routing.service
fi

# Main logic
GW1=$(get_gateway $IF1 $TABLE1)
GW2=$(get_gateway $IF2 $TABLE2)

# Check status
STATUS1=0
STATUS2=0

if check_connectivity "$IF1" "$GW1"; then STATUS1=1; fi
if check_connectivity "$IF2" "$GW2"; then STATUS2=1; fi

# Log status
log_info "Interface $IF1 (GW: $GW1): $( [ "$STATUS1" -eq 1 ] && echo "UP" || echo "DOWN" )"
log_info "Interface $IF2 (GW: $GW2): $( [ "$STATUS2" -eq 1 ] && echo "UP" || echo "DOWN" )"

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
    log_info "State changed from '$OLD_STATE' to '$NEW_STATE'. Updating routing..."

    # Trigger the setup script to re-configure routing based on current availability
    systemctl restart multipath-routing.service

    # Restart TProxy to ensure rules priority and chains are correct
    systemctl restart tproxy-routing.service

    # Save new state
    echo "$NEW_STATE" > "$STATE_FILE"
else
    log_info "State unchanged."
fi
