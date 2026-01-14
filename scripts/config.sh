#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
#
# Configuration variables for faure.sh scripts
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: config.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2026-01-14 11:42:22
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-01-14 11:47:31
##.

# --- Network Interfaces ---
# Primary interface (usually internal/static)
IF1="eth0"
# Secondary interface (usually external/dynamic/USB)
IF2="eth1"

# --- Network Subnets ---
# The LAN network that should not be load balanced (or handled specially)
LAN_NET="172.16.1.0/24"

# --- Routing Tables ---
# Table IDs for policy routing
TABLE1="100"
TABLE2="101"
TPROXY_TABLE="200"

# --- TProxy Configuration ---
# Variables used by setup-tproxy.sh
# (If these are not set here, setup-tproxy.sh uses its own defaults,
# but setting them here ensures consistency)
export FAURE_ADDR_RANGE="$LAN_NET"
export FAURE_INTERFACE="$IF1"
export FAURE_TPORT="8848"

# --- Monitoring ---
# Files used for state tracking
STATE_FILE="/run/uplink_status"

# Connectivity check targets
CONNECTIVITY_TARGETS=("223.5.5.5" "119.29.29.29" "1.1.1.1" "8.8.8.8")
