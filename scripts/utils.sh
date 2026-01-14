#!/usr/bin/env bash
# Copyright (c) 2025 mingcheng <mingcheng@apache.org>
#
# Shared utility functions for faure.sh scripts
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: utils.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-31 10:33:40
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2025-12-31 10:38:55
##

# Source utility functions
# SCRIPT_DIR is determined by the caller script mostly, but here we can try to find config
# if utils.sh is sourced, BASH_SOURCE[0] is utils.sh

# Load configuration if available
if [ -f "$(dirname "${BASH_SOURCE[0]}")/config.sh" ]; then
    source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
fi

# --- Logging Functions ---

# Colors
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[1;33m'
COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m' # No Color

log_info() {
    echo -e "${COLOR_GREEN}[INFO] $(date '+%Y-%m-%d %H:%M:%S')${COLOR_NC} $*"
}

log_warn() {
    echo -e "${COLOR_YELLOW}[WARN] $(date '+%Y-%m-%d %H:%M:%S')${COLOR_NC} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR] $(date '+%Y-%m-%d %H:%M:%S')${COLOR_NC} $*" >&2
}

# --- Network Helper Functions ---

# Get IP address of an interface
# Usage: get_ip <interface>
get_ip() {
    local iface=$1
    # Use awk for better portability than grep -P
    ip -4 addr show "$iface" 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n 1
}

# Get Subnet of an interface
# Usage: get_subnet <interface>
get_subnet() {
    local iface=$1
    ip route show dev "$iface" scope link 2>/dev/null | grep -v "linkdown" | awk '{print $1}' | head -n 1
}

# Get Gateway IP for an interface
# Usage: get_gateway <interface> <table_id>
get_gateway() {
    local iface=$1
    local table=$2
    local gw=""

    # 1. Try specific table first (most reliable if already configured)
    if [ -n "$table" ]; then
         local candidate_gw
         candidate_gw=$(ip route show table "$table" 2>/dev/null | grep default | awk '{print $3}')
         # Validate if the gateway is reachable via the interface (subnet match)
         if [ -n "$candidate_gw" ]; then
             if ip route get "$candidate_gw" dev "$iface" >/dev/null 2>&1; then
                 gw="$candidate_gw"
             fi
         fi
    fi

    # 2. If not found, try main table (handle simple 'default via')
    if [ -z "$gw" ]; then
         local candidate_gw
         candidate_gw=$(ip route show dev "$iface" 2>/dev/null | grep "default via" | awk '{print $3}')
         if [ -n "$candidate_gw" ]; then
             gw="$candidate_gw"
         fi
    fi

    # 3. DHCP fallback (Heuristic)
    if [ -z "$gw" ]; then
         # Get the subnet from scope link (e.g., 192.168.66.0/24)
         local subnet=$(get_subnet "$iface")
         if [ -n "$subnet" ]; then
             # Assume gateway is the .1 address of the subnet
             # This works for standard /24 networks commonly used in tethering/routers
             local prefix=$(echo "$subnet" | cut -d. -f1-3)
             gw="${prefix}.1"
         fi
    fi

    # 4. Fallback for eth0 (static) - Specific to this environment
    if [ -z "$gw" ] && [ "$iface" == "eth0" ]; then
        gw="172.16.1.1"
    fi

    echo "$gw"
}

# Check connectivity via an interface
# Usage: check_connectivity <interface> <gateway> [timeout]
check_connectivity() {
    local iface=$1
    local gw=$2
    local timeout=${3:-2}
    local targets=("223.5.5.5" "119.29.29.29")
    local success=0

    # Check if interface exists
    if ! ip link show "$iface" >/dev/null 2>&1; then
        return 1
    fi

    # If no gateway provided, try to find one (optional, but better to be explicit)
    if [ -z "$gw" ]; then
        # We can't reliably check connectivity without a gateway for policy routing
        # But if it's a simple ping on the interface...
        :
    fi

    for target in "${targets[@]}"; do
        # If gateway is provided, add a temporary route to force traffic
        if [ -n "$gw" ]; then
            ip route replace "$target" via "$gw" dev "$iface" 2>/dev/null || true
        fi

        # Use ping with interface binding
        if ping -I "$iface" -c 1 -W "$timeout" "$target" >/dev/null 2>&1; then
            success=1
        fi

        # Clean up temporary route
        if [ -n "$gw" ]; then
            ip route del "$target" via "$gw" dev "$iface" 2>/dev/null || true
        fi

        if [ "$success" -eq 1 ]; then break; fi
    done

    if [ "$success" -eq 1 ]; then
        return 0
    else
        return 1
    fi
}

# Wait for network interface to obtain an IP address
# Usage: wait_for_ip <interface> [max_retries] [retry_delay]
wait_for_ip() {
    local iface=$1
    local max_retries=${2:-30}
    local retry_delay=${3:-2}
    local count=0

    while [ $count -lt $max_retries ]; do
        local ip_addr
        ip_addr=$(get_ip "$iface")

        if [ -n "$ip_addr" ]; then
            return 0
        fi

        # Only log periodically to avoid spamming journal
        if [ $((count % 5)) -eq 0 ]; then
             log_info "Waiting for interface $iface to obtain IP address... ($((count+1))/$max_retries)"
        fi

        sleep "$retry_delay"
        count=$((count+1))
    done

    return 1
}
