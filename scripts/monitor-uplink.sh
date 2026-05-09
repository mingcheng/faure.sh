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
# Last Modified: 2026-05-09 17:08:15
##

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

# UPLINK_STATE_FILE comes from config.sh.
STATE_FILE="${UPLINK_STATE_FILE:-/run/uplink_status}"

# --- Helpers ---------------------------------------------------------------
# Returns 0 if the routing table for $iface looks broken (UP+IP but empty or
# unreachable gateway), so that we can trigger a re-setup.
needs_restore() {
    local iface=$1
    local table=$2

    ip link show "$iface" >/dev/null 2>&1 || return 1
    ip -4 addr show "$iface" 2>/dev/null | grep -q "inet\b" || return 1

    local route_entry
    route_entry=$(ip route show table "$table" 2>/dev/null | grep '^default')
    if [ -z "$route_entry" ]; then
        log_warn "Interface $iface is UP with IP, but Table $table is empty."
        return 0
    fi

    local gw
    gw=$(echo "$route_entry" | awk '{print $3}')
    if [ -n "$gw" ] && [ "$gw" != "dev" ]; then
        if ! ip route get "$gw" dev "$iface" >/dev/null 2>&1; then
            log_warn "Gateway $gw in Table $table is unreachable from $iface."
            return 0
        fi
    fi
    return 1
}

# Restart routing services exactly once per run, no matter how many reasons
# triggered the restart.
trigger_restart() {
    local reason=$1
    log_warn "Reapplying routing (reason: $reason)..."
    systemctl restart multipath-routing.service
    # Give the kernel a brief moment to install routes before TProxy comes up.
    sleep 3
    systemctl restart tproxy-routing.service
}

# --- Main ------------------------------------------------------------------
RESTART_REASON=""

# 1. Sanity check: detect missing/broken routing tables for either interface.
if needs_restore "$IF1" "$TABLE1" || needs_restore "$IF2" "$TABLE2"; then
    RESTART_REASON="missing/broken routing table"
fi

# 2. Connectivity-driven state machine.
GW1=$(get_gateway "$IF1" "$TABLE1")
GW2=$(get_gateway "$IF2" "$TABLE2")

STATUS1=0
STATUS2=0
check_connectivity "$IF1" "$GW1" && STATUS1=1
check_connectivity "$IF2" "$GW2" && STATUS2=1

log_info "Interface $IF1 (GW: ${GW1:-?}): $([ "$STATUS1" -eq 1 ] && echo UP || echo DOWN)"
log_info "Interface $IF2 (GW: ${GW2:-?}): $([ "$STATUS2" -eq 1 ] && echo UP || echo DOWN)"

if   [ "$STATUS1" -eq 1 ] && [ "$STATUS2" -eq 1 ]; then NEW_STATE="BOTH"
elif [ "$STATUS1" -eq 1 ]; then NEW_STATE="IF1_ONLY"
elif [ "$STATUS2" -eq 1 ]; then NEW_STATE="IF2_ONLY"
else                            NEW_STATE="NONE"
fi

OLD_STATE=""
[ -f "$STATE_FILE" ] && OLD_STATE=$(cat "$STATE_FILE")

if [ "$NEW_STATE" != "$OLD_STATE" ]; then
    [ -z "$RESTART_REASON" ] && RESTART_REASON="state $OLD_STATE -> $NEW_STATE"
    echo "$NEW_STATE" > "$STATE_FILE"
fi

# 3. Single restart point — handles both restore and state-change cases.
if [ -n "$RESTART_REASON" ]; then
    trigger_restart "$RESTART_REASON"
else
    log_info "State unchanged; no action."
fi
