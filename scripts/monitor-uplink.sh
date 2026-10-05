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
# Last Modified: 2026-10-05 10:00:00
##

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

STATE_FILE="$UPLINK_STATE_FILE"

# --- Helpers ---------------------------------------------------------------
# Returns 0 if the routing table for $iface looks broken (UP+IP but empty or
# unreachable gateway), so that we can trigger a re-setup.
needs_restore() {
    local iface=$1 table=$2 gw

    [ -n "$(get_ip "$iface")" ] || return 1

    if ! ip -4 route show table "$table" default 2>/dev/null | grep -q .; then
        log_warn "Interface $iface is UP with IP, but Table $table has no default route."
        return 0
    fi

    gw=$(ip -4 route show table "$table" default 2>/dev/null | awk '$2 == "via" { print $3; exit }')
    if [ -n "$gw" ] && ! ip route get "$gw" dev "$iface" >/dev/null 2>&1; then
        log_warn "Gateway $gw in Table $table is unreachable from $iface."
        return 0
    fi
    return 1
}

# Reapply routing exactly once per run. tproxy-routing.service Requires=
# multipath-routing.service, so restarting the latter also restarts the
# former when it is active; the explicit `start` revives it if it had failed.
trigger_restart() {
    log_warn "Reapplying routing (reason: $1)..."
    if systemctl restart multipath-routing.service; then
        systemctl start tproxy-routing.service || log_error "tproxy-routing.service failed to start."
    else
        log_error "multipath-routing.service failed; see journalctl -u multipath-routing.service."
    fi
}

# --- Main ------------------------------------------------------------------
RESTART_REASON=""
HAS_SECONDARY_UPLINK=0
if secondary_uplink_enabled; then
    HAS_SECONDARY_UPLINK=1
fi

# 1. Sanity check: detect missing/broken routing tables for either interface.
if needs_restore "$IF1" "$TABLE1" || { [ "$HAS_SECONDARY_UPLINK" -eq 1 ] && needs_restore "$IF2" "$TABLE2"; }; then
    RESTART_REASON="missing/broken routing table"
fi

# 2. Connectivity-driven state machine.
GW1=$(get_gateway "$IF1" "$TABLE1")
GW2=""
STATUS1=0
STATUS2=0
check_connectivity "$IF1" "$GW1" && STATUS1=1
log_info "Interface $IF1 (GW: ${GW1:-?}): $([ "$STATUS1" -eq 1 ] && echo UP || echo DOWN)"

if [ "$HAS_SECONDARY_UPLINK" -eq 1 ]; then
    GW2=$(get_gateway "$IF2" "$TABLE2")
    check_connectivity "$IF2" "$GW2" && STATUS2=1
    log_info "Interface $IF2 (GW: ${GW2:-?}): $([ "$STATUS2" -eq 1 ] && echo UP || echo DOWN)"
fi

NEW_STATE=$(uplink_state "$STATUS1" "$STATUS2")
OLD_STATE=""
[ -f "$STATE_FILE" ] && OLD_STATE=$(cat "$STATE_FILE")

if [ "$NEW_STATE" != "$OLD_STATE" ]; then
    [ -z "$RESTART_REASON" ] && RESTART_REASON="state ${OLD_STATE:-<none>} -> $NEW_STATE"
    echo "$NEW_STATE" >"$STATE_FILE"
fi

# 3. Single restart point — handles both restore and state-change cases.
if [ -n "$RESTART_REASON" ]; then
    trigger_restart "$RESTART_REASON"
else
    log_info "State unchanged ($NEW_STATE); no action."
fi
