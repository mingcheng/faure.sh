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
         gw=$(ip route show table "$table" 2>/dev/null | grep default | awk '{print $3}')
    fi

    # 2. If not found, try main table (handle simple 'default via')
    if [ -z "$gw" ]; then
         gw=$(ip route show dev "$iface" 2>/dev/null | grep "default via" | awk '{print $3}')
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
            ip route add "$target" via "$gw" dev "$iface" 2>/dev/null || true
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
