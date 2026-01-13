#!/usr/bin/env bash
# Copyright (c) 2025-2026 mingcheng <mingcheng@apache.org>
#
# Set up TPROXY firewall rules for Clash transparent proxying.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: setup-tproxy.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-03-19 14:32:47
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-01-13 23:43:55
##

# Exit on error, undefined variable, or pipe failure
set -o errexit
set -o nounset
set -o pipefail

# Configuration: Modify these variables or set them in your environment
FAURE_ADDR_RANGE="${FAURE_ADDR_RANGE:-172.16.1.0/24}"
FAURE_INTERFACE="${FAURE_INTERFACE:-eth0}"
FAURE_TPORT="${FAURE_TPORT:-8848}"
TPROXY_TABLE="${TPROXY_TABLE:-200}"  # Use a different routing table to avoid conflicts
TPROXY_MARK="0x1"
CHAIN_NAME="MIHOMO_TPROXY" # Standardized chain name

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root."
    exit 1
fi

# Check required commands
for cmd in iptables ip ss; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Command '$cmd' is required but not found."
        exit 1
    fi
done

# Ensure Clash/TProxy listeners exist; otherwise adding redirect rules will blackhole TCP/UDP
check_listeners() {
    local tcp_listen udp53_listen
    local max_retries=60
    local retry_delay=2
    local count=0

    log_info "Waiting for TProxy listeners (TCP:$FAURE_TPORT, UDP:53)..."

    while [ $count -lt $max_retries ]; do
        tcp_listen=$(ss -lnt sport = ":$FAURE_TPORT" | tail -n +2 | wc -l)
        udp53_listen=$(ss -lnu sport = ":53" | tail -n +2 | wc -l)

        if [ "$tcp_listen" -gt 0 ] && [ "$udp53_listen" -gt 0 ]; then
            log_info "TProxy listeners detected (TCP:$FAURE_TPORT, UDP:53)."
            return 0
        fi

        if [ $((count % 5)) -eq 0 ]; then
             log_info "Waiting for listeners... ($((count+1))/$max_retries)"
        fi

        sleep $retry_delay
        count=$((count+1))
    done

    if [ "$tcp_listen" -eq 0 ]; then
        log_error "No process listening on TCP port $FAURE_TPORT (expected Clash TProxy)."
    fi

    if [ "$udp53_listen" -eq 0 ]; then
        log_warn "No process listening on UDP/53 (DNS). DNS redirection will fail."
    fi

    return 1
}

# Cleanup function to remove existing rules
cleanup_firewall() {
    log_info "Cleaning up existing firewall rules..."

    # Cleanup legacy CLASH_TPROXY if exists
    if iptables -t mangle -C PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -j CLASH_TPROXY 2>/dev/null; then
         iptables -t mangle -D PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -j CLASH_TPROXY
    fi
    iptables -t mangle -F CLASH_TPROXY 2>/dev/null || true
    iptables -t mangle -X CLASH_TPROXY 2>/dev/null || true

    # Remove mangle table rules for current chain
    if iptables -t mangle -C PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -j "$CHAIN_NAME" 2>/dev/null; then
        iptables -t mangle -D PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -j "$CHAIN_NAME"
    fi

    iptables -t mangle -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -t mangle -X "$CHAIN_NAME" 2>/dev/null || true

    # Remove routing rules
    # Blindly delete the rule until it's gone. No grep needed.
    while ip rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" 2>/dev/null; do :; done

    # Flush the table to ensure it's clean
    ip route flush table "$TPROXY_TABLE" 2>/dev/null || true

    # Remove NAT DNS redirect rules
    iptables -t nat -D PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true

    log_info "Cleanup completed."
}

setup_tproxy_chain() {
    log_info "Creating $CHAIN_NAME chain..."
    iptables -t mangle -N "$CHAIN_NAME"

    # Exclude local and private networks
    local private_nets=("0.0.0.0/8" "10.0.0.0/8" "127.0.0.0/8" "169.254.0.0/16" "172.16.0.0/12" "192.168.0.0/16" "224.0.0.0/4" "240.0.0.0/4")
    for net in "${private_nets[@]}"; do
        iptables -t mangle -A "$CHAIN_NAME" -d "$net" -j RETURN
    done

    # Exclude broadcast
    iptables -t mangle -A "$CHAIN_NAME" -d 255.255.255.255/32 -j RETURN

    # Mark and TPROXY for TCP
    log_info "Configuring TPROXY rules for TCP/UDP on port $FAURE_TPORT..."
    iptables -t mangle -A "$CHAIN_NAME" -p tcp -j MARK --set-mark "$TPROXY_MARK"
    iptables -t mangle -A "$CHAIN_NAME" -p tcp -j TPROXY --tproxy-mark "$TPROXY_MARK/$TPROXY_MARK" --on-port "$FAURE_TPORT"

    # Mark and TPROXY for UDP
    iptables -t mangle -A "$CHAIN_NAME" -p udp -j MARK --set-mark "$TPROXY_MARK"
    iptables -t mangle -A "$CHAIN_NAME" -p udp -j TPROXY --tproxy-mark "$TPROXY_MARK/$TPROXY_MARK" --on-port "$FAURE_TPORT"

    # Apply TPROXY chain only to traffic from FAURE_ADDR_RANGE
    log_info "Applying TPROXY chain to interface $FAURE_INTERFACE for range $FAURE_ADDR_RANGE..."
    iptables -t mangle -A PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -j "$CHAIN_NAME"
}

setup_routing() {
    log_info "Setting up routing rules (Table: $TPROXY_TABLE)..."

    # Set up routing for marked packets (Use priority 99, before multipath rules)
    # Delete first to ensure no duplicates and no "File exists" error
    ip rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" priority 99 2>/dev/null || true
    ip rule add fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" priority 99

    # Use replace to ensure the route is set correctly without "File exists" error
    ip route replace local 0.0.0.0/0 dev lo table "$TPROXY_TABLE"
}

setup_dns_redirect() {
    log_info "Setting up DNS redirection..."
    iptables -t nat -A PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -p udp --dport 53 -j REDIRECT --to-ports 53
    iptables -t nat -A PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -p tcp --dport 53 -j REDIRECT --to-ports 53
}

verify_setup() {
    echo ""
    log_info "=== Verification ==="
    echo "--- Mangle PREROUTING rules ---"
    iptables -t mangle -L PREROUTING -n -v | grep "$CHAIN_NAME" || echo "No $CHAIN_NAME rules found in PREROUTING"

    echo -e "\n--- $CHAIN_NAME chain ---"
    iptables -t mangle -L "$CHAIN_NAME" -n -v

    echo -e "\n--- Routing rules ---"
    ip rule show | grep "$TPROXY_TABLE"

    echo -e "\n--- TPROXY routing table ---"
    ip route show table "$TPROXY_TABLE"
}

# Main execution
main() {
    log_info "Starting TPROXY setup..."
    log_info "Configuration:"
    echo "  Network:   $FAURE_ADDR_RANGE"
    echo "  Interface: $FAURE_INTERFACE"
    echo "  TProxy Port: $FAURE_TPORT"
    echo "  Table ID:  $TPROXY_TABLE"

    cleanup_firewall

    if ! check_listeners; then
        log_error "Required listeners are not ready. Aborting to avoid breaking connectivity."
        exit 1
    fi

    setup_tproxy_chain
    setup_routing
    setup_dns_redirect

    log_info "TPROXY firewall rules configured successfully."
    verify_setup
}

# Run main
main
