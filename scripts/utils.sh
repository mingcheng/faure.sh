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
# Last Modified: 2026-01-14 10:00:00
##

# Source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/config.sh" ]; then
    source "$SCRIPT_DIR/config.sh"
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

# Return success when the secondary uplink is configured as a distinct
# interface and currently has IPv4. Setting IF2 empty, setting it to IF1, or
# leaving the default IF2 inactive on a one-NIC host switches scripts into
# single-uplink mode; monitor-uplink will pick IF2 up on a later run once the
# NIC appears and receives an address.
secondary_uplink_enabled() {
    [ -n "${IF2:-}" ] && [ "${IF2:-}" != "${IF1:-}" ] && [ -n "$(get_ip "$IF2")" ]
}

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

    # 4. Static fallback for the primary WAN interface (configurable via
    #    IF1_GW_FALLBACK in config.sh; empty disables the fallback).
    if [ -z "$gw" ] && [ -n "${IF1_GW_FALLBACK:-}" ] && [ "$iface" = "${IF1:-eth0}" ]; then
        gw="$IF1_GW_FALLBACK"
    fi

    echo "$gw"
}

# Check connectivity via an interface
# Usage: check_connectivity <interface> <gateway> [timeout]
#
# Strategy:
#   1. ICMP echo to a small list of well-known IPs, source-bound to $iface.
#   2. If ICMP fails (common on cellular / 5G uplinks that block ICMP to the
#      public Internet but allow it to the carrier gateway), fall back to a
#      bash /dev/tcp probe against 223.5.5.5:443 / 119.29.29.29:443. A
#      successful TCP handshake -- even an immediate RST -- proves the path
#      is up; only DROP/black-hole returns failure.
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

    # --- Phase 1: ICMP ---
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

    # --- Phase 2: TCP fallback (carriers commonly block ICMP) ---
    if [ "$success" -eq 0 ]; then
        local ip_addr
        ip_addr=$(get_ip "$iface")
        for target in "${targets[@]}"; do
            # Pin route via $iface so the TCP probe really egresses there.
            if [ -n "$gw" ]; then
                ip route replace "$target" via "$gw" dev "$iface" 2>/dev/null || true
            fi

            # bash /dev/tcp respects the kernel routing table; with the
            # temporary route above plus the source IP we ensure the SYN
            # leaves on $iface. timeout(1) caps the syscall.
            if [ -n "$ip_addr" ] && \
               timeout "$timeout" bash -c \
                 "exec 9<>/dev/tcp/$target/443" 2>/dev/null; then
                success=1
                exec 9<&- 2>/dev/null || true
                exec 9>&- 2>/dev/null || true
            fi

            if [ -n "$gw" ]; then
                ip route del "$target" via "$gw" dev "$iface" 2>/dev/null || true
            fi

            if [ "$success" -eq 1 ]; then break; fi
        done
    fi

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

# --- Tethering / Hotspot detection bypass ---------------------------------
#
# Rewrite the IPv4 TTL (and IPv6 Hop-Limit) of every packet leaving the
# given WAN interface to a fixed value. This is applied in mangle POSTROUTING
# *after* the kernel's normal forwarding decrement, so the packet egresses
# with exactly $TTL_BYPASS_VALUE regardless of how many internal hops it
# took. Carriers that detect tethering by looking for the "off-by-one" TTL
# fingerprint (TTL = phone_default - 1) are defeated.
#
# Notes:
#   * iptables `TTL` target needs xt_TTL; ip6tables `HL` target needs xt_HL.
#     Both are part of the standard `iptables-extensions` package on Debian
#     and are auto-loaded by the kernel on first use. IPv6 is best-effort:
#     if the module is missing we warn and continue.
#   * Idempotent: any pre-existing TTL/HL rule for the interface (regardless
#     of the previous value) is removed before the new one is appended, so
#     repeated invocations (e.g. via monitor-uplink) do not stack rules.
#   * If $TTL_BYPASS_ENABLED is 0/false/empty, this becomes a no-op cleanup
#     so flipping the toggle off and re-running setup removes the rules.

# Sanity-check the configured TTL value. Returns 0 if usable, 1 otherwise.
_ttl_bypass_validate_value() {
    local v="${TTL_BYPASS_VALUE:-}"
    case "$v" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$v" -ge 1 ] && [ "$v" -le 255 ]
}

# Remove any TTL/HL rewrite rule we may have installed on the given iface.
# Loops because legacy installs (or value changes) could have left multiple.
# Usage: clear_ttl_bypass <iface>
clear_ttl_bypass() {
    local iface="$1"
    [ -z "$iface" ] && return 0

    # IPv4: drop every TTL-set rule we previously appended for this iface.
    while iptables -t mangle -S POSTROUTING 2>/dev/null \
            | grep -E -- "-o[[:space:]]+${iface}([[:space:]]|$).*-j[[:space:]]+TTL" \
            | head -n 1 | grep -q . ; do
        local rule
        rule=$(iptables -t mangle -S POSTROUTING \
                | grep -E -- "-o[[:space:]]+${iface}([[:space:]]|$).*-j[[:space:]]+TTL" \
                | head -n 1 | sed -E 's/^-A /-D /')
        # shellcheck disable=SC2086
        iptables -t mangle $rule 2>/dev/null || break
    done

    # IPv6: same dance, best-effort.
    if command -v ip6tables >/dev/null 2>&1; then
        while ip6tables -t mangle -S POSTROUTING 2>/dev/null \
                | grep -E -- "-o[[:space:]]+${iface}([[:space:]]|$).*-j[[:space:]]+HL" \
                | head -n 1 | grep -q . ; do
            local rule6
            rule6=$(ip6tables -t mangle -S POSTROUTING \
                    | grep -E -- "-o[[:space:]]+${iface}([[:space:]]|$).*-j[[:space:]]+HL" \
                    | head -n 1 | sed -E 's/^-A /-D /')
            # shellcheck disable=SC2086
            ip6tables -t mangle $rule6 2>/dev/null || break
        done
    fi
}

# Apply (or, if disabled, just clean up) the TTL/HL rewrite on a WAN iface.
# Usage: apply_ttl_bypass <iface>
apply_ttl_bypass() {
    local iface="$1"
    [ -z "$iface" ] && return 0

    # Always clear first so toggling the feature off and re-running setup
    # actually removes the rules.
    clear_ttl_bypass "$iface"

    case "${TTL_BYPASS_ENABLED:-1}" in
        1|true|TRUE|yes|on) ;;
        *)
            log_info "TTL bypass disabled; skipping $iface."
            return 0
            ;;
    esac

    if ! _ttl_bypass_validate_value; then
        log_warn "TTL_BYPASS_VALUE='${TTL_BYPASS_VALUE:-}' is not an integer in 1..255; skipping $iface."
        return 0
    fi

    local val="$TTL_BYPASS_VALUE"

    # IPv4 -- must succeed (xt_TTL ships with the standard iptables package).
    if iptables -t mangle -A POSTROUTING -o "$iface" -j TTL --ttl-set "$val" 2>/dev/null; then
        log_info "TTL bypass: $iface egress TTL pinned to $val (IPv4)."
    else
        log_warn "TTL bypass: failed to install IPv4 TTL rule on $iface (xt_TTL module missing?)."
    fi

    # IPv6 -- optional. Skip silently if ip6tables is not present at all.
    if command -v ip6tables >/dev/null 2>&1; then
        if ip6tables -t mangle -A POSTROUTING -o "$iface" -j HL --hl-set "$val" 2>/dev/null; then
            log_info "TTL bypass: $iface egress Hop-Limit pinned to $val (IPv6)."
        else
            log_warn "TTL bypass: failed to install IPv6 HL rule on $iface (xt_HL module missing?)."
        fi
    fi
}
