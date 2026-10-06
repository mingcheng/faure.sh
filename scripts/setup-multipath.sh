#!/usr/bin/env bash
# Copyright (c) 2025 mingcheng <mingcheng@apache.org>
#
# Setup multipath routing for load balancing between two interfaces
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: setup-multipath.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-27 23:13:18
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-10-06 19:30:00
##

set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"

log_info "Configuring multipath routing..."

# IF2 is "configured" when set and distinct from IF1; it is only *used* when
# it also has an IPv4 address (see secondary_uplink_enabled).
IF2_CONFIGURED=0
CONFIGURED_UPLINKS=("$IF1")
if secondary_uplink_configured; then
    IF2_CONFIGURED=1
    CONFIGURED_UPLINKS+=("$IF2")
fi

# Wait up to 60s for DHCP so a slow boot does not abort the setup.
wait_for_ip 30 2 "${CONFIGURED_UPLINKS[@]}" || true

# --- Uplink discovery ------------------------------------------------------
HAS_IF1=0
HAS_IF2=0
IP1=$(get_ip "$IF1")
IP2=""

if [ -n "$IP1" ]; then
    log_info "$IF1 IP: $IP1"
    HAS_IF1=1
else
    log_warn "No IP for $IF1. Skipping $IF1 configuration."
fi

if secondary_uplink_enabled; then
    IP2=$(get_ip "$IF2")
    log_info "$IF2 IP: $IP2"
    HAS_IF2=1
elif [ "$IF2_CONFIGURED" -eq 1 ]; then
    log_warn "No IP for $IF2. Running in single-uplink mode."
else
    log_info "Single-uplink mode: secondary uplink is disabled."
fi

if [ "$HAS_IF1" -eq 0 ] && [ "$HAS_IF2" -eq 0 ]; then
    log_error "No uplink has an IPv4 address. Exiting."
    exit 1
fi

SUBNET1=""
SUBNET2=""
GW1=""
GW2=""
if [ "$HAS_IF1" -eq 1 ]; then
    SUBNET1=$(get_subnet "$IF1")
    GW1=$(get_gateway "$IF1" "$TABLE1")
    if [ -n "$GW1" ]; then
        log_info "$IF1 subnet: ${SUBNET1:-?}, gateway: $GW1"
    else
        log_error "No gateway for $IF1"
        HAS_IF1=0
    fi
fi
if [ "$HAS_IF2" -eq 1 ]; then
    SUBNET2=$(get_subnet "$IF2")
    GW2=$(get_gateway "$IF2" "$TABLE2")
    if [ -n "$GW2" ]; then
        log_info "$IF2 subnet: ${SUBNET2:-?}, gateway: $GW2"
    else
        log_error "No gateway for $IF2"
        HAS_IF2=0
    fi
fi

# --- Connectivity check ----------------------------------------------------
# An uplink that fails the probe keeps its own table/rules (so it stays
# reachable for debugging) but is excluded from the main default route.
IF1_UP=0
IF2_UP=0
if [ "$HAS_IF1" -eq 1 ]; then
    log_info "Verifying connectivity for $IF1 via $GW1..."
    if check_connectivity "$IF1" "$GW1"; then
        log_info "$IF1 is UP"
        IF1_UP=1
    else
        log_warn "$IF1 failed connectivity check; excluding it from the default route."
    fi
fi
if [ "$HAS_IF2" -eq 1 ]; then
    log_info "Verifying connectivity for $IF2 via $GW2..."
    if check_connectivity "$IF2" "$GW2"; then
        log_info "$IF2 is UP"
        IF2_UP=1
    else
        log_warn "$IF2 failed connectivity check; excluding it from the default route."
    fi
fi

# --- Per-uplink routing tables ---------------------------------------------
log_info "Flushing old routing tables..."
ip route flush table "$TABLE1" 2>/dev/null || true
ip route flush table "$TABLE2" 2>/dev/null || true

# Each table holds the on-link subnets (so local peers stay reachable) plus a
# default route via its own uplink; src pins the correct source address.
if [ "$HAS_IF1" -eq 1 ]; then
    log_info "Configuring route table $TABLE1..."
    [ -n "$SUBNET1" ] && ip route replace "$SUBNET1" dev "$IF1" src "$IP1" table "$TABLE1"
    [ -n "$SUBNET2" ] && { ip route replace "$SUBNET2" dev "$IF2" table "$TABLE1" 2>/dev/null || true; }
    ip route replace default via "$GW1" dev "$IF1" src "$IP1" table "$TABLE1"
fi
if [ "$HAS_IF2" -eq 1 ]; then
    log_info "Configuring route table $TABLE2..."
    [ -n "$SUBNET1" ] && { ip route replace "$SUBNET1" dev "$IF1" table "$TABLE2" 2>/dev/null || true; }
    [ -n "$SUBNET2" ] && ip route replace "$SUBNET2" dev "$IF2" src "$IP2" table "$TABLE2"
    ip route replace default via "$GW2" dev "$IF2" src "$IP2" table "$TABLE2"
fi

# --- Source-based policy rules ---------------------------------------------
log_info "Refreshing source policy rules..."
# Delete by priority so a changed IP never leaves a stale rule behind.
while ip rule del priority "$PRIO_SRC1" 2>/dev/null; do :; done
while ip rule del priority "$PRIO_SRC2" 2>/dev/null; do :; done

if [ "$HAS_IF1" -eq 1 ]; then
    ip rule add from "$IP1" table "$TABLE1" priority "$PRIO_SRC1"
fi
if [ "$HAS_IF2" -eq 1 ]; then
    ip rule add from "$IP2" table "$TABLE2" priority "$PRIO_SRC2"
    # Anything sourced from the $IF2 subnet must also leave via $IF2.
    if [ -n "$SUBNET2" ]; then
        ip rule add from "$SUBNET2" table "$TABLE2" priority "$PRIO_SRC2"
    fi
fi

# --- Connection marking (Docker/NAT compatible) ----------------------------
log_info "Configuring connection marking..."
iptables -t mangle -N MULTIPATH_MARK 2>/dev/null || true
iptables -t mangle -F MULTIPATH_MARK
iptables -t mangle -A MULTIPATH_MARK -j CONNMARK --restore-mark

# Bypass LAN-sourced traffic FIRST so it never gets stamped with a WAN mark.
# Critical when LAN_IF is also a WAN uplink (one-NIC / shared NIC): otherwise
# LAN client traffic would be tagged and force-routed via that uplink's
# table, breaking forwarding/failover when that uplink is down.
iptables -t mangle -A MULTIPATH_MARK -i "$LAN_IF" -s "$LAN_NET" -j RETURN

# Mark NEW connections arriving on each WAN uplink so replies leave through
# the same uplink (via the fwmark rules below).
if [ "$HAS_IF1" -eq 1 ]; then
    iptables -t mangle -A MULTIPATH_MARK -i "$IF1" -m conntrack --ctstate NEW -j MARK --set-mark "$MARK1"
fi
if [ "$HAS_IF2" -eq 1 ]; then
    iptables -t mangle -A MULTIPATH_MARK -i "$IF2" -m conntrack --ctstate NEW -j MARK --set-mark "$MARK2"
fi
iptables -t mangle -A MULTIPATH_MARK -m mark ! --mark 0 -j CONNMARK --save-mark
# WAN-originated flows are done here; ACCEPT also keeps them out of TProxy.
iptables -t mangle -A MULTIPATH_MARK -m mark --mark "$MARK1" -j ACCEPT
if [ "$HAS_IF2" -eq 1 ]; then
    iptables -t mangle -A MULTIPATH_MARK -m mark --mark "$MARK2" -j ACCEPT
fi

while iptables -t mangle -D PREROUTING -j MULTIPATH_MARK 2>/dev/null; do :; done
iptables -t mangle -I PREROUTING 1 -j MULTIPATH_MARK

# Restore the connmark for locally generated packets too, so the router's own
# replies to WAN-inbound connections leave via the uplink they arrived on
# (otherwise upstream RPF may drop them).
while iptables -t mangle -D OUTPUT -j CONNMARK --restore-mark 2>/dev/null; do :; done
iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark

while ip rule del priority "$PRIO_MARK1" 2>/dev/null; do :; done
while ip rule del priority "$PRIO_MARK2" 2>/dev/null; do :; done
ip rule add fwmark "$MARK1" table "$TABLE1" priority "$PRIO_MARK1"
if [ "$HAS_IF2" -eq 1 ]; then
    ip rule add fwmark "$MARK2" table "$TABLE2" priority "$PRIO_MARK2"
fi

# --- Main routing table ----------------------------------------------------
log_info "Updating main routing table..."
# Only remove default routes that egress through $IF1 / $IF2 (directly or as
# a multipath nexthop); defaults via unmanaged NICs are preserved on purpose.
MANAGED_RE="${IF1//./\\.}"
[ "$IF2_CONFIGURED" -eq 1 ] && MANAGED_RE+="|${IF2//./\\.}"
MANAGED_DEV_RE="(^|[[:space:]])dev[[:space:]]+(${MANAGED_RE})([[:space:]]|$)"
METRIC_RE="metric[[:space:]]+([0-9]+)"
DEV_RE="dev[[:space:]]+([^[:space:]]+)"

# `ip -o` folds multipath nexthops onto one line. Delete by a minimal
# selector (prefix + dev + metric) since the full line is not valid input.
while IFS= read -r route; do
    [[ $route =~ $MANAGED_DEV_RE ]] || continue
    del_spec=(default)
    if [[ $route != *nexthop* && $route =~ $DEV_RE ]]; then
        del_spec+=(dev "${BASH_REMATCH[1]}")
    fi
    if [[ $route =~ $METRIC_RE ]]; then
        del_spec+=(metric "${BASH_REMATCH[1]}")
    fi
    ip route del "${del_spec[@]}" 2>/dev/null || true
done < <(ip -o -4 route show default 2>/dev/null || true)

# Host routes to the gateways, required by the nexthop entries below.
if [ "$HAS_IF1" -eq 1 ]; then
    ip route replace "$GW1" dev "$IF1" 2>/dev/null || true
fi
if [ "$HAS_IF2" -eq 1 ]; then
    ip route replace "$GW2" dev "$IF2" 2>/dev/null || true
fi

# MULTIPATH_MODE only matters when BOTH uplinks are UP; otherwise the lone
# healthy uplink is used. `replace` keeps re-runs idempotent.
MODE="${MULTIPATH_MODE:-balance}"
log_info "Installing default route (mode: $MODE)..."
if [ "$IF1_UP" -eq 1 ] && [ "$IF2_UP" -eq 1 ]; then
    case "$MODE" in
        failover)
            if [ "${PRIMARY_IF:-IF1}" = "IF2" ]; then
                log_info "Failover mode: primary=$IF2 (backup=$IF1)"
                ip route replace default via "$GW2" dev "$IF2" src "$IP2"
            else
                log_info "Failover mode: primary=$IF1 (backup=$IF2)"
                ip route replace default via "$GW1" dev "$IF1" src "$IP1"
            fi
            ;;
        *)
            if [ "$MODE" != "balance" ]; then
                log_warn "Unknown MULTIPATH_MODE='$MODE', falling back to balance."
            fi
            ip route replace default scope global \
                nexthop via "$GW1" dev "$IF1" weight "$WEIGHT1" \
                nexthop via "$GW2" dev "$IF2" weight "$WEIGHT2"
            ;;
    esac
elif [ "$IF1_UP" -eq 1 ]; then
    ip route replace default via "$GW1" dev "$IF1" src "$IP1"
elif [ "$IF2_UP" -eq 1 ]; then
    ip route replace default via "$GW2" dev "$IF2" src "$IP2"
elif [ "$HAS_IF1" -eq 1 ]; then
    # Probes can fail for reasons unrelated to the uplink (e.g. ICMP and the
    # probe targets both filtered); keep a route rather than black-holing.
    log_warn "No uplink passed the connectivity check; keeping default route via $IF1."
    ip route replace default via "$GW1" dev "$IF1" src "$IP1"
elif [ "$HAS_IF2" -eq 1 ]; then
    log_warn "No uplink passed the connectivity check; keeping default route via $IF2."
    ip route replace default via "$GW2" dev "$IF2" src "$IP2"
fi

sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || log_warn "Failed to enable IP forwarding via sysctl"

# --- NAT ---------------------------------------------------------------------
# Covers every configured uplink (not just the active ones) so a secondary
# uplink that comes back between monitor runs is masqueraded right away.
log_info "Configuring NAT..."
for iface in "${CONFIGURED_UPLINKS[@]}"; do
    while iptables -t nat -D POSTROUTING -o "$iface" -j MASQUERADE 2>/dev/null; do :; done
    iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
done

# --- Tethering / hotspot detection bypass ----------------------------------
# Re-applied on every run so TTL_BYPASS_* changes take effect on the next
# setup/monitor cycle; inactive uplinks are included so disabling the
# feature also clears them.
log_info "Applying TTL/Hop-Limit bypass on configured uplinks..."
for iface in "${CONFIGURED_UPLINKS[@]}"; do
    apply_ttl_bypass "$iface"
done

log_info "Multipath routing configured successfully"

# Persist the uplink state so monitor-uplink.sh can detect transitions.
if [ -n "${UPLINK_STATE_FILE:-}" ]; then
    uplink_state "$IF1_UP" "$IF2_UP" >"$UPLINK_STATE_FILE"
    log_info "Updated uplink state to: $(cat "$UPLINK_STATE_FILE")"
fi
