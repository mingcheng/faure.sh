#!/usr/bin/env bash
# Copyright (c) 2025-2026 mingcheng <mingcheng@apache.org>
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
# Last Modified: 2026-01-14 00:42:42
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

# Ensure scripts are executable
log_info "Making scripts executable..."
chmod +x "$PROJECT_DIR"/scripts/*.sh
chmod +x "$PROJECT_DIR"/install.sh
chmod +x "$PROJECT_DIR"/verify.sh

log_info "Installing from $PROJECT_DIR..."

# --- Package Installation ---
log_info "Installing required system packages..."
if command -v apt &> /dev/null; then
    apt update
    apt install -y netplan.io iptables net-tools iproute2 procps curl wget iputils-ping dnsutils ca-certificates gnupg lsb-release
else
    log_error "apt package manager is not found. Please install required packages manually."
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
    # Create a temporary directory for modified systemd files
    TEMP_SYSTEMD=$(mktemp -d)
    cp "$PROJECT_DIR"/systemd/*.service "$TEMP_SYSTEMD"/
    cp "$PROJECT_DIR"/systemd/*.timer "$TEMP_SYSTEMD"/

    # Update paths in service files to match PROJECT_DIR
    # We use | as delimiter to avoid issues with / in paths
    sed -i "s|/root/faure.sh|$PROJECT_DIR|g" "$TEMP_SYSTEMD"/*.service

    log_info "Installing systemd services..."
    cp "$TEMP_SYSTEMD"/*.service /etc/systemd/system/
    cp "$TEMP_SYSTEMD"/*.timer /etc/systemd/system/
    chmod 644 /etc/systemd/system/*.service
    chmod 644 /etc/systemd/system/*.timer

    rm -rf "$TEMP_SYSTEMD"

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
            log_info "Enabling and starting $service..."
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
