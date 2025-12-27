#!/bin/bash
#
# Monitor uplink status and update multipath routing
#

# Configuration
IF1="eth0"
IF2="eth1"
TABLE1="100"
TABLE2="101"
CHECK_TARGETS=("8.8.8.8" "1.1.1.1" "223.5.5.5" "119.29.29.29")
CHECK_TIMEOUT=2
WEIGHT1=1
WEIGHT2=1

# State file to avoid flapping/unnecessary updates
STATE_FILE="/run/uplink_status"

# Function to get Gateway IP for an interface
get_gateway() {
    local iface=$1
    # Try to get from main table first
    local gw=$(ip route show dev $iface | grep default | awk '{print $3}')
    if [ -z "$gw" ]; then
        # Try to get from specific tables
        if [ "$iface" == "$IF1" ]; then
             # Try table name first, then ID 100
             gw=$(ip route show table $TABLE1 2>/dev/null | grep default | awk '{print $3}')
             if [ -z "$gw" ]; then gw=$(ip route show table 100 2>/dev/null | grep default | awk '{print $3}'); fi
        elif [ "$iface" == "$IF2" ]; then
             gw=$(ip route show table $TABLE2 2>/dev/null | grep default | awk '{print $3}')
             if [ -z "$gw" ]; then gw=$(ip route show table 101 2>/dev/null | grep default | awk '{print $3}'); fi
        fi
    fi

    # Fallback for eth0 (static) if not found
    if [ -z "$gw" ] && [ "$iface" == "eth0" ]; then
        gw="172.16.1.1"
    fi

    echo "$gw"
}

# Function to check connectivity
check_connectivity() {
    local iface=$1
    local up=0

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

# Main logic
GW1=$(get_gateway $IF1)
GW2=$(get_gateway $IF2)

# If GW2 is empty (maybe eth1 is down or not configured yet), try to detect from system
if [ -z "$GW2" ]; then
    # Try to find any gateway for eth1
    GW2=$(ip route show dev $IF2 | grep default | awk '{print $3}')
fi

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

    case "$NEW_STATE" in
        "BOTH")
            if [ -n "$GW1" ] && [ -n "$GW2" ]; then
                ip route replace default scope global \
                    nexthop via $GW1 dev $IF1 weight $WEIGHT1 \
                    nexthop via $GW2 dev $IF2 weight $WEIGHT2
            fi
            ;;
        "IF1_ONLY")
            if [ -n "$GW1" ]; then
                ip route replace default via $GW1 dev $IF1
            fi
            ;;
        "IF2_ONLY")
            if [ -n "$GW2" ]; then
                ip route replace default via $GW2 dev $IF2
            fi
            ;;
        "NONE")
            echo "All uplinks down!"
            ;;
    esac

    # Save new state
    echo "$NEW_STATE" > "$STATE_FILE"

    # Flush cache
    ip route flush cache
else
    echo "State unchanged."
fi
