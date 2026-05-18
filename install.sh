#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
#
# Install script for faure.sh
#
# Assumes project is located at /root/faure.sh by default.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: install.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-28 16:31:58
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-05-09 10:37:14
##

set -e

# Default project path
PROJECT_DIR="${1:-/root/faure.sh}"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root"
   exit 1
fi

# Check if project directory exists
if [ ! -d "$PROJECT_DIR" ]; then
    log_error "Project directory $PROJECT_DIR not found."
    log_error "Please clone the project to $PROJECT_DIR or provide the path as an argument."
    exit 1
fi

log_info "Installing from $PROJECT_DIR..."

# --- Package Installation ---
log_info "Installing required system packages..."
if command -v apt &> /dev/null; then
    apt update
    apt install -y netplan.io iptables net-tools iproute2 procps curl wget \
        iputils-ping dnsutils ca-certificates gnupg lsb-release \
        vnstat jq util-linux
else
    log_error "apt package manager is not found. Please install required packages manually."
fi

# --- External Configuration Bootstrap ---
# Create /etc/faure/config.sh on first install so users have a single,
# upgrade-safe place to override defaults from scripts/config.sh.
log_info "Bootstrapping external configuration directory /etc/faure..."
mkdir -p /etc/faure
if [ ! -f /etc/faure/config.sh ]; then
    cat > /etc/faure/config.sh <<'EOF'
#!/usr/bin/env bash
# /etc/faure/config.sh - local overrides for faure.sh
#
# This file is sourced AFTER scripts/config.sh, so any value re-exported here
# replaces the default. It is preserved across `install.sh` re-runs.
#
# Uncomment and adjust the variables you want to override:
#
# export IF1="eth0"
# export IF2="eth1"
# # One-NIC side-router mode: uncomment to disable the secondary uplink.
# # export IF2=""
# export LAN_NET="192.168.1.0/24"
# export MAIN_IP="192.168.1.99"
# export TPROXY_PORT="8848"
#
# # Multipath weights (used in "balance" mode):
# export WEIGHT1=1
# export WEIGHT2=2
#
# # Multi-gateway egress mode (only when BOTH uplinks are UP):
# #   balance  - ECMP load balancing using WEIGHT1/WEIGHT2 (default)
# #   failover - active/standby; only $PRIMARY_IF is used while it is UP,
# #              the other uplink takes over automatically on failure.
# export MULTIPATH_MODE="balance"
# export PRIMARY_IF="IF1"   # used only when MULTIPATH_MODE=failover
#
# # Tethering / hotspot detection bypass. Rewrites the IPv4 TTL and IPv6
# # Hop-Limit of every WAN egress packet so carriers cannot fingerprint
# # forwarded (tethered) traffic by its decremented TTL. Enabled by default.
# #   TTL_BYPASS_VALUE=65 mimics a phone forwarding tethered traffic.
# #   TTL_BYPASS_VALUE=64 mimics direct phone egress.
# export TTL_BYPASS_ENABLED=1
# export TTL_BYPASS_VALUE=65
EOF
    chmod 644 /etc/faure/config.sh
    log_info "Created /etc/faure/config.sh (edit to override defaults)."
else
    log_info "/etc/faure/config.sh already exists; preserving user overrides."
fi

# --- Sysctl Configuration ---
log_info "Installing sysctl configurations..."
if [ -d "$PROJECT_DIR/sysctl.d" ]; then
    cp "$PROJECT_DIR"/sysctl.d/*.conf /etc/sysctl.d/
    chmod 644 /etc/sysctl.d/*.conf
else
    log_error "sysctl.d directory not found in $PROJECT_DIR"
fi

# --- Systemd Configuration ---
log_info "Installing systemd services..."
if [ -d "$PROJECT_DIR/systemd" ]; then
    cp "$PROJECT_DIR"/systemd/*.service /etc/systemd/system/
    cp "$PROJECT_DIR"/systemd/*.timer /etc/systemd/system/
    chmod 644 /etc/systemd/system/*.service
    chmod 644 /etc/systemd/system/*.timer

    log_info "Reloading systemd daemon..."
    systemctl daemon-reload

    # Enable and start services
    SERVICES=(
        # "monitor-uplink.service"
        "monitor-uplink.timer"
        "multipath-routing.service"
        "tproxy-routing.service"
    )

    for service in "${SERVICES[@]}"; do
        if [ -f "/etc/systemd/system/$service" ]; then
            log_info "Enabling $service..."
            systemctl enable "$service"
        else
          log_error "Service file $service not found in /etc/systemd/system/"
        fi
    done
else
    log_error "systemd directory not found in $PROJECT_DIR"
fi

# --- Scripts Permissions ---
log_info "Setting executable permissions for scripts..."
if [ -d "$PROJECT_DIR/scripts" ]; then
    chmod +x "$PROJECT_DIR"/scripts/*.sh
fi

log_info "Installation completed successfully."
log_info ""
log_info "Next steps:"
log_info "  1. Review and edit /etc/faure/config.sh to match your environment."
log_info "  2. Configure netplan in /etc/netplan/ and run: netplan apply"
log_info "  3. Start services manually for the first time:"
log_info "       systemctl start multipath-routing.service"
log_info "       systemctl start tproxy-routing.service"
log_info "       systemctl start monitor-uplink.timer"
log_info "  4. Verify the setup:"
log_info "       sudo $PROJECT_DIR/scripts/verify-network.sh"
log_info "       sudo $PROJECT_DIR/scripts/verify-kernel.sh"
