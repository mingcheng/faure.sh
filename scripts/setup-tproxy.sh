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
# Last Modified: 2026-10-28 17:34:53
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

set -o errexit -o nounset -o pipefail

# --- Load shared configuration & utilities ---------------------------------
# utils.sh sources config.sh (and any /etc/faure/config.sh override).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

validate_tproxy_config() {
    local value
    if [ -z "$LAN_IF" ] || [ -z "$LAN_NET" ]; then
        log_error "LAN_IF and LAN_NET must be set in the configuration override."
        return 1
    fi
    for value in "$TPROXY_PORT" "$TPROXY_DNS_PORT"; do
        if ! [[ $value =~ ^[1-9][0-9]{0,4}$ ]] || [ "$value" -gt 65535 ]; then
            log_error "TProxy and DNS ports must be decimal integers in 1..65535 (got '$value')."
            return 1
        fi
    done
    for value in "$TPROXY_WAIT_TIMEOUT" "$TPROXY_WAIT_INTERVAL"; do
        if ! [[ $value =~ ^(0|[1-9][0-9]{0,8})$ ]]; then
            log_error "TProxy wait settings must be decimal seconds in 0..999999999 (got '$value')."
            return 1
        fi
    done
    if [ "$TPROXY_WAIT_INTERVAL" -eq 0 ]; then
        log_error "TPROXY_WAIT_INTERVAL must be greater than zero."
        return 1
    fi
}

# Ensure Mihomo/TProxy listeners exist; otherwise adding redirect rules will
# blackhole TCP/UDP traffic.
check_listeners() {
    local started=$SECONDS elapsed remaining delay next_log=0
    local proto port listeners
    local -a missing=()

    log_info "Waiting up to ${TPROXY_WAIT_TIMEOUT}s for TCP/UDP listeners on TProxy:$TPROXY_PORT and DNS:$TPROXY_DNS_PORT..."

    while :; do
        missing=()
        for proto in tcp udp; do
            for port in "$TPROXY_PORT" "$TPROXY_DNS_PORT"; do
                if ! listeners=$(ss -H -ln"${proto:0:1}" "sport = :$port"); then
                    log_error "Could not inspect $proto/$port listeners."
                    return 1
                fi
                [ -n "$listeners" ] || missing+=("$proto/$port")
            done
        done

        if [ "${#missing[@]}" -eq 0 ]; then
            log_info "Required TProxy and DNS TCP/UDP listeners detected."
            return 0
        fi

        elapsed=$((SECONDS - started))
        remaining=$((TPROXY_WAIT_TIMEOUT - elapsed))
        [ "$remaining" -gt 0 ] || break
        if [ "$elapsed" -ge "$next_log" ]; then
            log_info "Still waiting for ${missing[*]}... (${elapsed}s elapsed, ${remaining}s remaining)"
            next_log=$((elapsed + 10))
        fi

        delay="$TPROXY_WAIT_INTERVAL"
        [ "$delay" -le "$remaining" ] || delay="$remaining"
        sleep "$delay"
    done

    log_error "Missing listeners after ${TPROXY_WAIT_TIMEOUT}s: ${missing[*]}."
    return 1
}

# --- Cleanup ---------------------------------------------------------------
# Only touches our own namespaced chain and a tightly-scoped DNS REDIRECT.
# Docker's DOCKER / DOCKER-USER / DOCKER-ISOLATION-* chains are never flushed.
# Rules are matched by their target / comment rather than by the current
# LAN_IF / LAN_NET, so changing those settings leaves nothing stale behind.
DNS_RULE_TAG="faure-tproxy-dns"

cleanup_firewall() {
    log_info "Cleaning up existing TPROXY firewall rules..."

    # Detach our chain from PREROUTING whatever its matchers were.
    delete_rules iptables mangle PREROUTING "-j ${CHAIN_NAME}( |$)"
    iptables -t mangle -F "$CHAIN_NAME" 2>/dev/null || true
    iptables -t mangle -X "$CHAIN_NAME" 2>/dev/null || true

    # Routing rules / table.
    while ip rule del priority "$PRIO_TPROXY" 2>/dev/null; do :; done
    while ip rule del fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" 2>/dev/null; do :; done
    ip route flush table "$TPROXY_TABLE" 2>/dev/null || true

    # NAT DNS redirect (scoped, so Docker rules are unaffected).
    delete_rules iptables nat PREROUTING "--comment \"?${DNS_RULE_TAG}\"?( |$)"
    # Legacy untagged rules from older versions of this script.
    local proto
    for proto in udp tcp; do
        while iptables -t nat -D PREROUTING -i "$LAN_IF" -s "$LAN_NET" -p "$proto" --dport 53 \
            -j REDIRECT --to-ports "$TPROXY_DNS_PORT" 2>/dev/null; do :; done
    done

    log_info "Cleanup completed."
}

# --- Setup -----------------------------------------------------------------
setup_tproxy_chain() {
    log_info "Creating $CHAIN_NAME chain..."
    iptables -t mangle -N "$CHAIN_NAME" 2>/dev/null || true
    iptables -t mangle -F "$CHAIN_NAME"

    # Bypass traffic to the router itself and to local / private / multicast
    # / broadcast destinations. 172.16.0.0/12 includes Docker's default
    # bridge ranges, so container traffic is never hijacked by TPROXY.
    iptables -t mangle -A "$CHAIN_NAME" -m addrtype --dst-type LOCAL -j RETURN
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
    # TPROXY sets the whole fwmark itself (no mask = 0xffffffff), so the
    # exact-match `ip rule fwmark` below hits without a separate MARK rule.
    for proto in tcp udp; do
        iptables -t mangle -A "$CHAIN_NAME" -p "$proto" -j TPROXY \
            --tproxy-mark "$TPROXY_MARK" --on-port "$TPROXY_PORT"
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
            -m comment --comment "$DNS_RULE_TAG" -j REDIRECT --to-ports "$TPROXY_DNS_PORT"
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
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root."
        return 1
    fi
    local cmd
    for cmd in iptables ip ss; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Command '$cmd' is required but not found."
            return 1
        fi
    done
    validate_tproxy_config || return 1

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

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main
fi
