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
# Last Modified: 2026-05-09 10:31:18
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
#     export LAN_NET="10.0.0.0/24"
#     export TPROXY_PORT="7893"
#

# Network Interfaces
export IF1="eth0"
export IF2="eth1"

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

# TProxy Settings
export TPROXY_PORT="8848"
export TPROXY_DNS_PORT="1053"
export TPROXY_TABLE="200"
export CHAIN_NAME="MIHOMO_TPROXY"

# State File
export UPLINK_STATE_FILE="/run/uplink_status"

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
