#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
#
# Set up TPROXY firewall rules for Mihomo/Clash transparent proxying.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: setup-tproxy.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-03-19 14:32:47
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-05-09
##
#
# Docker compatibility notes:
#  * This script never flushes builtin iptables chains (PREROUTING/POSTROUTING/etc.).
#  * It only manages its own namespaced chain ($CHAIN_NAME) plus a tightly-scoped
#    DNS REDIRECT in the nat table (matched by -i $LAN_IF -s $LAN_NET --dport 53),
#    so docker0 / br-* bridge traffic and Docker's DOCKER/DOCKER-USER chains are
#    untouched.
#  * All inserts use -A (append). Docker's PREROUTING jump to the DOCKER chain
#    therefore evaluates first; only LAN-sourced traffic reaches our rules.
#  * The TPROXY logic lives entirely in the mangle table, which Docker does not
#    use, so there is no conflict with container port publishing.

set -o errexit
set -o nounset
set -o pipefail

# --- Load shared configuration & utilities ---------------------------------
# utils.sh sources config.sh (and any /etc/faure/config.sh override).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

# All tunables come from config.sh; environment variables still take precedence.
LAN_IF="${LAN_IF:?LAN_IF not set (check config.sh)}"
LAN_NET="${LAN_NET:?LAN_NET not set (check config.sh)}"
TPROXY_PORT="${TPROXY_PORT:?TPROXY_PORT not set (check config.sh)}"
TPROXY_DNS_PORT="${TPROXY_DNS_PORT:-53}"
TPROXY_TABLE="${TPROXY_TABLE:-200}"
TPROXY_MARK="${TPROXY_MARK:-0x1}"
CHAIN_NAME="${CHAIN_NAME:-MIHOMO_TPROXY}"
PRIO_TPROXY="${PRIO_TPROXY:-99}"

# How long to wait for Mihomo/Clash listeners before giving up. Mihomo can
# take ~60s (occasionally longer) to download/parse rule providers on first
# start, so the default budget is generous. Override via env / config.
#   TPROXY_WAIT_TIMEOUT  - total wait budget in seconds (default 300 = 5 min)
#   TPROXY_WAIT_INTERVAL - poll interval in seconds (default 2)
TPROXY_WAIT_TIMEOUT="${TPROXY_WAIT_TIMEOUT:-300}"
TPROXY_WAIT_INTERVAL="${TPROXY_WAIT_INTERVAL:-2}"

# --- Pre-flight checks -----------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root."
    exit 1
fi

for cmd in iptables ip ss; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "Command '$cmd' is required but not found."
        exit 1
    fi
done

# Ensure Mihomo/TProxy listeners exist; otherwise adding redirect rules will
# blackhole TCP/UDP traffic.
check_listeners() {
    local tcp_listen=0 udp_dns_listen=0
    local interval="$TPROXY_WAIT_INTERVAL"
    local deadline=$(( $(date +%s) + TPROXY_WAIT_TIMEOUT ))
    local now elapsed remaining

    log_info "Waiting up to ${TPROXY_WAIT_TIMEOUT}s for TProxy listeners (TCP:$TPROXY_PORT, UDP:$TPROXY_DNS_PORT)..."

    while :; do
        tcp_listen=$(ss -lnt "sport = :$TPROXY_PORT" | tail -n +2 | wc -l)
        udp_dns_listen=$(ss -lnu "sport = :$TPROXY_DNS_PORT" | tail -n +2 | wc -l)

        if [ "$tcp_listen" -gt 0 ] && [ "$udp_dns_listen" -gt 0 ]; then
            log_info "TProxy listeners detected (TCP:$TPROXY_PORT, UDP:$TPROXY_DNS_PORT)."
            return 0
        fi

        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            break
        fi

        remaining=$(( deadline - now ))
        elapsed=$(( TPROXY_WAIT_TIMEOUT - remaining ))
        # Log roughly every 10s instead of every poll to keep journal quiet.
        if [ $(( elapsed % 10 )) -lt "$interval" ]; then
            log_info "Still waiting for listeners... (${elapsed}s elapsed, ${remaining}s remaining; TCP=$tcp_listen UDP=$udp_dns_listen)"
        fi

        sleep "$interval"
    done

    [ "$tcp_listen" -eq 0 ] && log_error "No process listening on TCP/$TPROXY_PORT after ${TPROXY_WAIT_TIMEOUT}s (expected Mihomo TProxy)."
    [ "$udp_dns_listen" -eq 0 ] && log_warn "No process listening on UDP/$TPROXY_DNS_PORT after ${TPROXY_WAIT_TIMEOUT}s (DNS). DNS redirection will fail."
    return 1
}

# --- Cleanup ---------------------------------------------------------------
# Only touches our own namespaced chain and a tightly-scoped DNS REDIRECT.
# Docker's DOCKER / DOCKER-USER / DOCKER-ISOLATION-* chains are never flushed.
cleanup_firewall() {
    log_info "Cleaning up existing TPROXY firewall rules..."

    # Detach our chain from PREROUTING (idempotent).
    if iptables -t mangle -C PREROUTING -i "$LAN_IF" -s "$LAN_NET" -j "$CHAIN_NAME" 2>/dev/null; then
        iptables -t mangle -D PREROUTING -i "$LAN_IF" -s "$LAN_NET" -j "$CHAIN_NAME"
    fi
    iptables -t mangle -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -t mangle -X "$CHAIN_NAME" 2>/dev/null || true

    # Routing rules / table.
    while ip rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" 2>/dev/null; do :; done
    ip route flush table "$TPROXY_TABLE" 2>/dev/null || true

    # NAT DNS redirect (scoped, so Docker rules are unaffected).
    local proto
    for proto in udp tcp; do
        iptables -t nat -D PREROUTING -i "$LAN_IF" -s "$LAN_NET" -p "$proto" --dport 53 \
            -j REDIRECT --to-ports "$TPROXY_DNS_PORT" 2>/dev/null || true
    done

    log_info "Cleanup completed."
}

# --- Setup -----------------------------------------------------------------
setup_tproxy_chain() {
    log_info "Creating $CHAIN_NAME chain..."
    iptables -t mangle -N "$CHAIN_NAME"

    # Bypass local / private / multicast / broadcast destinations.
    # 172.16.0.0/12 includes Docker's default bridge ranges, so container
    # traffic is never hijacked by TPROXY.
    local bypass_nets=(
        0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16
        172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4
        255.255.255.255/32
    )
    local net
    for net in "${bypass_nets[@]}"; do
        iptables -t mangle -A "$CHAIN_NAME" -d "$net" -j RETURN
    done

    log_info "Configuring TPROXY rules for TCP/UDP on port $TPROXY_PORT..."
    local proto
    for proto in tcp udp; do
        iptables -t mangle -A "$CHAIN_NAME" -p "$proto" -j MARK --set-mark "$TPROXY_MARK"
        iptables -t mangle -A "$CHAIN_NAME" -p "$proto" -j TPROXY \
            --tproxy-mark "$TPROXY_MARK/$TPROXY_MARK" --on-port "$TPROXY_PORT"
    done

    # Append (not insert): Docker's DOCKER chain still gets first crack at
    # PREROUTING; only LAN-sourced traffic on $LAN_IF reaches us.
    log_info "Attaching $CHAIN_NAME to PREROUTING ($LAN_IF, src $LAN_NET)..."
    iptables -t mangle -A PREROUTING -i "$LAN_IF" -s "$LAN_NET" -j "$CHAIN_NAME"
}

setup_routing() {
    log_info "Setting up routing rules (table $TPROXY_TABLE, prio $PRIO_TPROXY)..."
    # cleanup_firewall already removed any stale rule, so a plain add is safe.
    ip rule add fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" priority "$PRIO_TPROXY"
    ip route replace local 0.0.0.0/0 dev lo table "$TPROXY_TABLE"
}

setup_dns_redirect() {
    log_info "Setting up DNS redirection -> $TPROXY_DNS_PORT (LAN only)..."
    local proto
    for proto in udp tcp; do
        iptables -t nat -A PREROUTING -i "$LAN_IF" -s "$LAN_NET" -p "$proto" --dport 53 \
            -j REDIRECT --to-ports "$TPROXY_DNS_PORT"
    done
}

verify_setup() {
    echo ""
    log_info "=== Verification ==="
    echo "--- Mangle PREROUTING rules ---"
    iptables -t mangle -L PREROUTING -n -v | grep "$CHAIN_NAME" \
        || echo "No $CHAIN_NAME rules found in PREROUTING"

    echo -e "\n--- $CHAIN_NAME chain ---"
    iptables -t mangle -L "$CHAIN_NAME" -n -v

    echo -e "\n--- Routing rules ---"
    ip rule show | grep "$TPROXY_TABLE" || true

    echo -e "\n--- TPROXY routing table ---"
    ip route show table "$TPROXY_TABLE" || true
}

# --- Main ------------------------------------------------------------------
main() {
    log_info "Starting TPROXY setup..."
    log_info "Configuration:"
    echo "  LAN Network:    $LAN_NET"
    echo "  LAN Interface:  $LAN_IF"
    echo "  TProxy Port:    $TPROXY_PORT"
    echo "  DNS Port:       $TPROXY_DNS_PORT"
    echo "  Routing Table:  $TPROXY_TABLE (prio $PRIO_TPROXY)"
    echo "  Firewall Mark:  $TPROXY_MARK"

    # Verify listeners FIRST - do not touch firewall/routing state until we
    # know Mihomo is actually ready. Otherwise a partial cleanup could
    # blackhole LAN traffic if the proxy never comes up.
    if ! check_listeners; then
        log_error "Required listeners are not ready. Aborting without changing any firewall or routing state."
        exit 1
    fi

    cleanup_firewall
    setup_tproxy_chain
    setup_routing
    setup_dns_redirect

    log_info "TPROXY firewall rules configured successfully."
    verify_setup
}

main
