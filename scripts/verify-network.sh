#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
#
# Verify network configuration for multipath routing and TProxy
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: verify-network.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-27 23:53:23
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-10-06 19:30:00
##
#
# Read-only report of the live multipath / TProxy / TTL state. Exits 1 when
# any check FAILs, so it can be used from scripts or monitoring.

# Source shared configuration & utilities (config.sh is required).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"
use_report_logging

FAIL_COUNT=0
# FAIL and count it towards the exit status.
fail() {
    log_fail "$*"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "=============================================="
echo "Network Configuration Verification"
echo "=============================================="

if [ "$(id -u)" -ne 0 ]; then
    log_warn "Not running as root: iptables checks will report missing rules."
fi

HAS_SECONDARY_UPLINK=0
if secondary_uplink_enabled; then
    HAS_SECONDARY_UPLINK=1
fi

# 1. Check Default Route
echo ""
echo "--- 1. Default Route ---"
ROUTE_OUTPUT=$(ip route show default)
if [[ $ROUTE_OUTPUT == *nexthop* ]]; then
    log_pass "Multipath default route detected."
elif [ -n "$ROUTE_OUTPUT" ]; then
    log_pass "Single/failover default route detected."
else
    fail "No usable default route found."
fi
while IFS= read -r line; do
    [ -n "$line" ] && log_info "$line"
done <<<"$ROUTE_OUTPUT"

# 2. Check Routing Rules
echo ""
echo "--- 2. Policy Routing Rules ---"
RULES=$(ip rule show)

check_rule() {
    local prio=$1 desc=$2
    if grep -q "^$prio:" <<<"$RULES"; then
        log_pass "Priority $prio ($desc) exists."
    else
        fail "Priority $prio ($desc) MISSING."
    fi
}

check_rule "$PRIO_MARK1" "Fwmark $MARK1 -> Table $TABLE1"
check_rule "$PRIO_SRC1" "Source IP1 -> Table $TABLE1"
if [ "$HAS_SECONDARY_UPLINK" -eq 1 ]; then
    check_rule "$PRIO_MARK2" "Fwmark $MARK2 -> Table $TABLE2"
    check_rule "$PRIO_SRC2" "Source IP2 -> Table $TABLE2"
else
    log_info "Secondary uplink disabled; skipping $MARK2 / table $TABLE2 rule checks."
fi

# 3. Check IPTables
echo ""
echo "--- 3. IPTables Mangle Rules ---"

if iptables -t mangle -S MULTIPATH_MARK >/dev/null 2>&1; then
    log_pass "Chain MULTIPATH_MARK exists."
else
    fail "Chain MULTIPATH_MARK missing."
fi

if [ -n "$(find_rules iptables mangle PREROUTING "-j MULTIPATH_MARK( |$)")" ]; then
    log_pass "MULTIPATH_MARK hooked in PREROUTING."
else
    fail "MULTIPATH_MARK NOT hooked in PREROUTING."
fi

# 3a. TProxy: optional as a whole, but must be complete once installed.
echo ""
echo "--- 3a. TProxy ---"
if iptables -t mangle -S "$CHAIN_NAME" >/dev/null 2>&1; then
    log_pass "Chain $CHAIN_NAME exists."

    if [ -n "$(find_rules iptables mangle PREROUTING "-j ${CHAIN_NAME}( |$)")" ]; then
        log_pass "$CHAIN_NAME hooked in PREROUTING."
    else
        fail "$CHAIN_NAME NOT hooked in PREROUTING."
    fi

    check_rule "$PRIO_TPROXY" "Fwmark $TPROXY_MARK -> Table $TPROXY_TABLE"

    if ip route show table "$TPROXY_TABLE" 2>/dev/null | grep -q '^local '; then
        log_pass "Table $TPROXY_TABLE has the local delivery route."
    else
        fail "Table $TPROXY_TABLE is missing 'local 0.0.0.0/0 dev lo'."
    fi
else
    log_warn "Chain $CHAIN_NAME missing (TProxy not running); skipping TProxy checks."
fi

# 3b. TTL / Hop-Limit Bypass (tethering detection)
echo ""
echo "--- 3b. TTL / Hop-Limit Bypass ---"

# Print the value of the first live TTL/HL rewrite rule on an iface.
# Usage: live_rewrite_value <iptables|ip6tables> <TTL|HL> <iface>
live_rewrite_value() {
    egress_rewrite_rules "$1" "$2" "$3" \
        | sed -nE 's/.*--(ttl|hl)-set[[:space:]]+([0-9]+).*/\2/p' | head -n 1
}

check_ttl_iface() {
    local iface="$1" v4 v6
    [ -n "$iface" ] || return
    ip link show "$iface" >/dev/null 2>&1 || return

    v4=$(live_rewrite_value iptables TTL "$iface")

    if ttl_bypass_enabled; then
        if [ -n "$v4" ]; then
            log_pass "IPv4 TTL pinned to $v4 on $iface."
            if [ -n "${TTL_BYPASS_VALUE:-}" ] && [ "$v4" != "$TTL_BYPASS_VALUE" ]; then
                log_warn "Live TTL ($v4) differs from configured TTL_BYPASS_VALUE ($TTL_BYPASS_VALUE); re-run setup-multipath.sh."
            fi
        else
            fail "No IPv4 TTL rewrite rule on $iface (expected -j TTL --ttl-set $TTL_BYPASS_VALUE)."
        fi

        if command -v ip6tables >/dev/null 2>&1 && [ -d /proc/sys/net/ipv6 ]; then
            v6=$(live_rewrite_value ip6tables HL "$iface")
            if [ -n "$v6" ]; then
                log_pass "IPv6 Hop-Limit pinned to $v6 on $iface."
            else
                log_warn "No IPv6 HL rewrite rule on $iface (xt_HL module missing? IPv6 fingerprint may leak)."
            fi
        fi
    else
        if [ -n "$v4" ]; then
            log_warn "TTL_BYPASS_ENABLED=0 but a live TTL rule still exists on $iface (TTL=$v4). Re-run setup-multipath.sh to clear it."
        else
            log_info "TTL bypass disabled; no rewrite rule on $iface (as expected)."
        fi
    fi
}

check_ttl_iface "$IF1"
if [ "$HAS_SECONDARY_UPLINK" -eq 1 ]; then
    check_ttl_iface "$IF2"
fi

# 4. Connectivity Test
echo ""
echo "--- 4. Connectivity Test ---"
# Use China Mainland optimized services
TEST_URL="http://connect.rom.miui.com/generate_204"
IP_API="http://myip.ipip.net"

check_iface() {
    local iface=$1 ip_addr ext_ip

    if ! ip link show "$iface" >/dev/null 2>&1; then
        log_warn "Interface $iface does not exist. Skipping."
        return
    fi

    ip_addr=$(get_ip "$iface")
    if [ -z "$ip_addr" ]; then
        log_warn "Interface $iface has no IP address."
        return
    fi

    echo "Testing interface: $iface ($ip_addr)..."

    if curl --interface "$iface" --connect-timeout 3 --max-time 5 -s -o /dev/null "$TEST_URL"; then
        log_pass "$iface can reach Internet."

        ext_ip=$(curl --interface "$iface" --connect-timeout 5 --max-time 8 -s "$IP_API")
        if [ -n "$ext_ip" ]; then
            log_info "External IP via $iface: $ext_ip"
        else
            log_warn "Could not fetch external IP via $iface."
        fi
    else
        fail "$iface CANNOT reach Internet."
    fi
}

if command -v curl >/dev/null 2>&1; then
    check_iface "$IF1"
    if [ "$HAS_SECONDARY_UPLINK" -eq 1 ]; then
        check_iface "$IF2"
    else
        log_info "Secondary uplink disabled; skipping IF2 connectivity test."
    fi
else
    log_warn "curl not found; skipping connectivity tests."
fi

echo ""
echo "=============================================="
if [ "$FAIL_COUNT" -gt 0 ]; then
    log_fail "Verification finished with $FAIL_COUNT failure(s)."
    exit 1
fi
log_pass "Verification finished."
