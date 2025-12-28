#!/usr/bin/env bash
# Copyright (c) 2025 mingcheng <mingcheng@apache.org>
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
# Last Modified: 2025-12-28 23:27:05
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

# Helper functions for logging
log_info() {
    echo -e "\033[0;32m[INFO]\033[0m $*"
}

log_warn() {
    echo -e "\033[0;33m[WARN]\033[0m $*"
}

log_error() {
    echo -e "\033[0;31m[ERROR]\033[0m $*" >&2
}

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root."
    exit 1
fi

# Check required commands
for cmd in iptables ip; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Command '$cmd' is required but not found."
        exit 1
    fi
done

# Cleanup function to remove existing rules
cleanup_firewall() {
    log_info "Cleaning up existing firewall rules..."

    # Remove mangle table rules
    if iptables -t mangle -C PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -j CLASH_TPROXY 2>/dev/null; then
        iptables -t mangle -D PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -j CLASH_TPROXY
    fi

    iptables -t mangle -F CLASH_TPROXY 2>/dev/null || true
    iptables -t mangle -X CLASH_TPROXY 2>/dev/null || true

    # Remove routing rules
    while ip rule show | grep -q "fwmark $TPROXY_MARK lookup $TPROXY_TABLE"; do
        ip rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE"
    done

    ip route del local 0.0.0.0/0 dev lo table "$TPROXY_TABLE" 2>/dev/null || true

    # Remove NAT DNS redirect rules
    iptables -t nat -D PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -p udp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true
    iptables -t nat -D PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -p tcp --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || true

    log_info "Cleanup completed."
}

setup_tproxy_chain() {
    log_info "Creating CLASH_TPROXY chain..."
    iptables -t mangle -N CLASH_TPROXY

    # Exclude local and private networks
    local private_nets=("0.0.0.0/8" "10.0.0.0/8" "127.0.0.0/8" "169.254.0.0/16" "172.16.0.0/12" "192.168.0.0/16" "224.0.0.0/4" "240.0.0.0/4")
    for net in "${private_nets[@]}"; do
        iptables -t mangle -A CLASH_TPROXY -d "$net" -j RETURN
    done

    # Exclude broadcast
    iptables -t mangle -A CLASH_TPROXY -d 255.255.255.255/32 -j RETURN

    # Mark and TPROXY for TCP
    log_info "Configuring TPROXY rules for TCP/UDP on port $FAURE_TPORT..."
    iptables -t mangle -A CLASH_TPROXY -p tcp -j MARK --set-mark "$TPROXY_MARK"
    iptables -t mangle -A CLASH_TPROXY -p tcp -j TPROXY --tproxy-mark "$TPROXY_MARK/$TPROXY_MARK" --on-port "$FAURE_TPORT"

    # Mark and TPROXY for UDP
    iptables -t mangle -A CLASH_TPROXY -p udp -j MARK --set-mark "$TPROXY_MARK"
    iptables -t mangle -A CLASH_TPROXY -p udp -j TPROXY --tproxy-mark "$TPROXY_MARK/$TPROXY_MARK" --on-port "$FAURE_TPORT"

    # Apply TPROXY chain only to traffic from FAURE_ADDR_RANGE
    log_info "Applying TPROXY chain to interface $FAURE_INTERFACE for range $FAURE_ADDR_RANGE..."
    iptables -t mangle -A PREROUTING -i "$FAURE_INTERFACE" -s "$FAURE_ADDR_RANGE" -j CLASH_TPROXY
}

setup_routing() {
    log_info "Setting up routing rules (Table: $TPROXY_TABLE)..."

    # Set up routing for marked packets (Use priority 99, before multipath rules)
    if ! ip rule show | grep -q "fwmark $TPROXY_MARK lookup $TPROXY_TABLE"; then
        ip rule add fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" priority 99
    fi

    if ! ip route show table "$TPROXY_TABLE" | grep -q "local 0.0.0.0/0 dev lo"; then
        ip route add local 0.0.0.0/0 dev lo table "$TPROXY_TABLE"
    fi
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
    iptables -t mangle -L PREROUTING -n -v | grep CLASH_TPROXY || echo "No CLASH_TPROXY rules found in PREROUTING"

    echo -e "\n--- CLASH_TPROXY chain ---"
    iptables -t mangle -L CLASH_TPROXY -n -v

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
    setup_tproxy_chain
    setup_routing
    setup_dns_redirect

    log_info "TPROXY firewall rules configured successfully."
    verify_setup
}

# Run main
main
