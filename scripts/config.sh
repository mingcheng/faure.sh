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
# Last Modified: 2026-05-09 16:54:21
#
# This file ships with sane defaults. To override any value WITHOUT editing
# this file (recommended for upgrade-friendly deployments), drop a shell
# fragment at one of the following locations - the first existing one wins:
#
#   1. The path in the FAURE_CONFIG environment variable
#   2. /etc/faure/config.sh                (preferred system-wide override)
#   3. /etc/default/faure                  (Debian-style alternative)
#
# The override file is sourced AFTER the defaults below, so it only needs to
# redefine the variables you want to change, e.g.:
#
#     # /etc/faure/config.sh
#     export IF1="enp1s0"
#     export IF2="enx001122334455"
#     # For a one-NIC side-router, disable the secondary uplink with:
#     # export IF2=""
#     export LAN_NET="10.0.0.0/24"
#     export TPROXY_PORT="7893"
#

# Network Interfaces
export IF1="eth0"
export IF2="eth1"

# LAN-facing interface for TProxy (clients reach the gateway via this NIC).
# Defaults to $IF1 so overriding IF1 cascades; can still be overridden
# independently via env var or override file.
export LAN_IF="${LAN_IF:-$IF1}"

# Network Definitions
export LAN_NET="192.168.1.0/24"
export MAIN_IP="192.168.1.99"

# Routing Tables
export TABLE1="100"
export TABLE2="101"

# Routing Properties
export PRIO_MARK1="90"
export PRIO_MARK2="91"
export PRIO_TPROXY="99"
export PRIO_SRC1="100"
export PRIO_SRC2="101"

# Firewall Marks
export MARK1="0x100"
export MARK2="0x200"
export TPROXY_MARK="0x1"

# Weights for Multipath
export WEIGHT1=1
export WEIGHT2=1
# Multipath egress mode (only meaningful when BOTH uplinks are UP; otherwise
# the single available uplink is used and these settings are ignored):
#   "balance"  - ECMP load balancing across both uplinks using WEIGHT1/WEIGHT2
#                (round-robin by flow, weighted by the values above).
#   "failover" - Active/standby. Only $PRIMARY_IF carries traffic while it is
#                UP; the other uplink takes over automatically when the
#                primary fails (handled by monitor-uplink restarting setup).
export MULTIPATH_MODE="balance"
# Which logical interface is primary in "failover" mode: "IF1" or "IF2".
export PRIMARY_IF="IF1"
# TProxy Settings
export TPROXY_PORT="8848"
# Local DNS port that mihomo/clash listens on. The original setup REDIRECTed
# LAN DNS traffic to port 53, so 53 is the safe default. Override to e.g.
# 1053 only if mihomo is configured to bind a non-privileged port.
export TPROXY_DNS_PORT="53"
export TPROXY_TABLE="200"
export CHAIN_NAME="MIHOMO_TPROXY"

# State File
export UPLINK_STATE_FILE="/run/uplink_status"

# Optional gateway fallback when DHCP/route detection fails on IF1.
# Leave empty to disable the fallback. Used only by utils.sh::get_gateway().
export IF1_GW_FALLBACK="${IF1_GW_FALLBACK:-172.16.1.1}"

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
