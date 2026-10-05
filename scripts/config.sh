#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: config.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2026-01-14 22:29:32
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-10-05 10:00:00
#
# This file ships with sane defaults. To override any value WITHOUT editing
# this file (recommended for upgrade-friendly deployments), drop a shell
# fragment at one of the following locations - the first existing one wins:
#
#   1. The path in the FAURE_CONFIG environment variable
#   2. /etc/faure/config.sh                (preferred system-wide override)
#   3. /etc/default/faure                  (Debian-style alternative)
#
# Precedence (highest first): override file > environment > defaults below.
# The override file only needs to redefine the variables you want to change:
#
#     # /etc/faure/config.sh
#     export IF1="enp1s0"
#     export IF2="enx001122334455"
#     # For a one-NIC side-router, disable the secondary uplink with:
#     # export IF2=""
#     export LAN_NET="10.0.0.0/24"
#     export TPROXY_PORT="7893"
#

# Network Interfaces. IF2 uses `-` (not `:-`) so an explicitly empty IF2
# from the environment keeps one-NIC mode instead of falling back to eth1.
export IF1="${IF1:-eth0}"
export IF2="${IF2-eth1}"

# LAN network served by this gateway (TProxy + multipath LAN bypass).
# LAN_IF defaults to $IF1 and is resolved at the end of this file so that an
# override of IF1 also cascades to LAN_IF.
export LAN_NET="${LAN_NET:-192.168.1.0/24}"

# Routing Tables
export TABLE1="${TABLE1:-100}"
export TABLE2="${TABLE2:-101}"

# Policy routing rule priorities
export PRIO_MARK1="${PRIO_MARK1:-90}"
export PRIO_MARK2="${PRIO_MARK2:-91}"
export PRIO_TPROXY="${PRIO_TPROXY:-99}"
export PRIO_SRC1="${PRIO_SRC1:-100}"
export PRIO_SRC2="${PRIO_SRC2:-101}"

# Firewall Marks
export MARK1="${MARK1:-0x100}"
export MARK2="${MARK2:-0x200}"
export TPROXY_MARK="${TPROXY_MARK:-0x1}"

# Weights for Multipath
export WEIGHT1="${WEIGHT1:-1}"
export WEIGHT2="${WEIGHT2:-1}"
# Multipath egress mode (only meaningful when BOTH uplinks are UP; otherwise
# the single available uplink is used and these settings are ignored):
#   "balance"  - ECMP load balancing across both uplinks using WEIGHT1/WEIGHT2
#                (hashed per flow, weighted by the values above).
#   "failover" - Active/standby. Only $PRIMARY_IF carries traffic while it is
#                UP; the other uplink takes over automatically when the
#                primary fails (handled by monitor-uplink restarting setup).
export MULTIPATH_MODE="${MULTIPATH_MODE:-balance}"
# Which logical interface is primary in "failover" mode: "IF1" or "IF2".
export PRIMARY_IF="${PRIMARY_IF:-IF1}"

# TProxy Settings
export TPROXY_PORT="${TPROXY_PORT:-8848}"
# Local DNS port that mihomo/clash listens on; LAN DNS (port 53) is
# REDIRECTed here. Override to e.g. 1053 only if mihomo binds that port.
export TPROXY_DNS_PORT="${TPROXY_DNS_PORT:-53}"
export TPROXY_TABLE="${TPROXY_TABLE:-200}"
export CHAIN_NAME="${CHAIN_NAME:-MIHOMO_TPROXY}"
# How long setup-tproxy.sh waits for the Mihomo listeners (seconds). Mihomo
# may need 60s+ to fetch rule providers on a cold start. Keep the timeout
# below TimeoutStartSec in systemd/tproxy-routing.service (360s).
export TPROXY_WAIT_TIMEOUT="${TPROXY_WAIT_TIMEOUT:-300}"
export TPROXY_WAIT_INTERVAL="${TPROXY_WAIT_INTERVAL:-2}"

# State File
export UPLINK_STATE_FILE="${UPLINK_STATE_FILE:-/run/uplink_status}"

# ---------------------------------------------------------------------------
# Tethering / Hotspot detection bypass (TTL / Hop-Limit normalization)
# ---------------------------------------------------------------------------
# Many carriers (and some domestic plans) throttle or meter "tethered" traffic
# separately by inspecting the IPv4 TTL / IPv6 Hop-Limit of packets leaving
# the handset: a phone's own traffic egresses at the OS default (Android 64,
# iOS 64, ...), while tethered downstream devices appear with TTL = default-1
# because the phone forwarded (and decremented) the packet.
#
# When this router sits behind such an uplink (e.g. USB tethering on $IF2),
# its forwarded packets reach the carrier with TTL = default-2, which is a
# trivial fingerprint. We neutralize this by rewriting the TTL / Hop-Limit on
# every WAN egress to a fixed value at mangle POSTROUTING (after the kernel's
# normal decrement), so packets leave the router as if they originated from a
# phone.
#
#   TTL_BYPASS_ENABLED  - 1 = apply on all active uplinks (default), 0 = off.
#   TTL_BYPASS_VALUE    - integer 1..255. 65 mimics Android tether egress
#                         (handset default 64 + 1, since the carrier expects
#                         TTL to have already been decremented once by the
#                         phone's forwarding path). 64 mimics direct egress.
export TTL_BYPASS_ENABLED="${TTL_BYPASS_ENABLED:-1}"
export TTL_BYPASS_VALUE="${TTL_BYPASS_VALUE:-65}"

# Optional gateway fallback when DHCP/route detection fails on IF1.
# Leave empty to disable the fallback. Used only by utils.sh::get_gateway().
export IF1_GW_FALLBACK="${IF1_GW_FALLBACK-172.16.1.1}"

# ---------------------------------------------------------------------------
# External overrides (do NOT edit below)
# ---------------------------------------------------------------------------
# Sourcing happens here so user-supplied files can change any default above.
for _faure_override in "${FAURE_CONFIG:-}" /etc/faure/config.sh /etc/default/faure; do
    if [ -n "$_faure_override" ] && [ -f "$_faure_override" ]; then
        # shellcheck disable=SC1090
        source "$_faure_override"
        export FAURE_CONFIG_LOADED="$_faure_override"
        break
    fi
done
unset _faure_override

# Resolved after overrides so a custom IF1 also becomes the default LAN_IF.
export LAN_IF="${LAN_IF:-$IF1}"
