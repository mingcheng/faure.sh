#!/usr/bin/env bash
# Copyright (c) 2025-2026 mingcheng <mingcheng@apache.org>
#
# Shared configuration for faure.sh network scripts.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: config.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2026-01-14
##

# Network Interfaces
export IF1="eth0"
export IF2="eth1"

# Network Definitions
export LAN_NET="172.16.1.0/24"
export MAIN_IP="172.16.1.250"

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
