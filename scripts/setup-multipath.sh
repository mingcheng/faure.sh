#!/usr/bin/env bash
# Copyright (c) 2025 mingcheng <mingcheng@apache.org>
#
# Setup multipath routing for load balancing between two interfaces
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: setup-multipath.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-27 23:13:18
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2025-12-30 21:59:53
##

# Exit on error
set -e

# --- Configuration ---
IF1="eth0"
IF2="eth1"
LAN_NET="172.16.1.0/24"

# Routing Table Names
TABLE1="100"
TABLE2="101"

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# --- Execution ---

log_info "Configuring multipath routing..."

# Wait for network initialization (up to 60 seconds)
# This prevents the script from failing immediately at boot if DHCP is slow
MAX_RETRIES=30
RETRY_DELAY=2
count=0

while [ $count -lt $MAX_RETRIES ]; do
    IP1=$(get_ip $IF1)
    IP2=$(get_ip $IF2)

    if [ -n "$IP1" ] || [ -n "$IP2" ]; then
        break
    fi

    log_info "Waiting for network interfaces to obtain IP addresses... ($((count+1))/$MAX_RETRIES)"
    sleep $RETRY_DELAY
    count=$((count+1))
done

IP1=$(get_ip $IF1)
IP2=$(get_ip $IF2)

# Check which interfaces are available
HAS_IF1=0
HAS_IF2=0

if [ -n "$IP1" ]; then
    log_info "$IF1 IP: $IP1"
    HAS_IF1=1
else
    log_warn "No IP for $IF1. Skipping $IF1 configuration."
fi

if [ -n "$IP2" ]; then
    log_info "$IF2 IP: $IP2"
    HAS_IF2=1
else
    log_warn "No IP for $IF2. Skipping $IF2 configuration."
fi

if [ "$HAS_IF1" -eq 0 ] && [ "$HAS_IF2" -eq 0 ]; then
    log_error "Neither $IF1 nor $IF2 has an IP address. Exiting."
    exit 1
fi

# Detect Subnets
SUBNET1=""
SUBNET2=""
if [ "$HAS_IF1" -eq 1 ]; then
    SUBNET1=$(get_subnet $IF1)
    log_info "$IF1 Subnet: $SUBNET1"
fi
if [ "$HAS_IF2" -eq 1 ]; then
    SUBNET2=$(get_subnet $IF2)
    log_info "$IF2 Subnet: $SUBNET2"
fi

# Detect Gateways
GW1=""
GW2=""
if [ "$HAS_IF1" -eq 1 ]; then
    GW1=$(get_gateway $IF1 $TABLE1)
    if [ -z "$GW1" ]; then
        log_error "No Gateway for $IF1"
        HAS_IF1=0
    else
        log_info "$IF1 Gateway: $GW1"
    fi
fi

if [ "$HAS_IF2" -eq 1 ]; then
    GW2=$(get_gateway $IF2 $TABLE2)
    if [ -z "$GW2" ]; then
        log_error "No Gateway for $IF2"
        HAS_IF2=0
    else
        log_info "$IF2 Gateway: $GW2"
    fi
fi

# --- Connectivity Check ---
if [ "$HAS_IF1" -eq 1 ]; then
    log_info "Verifying connectivity for $IF1 via $GW1..."
    if check_connectivity "$IF1" "$GW1"; then
        log_info "$IF1 is UP"
    else
        log_warn "$IF1 failed connectivity check."
        HAS_IF1=0
    fi
fi

if [ "$HAS_IF2" -eq 1 ]; then
    log_info "Verifying connectivity for $IF2 via $GW2..."
    if check_connectivity "$IF2" "$GW2"; then
        log_info "$IF2 is UP"
    else
        log_warn "$IF2 failed connectivity check."
        HAS_IF2=0
    fi
fi

if [ "$HAS_IF1" -eq 0 ] && [ "$HAS_IF2" -eq 0 ]; then
    log_error "No interfaces have internet connectivity. Proceeding to clear routing."
fi

# Flush old routing table rules
log_info "Flushing old routing tables..."
ip route flush table $TABLE1 2>/dev/null || true
ip route flush table $TABLE2 2>/dev/null || true

# Configure Table 1 ($IF1)
if [ "$HAS_IF1" -eq 1 ]; then
    log_info "Configuring route table $TABLE1..."
    # Add local subnet routes to table to ensure local traffic works
    [ -n "$SUBNET1" ] && ip route add $SUBNET1 dev $IF1 table $TABLE1
    [ -n "$SUBNET2" ] && ip route add $SUBNET2 dev $IF2 table $TABLE1 2>/dev/null || true
    ip route add default via $GW1 dev $IF1 table $TABLE1
fi

# Configure Table 2 ($IF2)
if [ "$HAS_IF2" -eq 1 ]; then
    log_info "Configuring route table $TABLE2..."
    [ -n "$SUBNET1" ] && ip route add $SUBNET1 dev $IF1 table $TABLE2 2>/dev/null || true
    [ -n "$SUBNET2" ] && ip route add $SUBNET2 dev $IF2 src $IP2 table $TABLE2
    ip route add default via $GW2 dev $IF2 table $TABLE2
fi

# Cleanup old policy routing rules
log_info "Cleaning up old policy rules..."
# Delete all rules with specific priorities to handle IP changes cleanly
while ip rule del priority 100 2>/dev/null; do :; done
while ip rule del priority 101 2>/dev/null; do :; done

# Add new policy routing rules
log_info "Adding new policy rules..."
if [ "$HAS_IF1" -eq 1 ]; then
    ip rule add from $IP1 table $TABLE1 priority 100
fi
if [ "$HAS_IF2" -eq 1 ]; then
    ip rule add from $IP2 table $TABLE2 priority 101
    # Ensure traffic originating from eth2 subnet uses table 2
    [ -n "$SUBNET2" ] && ip rule add from $SUBNET2 table $TABLE2 priority 101
fi

# --- Docker/NAT Compatibility (Connection Marking) ---
log_info "Configuring connection marking..."
MARK1="0x100"
MARK2="0x200"

iptables -t mangle -N MULTIPATH_MARK 2>/dev/null || true
iptables -t mangle -F MULTIPATH_MARK
iptables -t mangle -A MULTIPATH_MARK -j CONNMARK --restore-mark
# Exclude LAN traffic from being marked as "WAN incoming" on IF1
if [ "$HAS_IF1" -eq 1 ]; then
    iptables -t mangle -A MULTIPATH_MARK -i $IF1 ! -s $LAN_NET -m conntrack --ctstate NEW -j MARK --set-mark $MARK1
fi
if [ "$HAS_IF2" -eq 1 ]; then
    iptables -t mangle -A MULTIPATH_MARK -i $IF2 -m conntrack --ctstate NEW -j MARK --set-mark $MARK2
fi
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
log_info "Updating main routing table..."
ip route del default 2>/dev/null || true
# Ensure main table has routes to gateways (needed for nexthop)
if [ "$HAS_IF1" -eq 1 ]; then
    ip route replace $GW1 dev $IF1 2>/dev/null || true
fi
if [ "$HAS_IF2" -eq 1 ]; then
    ip route replace $GW2 dev $IF2 2>/dev/null || true
fi

log_info "Adding default route..."
if [ "$HAS_IF1" -eq 1 ] && [ "$HAS_IF2" -eq 1 ]; then
    ip route add default scope global \
        nexthop via $GW1 dev $IF1 weight 1 \
        nexthop via $GW2 dev $IF2 weight 1
elif [ "$HAS_IF1" -eq 1 ]; then
    ip route add default via $GW1 dev $IF1
elif [ "$HAS_IF2" -eq 1 ]; then
    ip route add default via $GW2 dev $IF2
fi

# NAT
log_info "Configuring NAT..."
if [ "$HAS_IF1" -eq 1 ]; then
    iptables -t nat -D POSTROUTING -o $IF1 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o $IF1 -j MASQUERADE
fi
if [ "$HAS_IF2" -eq 1 ]; then
    iptables -t nat -D POSTROUTING -o $IF2 -j MASQUERADE 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o $IF2 -j MASQUERADE
fi

ip route flush cache
log_info "Multipath routing configured successfully"
