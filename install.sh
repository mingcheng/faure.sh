#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
#
# Install script for faure.sh
#
# Usage: sudo ./install.sh [project_dir]
# project_dir defaults to the directory containing this script; systemd unit
# paths are rewritten to match it.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: install.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-28 16:31:58
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-10-28 17:34:53
##

# Exit immediately if a command exits with a non-zero status, if an undefined variable is used, or if any command in a pipeline fails.
set -o errexit -o nounset -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/scripts" && pwd)"
# shellcheck source=scripts/utils.sh
source "$SCRIPT_DIR/utils.sh"

render_systemd_unit() {
    local path=$1 replacement
    # ExecStart is quoted in the units; escape systemd syntax before sed.
    path=${path//\\/\\\\}
    path=${path//\"/\\\"}
    path=${path//%/%%}
    # Unlike argv, the executable path does not undergo $ expansion.
    replacement=$(printf '%s' "$path" | sed 's/[\\&|]/\\&/g')
    sed "s|/root/faure\\.sh|$replacement|g" "$2"
}

main() {
    local PROJECT_DIR="${1:-$(dirname "${BASH_SOURCE[0]}")}"
    local path unit dest service cmd
    local -a SERVICES=(
        "monitor-uplink.timer"
        "multipath-routing.service"
        "tproxy-routing.service"
    )

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        return 1
    fi

    if [ "$(uname -s)" != Linux ]; then
        log_error "This installer requires a Debian/Ubuntu Linux system with systemd."
        return 1
    fi
    for cmd in apt-get systemctl; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Required command '$cmd' was not found; nothing has been installed."
            return 1
        fi
    done
    if ! systemctl show-environment >/dev/null; then
        log_error "Cannot contact systemd; nothing has been installed."
        return 1
    fi

    if [ ! -d "$PROJECT_DIR" ]; then
        log_error "Project directory $PROJECT_DIR not found."
        log_error "Please clone the project first or provide its path as an argument."
        return 1
    fi
    PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
    if [[ $PROJECT_DIR == *$'\n'* || $PROJECT_DIR == *$'\r'* ]]; then
        log_error "The project path must not contain newline characters."
        return 1
    fi

    for path in \
        "$PROJECT_DIR"/sysctl.d/*.conf \
        "$PROJECT_DIR"/modules-load.d/*.conf \
        "$PROJECT_DIR"/scripts/{config,utils,setup-multipath,setup-tproxy,monitor-uplink}.sh \
        "$PROJECT_DIR"/systemd/monitor-uplink.service; do
        if [ ! -f "$path" ]; then
            log_error "Required project file not found: $path"
            return 1
        fi
    done
    for service in "${SERVICES[@]}"; do
        if [ ! -f "$PROJECT_DIR/systemd/$service" ]; then
            log_error "Required systemd unit not found: $service"
            return 1
        fi
    done

    log_info "Installing from $PROJECT_DIR..."

    # --- Package Installation ---
    log_info "Installing required system packages..."
    apt-get update
    apt-get install -y netplan.io iptables iproute2 procps curl wget \
        iputils-ping dnsutils ca-certificates gnupg lsb-release \
        vnstat jq util-linux

    # --- External Configuration Bootstrap ---
    # Create /etc/faure/config.sh on first install so users have a single,
    # upgrade-safe place to override defaults from scripts/config.sh.
    log_info "Bootstrapping external configuration directory /etc/faure..."
    mkdir -p /etc/faure
    if [ ! -f /etc/faure/config.sh ]; then
        cat >/etc/faure/config.sh <<'EOF'
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
# export LAN_IF="eth0"      # defaults to $IF1
# export LAN_NET="192.168.1.0/24"
# export TPROXY_PORT="8848"
# export TPROXY_DNS_PORT="53"
# # Both ports must have TCP and UDP listeners before rules are installed.
# export TPROXY_WAIT_TIMEOUT=300   # keep below TimeoutStartSec (360s)
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
#
# # Last-resort gateway for IF1 when route detection fails ("" disables).
# export IF1_GW_FALLBACK="172.16.1.1"
#
# # Advanced: change only if they clash with other routing/firewall setups.
# export TABLE1=100 TABLE2=101 TPROXY_TABLE=200
# export MARK1=0x100 MARK2=0x200 TPROXY_MARK=0x1
# export PRIO_MARK1=90 PRIO_MARK2=91 PRIO_TPROXY=99 PRIO_SRC1=100 PRIO_SRC2=101
# export CHAIN_NAME="MIHOMO_TPROXY"
# export TPROXY_WAIT_INTERVAL=2
# export UPLINK_STATE_FILE="/run/uplink_status"
EOF
        chmod 644 /etc/faure/config.sh
        log_info "Created /etc/faure/config.sh (edit to override defaults)."
    else
        log_info "/etc/faure/config.sh already exists; preserving user overrides."
    fi

    # --- Sysctl Configuration ---
    log_info "Installing sysctl configurations..."
    install -m 0644 -D -t /etc/sysctl.d/ "$PROJECT_DIR"/sysctl.d/*.conf

    # Modules that must be loaded before systemd-sysctl applies the files above.
    log_info "Installing modules-load.d configuration..."
    install -m 0644 -D -t /etc/modules-load.d/ "$PROJECT_DIR"/modules-load.d/*.conf

    # --- Systemd Configuration ---
    log_info "Installing systemd services..."
    for unit in "$PROJECT_DIR"/systemd/*.service "$PROJECT_DIR"/systemd/*.timer; do
        [ -f "$unit" ] || continue
        dest="/etc/systemd/system/$(basename "$unit")"
        render_systemd_unit "$PROJECT_DIR" "$unit" >"$dest"
        chmod 644 "$dest"
    done

    log_info "Reloading systemd daemon..."
    systemctl daemon-reload

    # monitor-uplink.service is driven by its timer, so it is not enabled.
    for service in "${SERVICES[@]}"; do
        log_info "Enabling $service..."
        systemctl enable "$service"
    done

    # --- Scripts Permissions ---
    log_info "Setting executable permissions for scripts..."
    chmod +x "$PROJECT_DIR"/scripts/*.sh

    log_info "Installation completed successfully."
    log_info ""
    log_info "Next steps:"
    log_info "  1. Review and edit /etc/faure/config.sh to match your environment."
    log_info "  2. Configure netplan in /etc/netplan/ and run: netplan apply"
    log_info "  3. Apply kernel settings (or reboot):"
    log_info "       systemctl restart systemd-modules-load.service"
    log_info "       sysctl --system"
    log_info "  4. Start services manually for the first time:"
    log_info "       systemctl start multipath-routing.service"
    log_info "       systemctl start tproxy-routing.service"
    log_info "       systemctl start monitor-uplink.timer"
    log_info "  5. Verify the setup:"
    log_info "       sudo $PROJECT_DIR/scripts/verify-network.sh"
    log_info "       sudo $PROJECT_DIR/scripts/verify-kernel.sh"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
