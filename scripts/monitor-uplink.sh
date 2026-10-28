#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
#
# Monitor uplink status and update multipath routing.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: monitor-uplink.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-27 22:40:47
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-10-28 17:34:53
##

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

# --- Helpers ---------------------------------------------------------------
# Returns 0 if the routing table for $iface looks broken (UP+IP but empty or
# unreachable gateway), so that we can trigger a re-setup.
needs_restore() {
    local iface=$1 table=$2 gw current_ip route detected_gw

    current_ip=$(get_ip "$iface")
    [ -n "$current_ip" ] || return 1

    if ! route=$(ip -4 route show table "$table" default 2>/dev/null) || [ -z "$route" ]; then
        log_warn "Interface $iface is UP with IP, but Table $table has no default route."
        return 0
    fi

    if [[ " $route " != *" dev $iface "* || " $route " != *" src $current_ip "* ]]; then
        log_warn "Table $table no longer matches $iface ($current_ip); refreshing DHCP-dependent routes and rules."
        return 0
    fi

    gw=$(awk '$2 == "via" { print $3; exit }' <<<"$route")
    detected_gw=$(get_gateway "$iface" "$table")
    if [ -n "$detected_gw" ] && [ "$gw" != "$detected_gw" ]; then
        log_warn "Gateway for $iface changed from ${gw:-<none>} to $detected_gw."
        return 0
    fi
    if [ -n "$gw" ] && ! ip route get "$gw" dev "$iface" >/dev/null 2>&1; then
        log_warn "Gateway $gw in Table $table is unreachable from $iface."
        return 0
    fi
    return 1
}

ensure_tproxy_started() {
    local enabled
    systemctl is-active --quiet tproxy-routing.service && return 0
    if ! enabled=$(systemctl is-enabled tproxy-routing.service); then
        case "$enabled" in
            disabled | masked | masked-runtime)
                log_info "TProxy is $enabled; skipping automatic startup."
                return 0
                ;;
            *)
                log_error "Cannot determine whether tproxy-routing.service is enabled."
                return 1
                ;;
        esac
    fi
    log_warn "TProxy is not active; starting tproxy-routing.service..."
    if ! systemctl start tproxy-routing.service; then
        log_error "tproxy-routing.service failed to start; the next monitor run will retry."
        return 1
    fi
}

# Reapply routing once; retry TProxy independently of the persisted uplink
# state, which may already have been updated by a successful multipath setup.
trigger_restart() {
    log_warn "Reapplying routing (reason: $1)..."
    if ! systemctl restart multipath-routing.service; then
        log_error "multipath-routing.service failed; see journalctl -u multipath-routing.service."
        return 1
    fi
    ensure_tproxy_started
}

# --- Main ------------------------------------------------------------------
main() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root."
        return 1
    fi

    local RESTART_REASON="" HAS_SECONDARY_UPLINK=0
    local GW1 GW2="" STATUS1=0 STATUS2=0 NEW_STATE OLD_STATE=""
    if secondary_uplink_enabled; then
        HAS_SECONDARY_UPLINK=1
    fi

    if needs_restore "$IF1" "$TABLE1" || { [ "$HAS_SECONDARY_UPLINK" -eq 1 ] && needs_restore "$IF2" "$TABLE2"; }; then
        RESTART_REASON="missing/broken routing table"
    elif ! ip -4 route show default | grep -q '^default'; then
        RESTART_REASON="missing main default route"
    fi

    GW1=$(get_gateway "$IF1" "$TABLE1")
    if [ -n "$(get_ip "$IF1")" ] && [ -n "$GW1" ] && check_connectivity "$IF1" "$GW1"; then
        STATUS1=1
    fi
    log_info "Interface $IF1 (GW: ${GW1:-?}): $([ "$STATUS1" -eq 1 ] && echo UP || echo DOWN)"

    if [ "$HAS_SECONDARY_UPLINK" -eq 1 ]; then
        GW2=$(get_gateway "$IF2" "$TABLE2")
        if [ -n "$GW2" ] && check_connectivity "$IF2" "$GW2"; then
            STATUS2=1
        fi
        log_info "Interface $IF2 (GW: ${GW2:-?}): $([ "$STATUS2" -eq 1 ] && echo UP || echo DOWN)"
    fi

    NEW_STATE=$(uplink_state "$STATUS1" "$STATUS2")
    if [ -f "$UPLINK_STATE_FILE" ]; then
        OLD_STATE=$(cat "$UPLINK_STATE_FILE")
    fi

    # Only setup-multipath.sh records state, after applying routing.
    if [ "$NEW_STATE" != "$OLD_STATE" ] && [ -z "$RESTART_REASON" ]; then
        RESTART_REASON="state ${OLD_STATE:-<none>} -> $NEW_STATE"
    fi

    if [ -n "$RESTART_REASON" ]; then
        trigger_restart "$RESTART_REASON"
    else
        log_info "State unchanged ($NEW_STATE); checking TProxy service."
        ensure_tproxy_started
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main
fi
