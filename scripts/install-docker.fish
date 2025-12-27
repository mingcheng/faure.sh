#!/usr/bin/env fish
# Copyright (c) 2025 Hangzhou Guanwaii Technology Co., Ltd.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: install_docker.fish
# Author: mingcheng (mingcheng@apache.org)
# File Created: 2025-03-20 11:44:32
#
# Modified By: mingcheng (mingcheng@apache.org)
# Last Modified: 2025-10-01 22:46:42
##

# Colors for output
set -l RED '\033[0;31m'
set -l GREEN '\033[0;32m'
set -l YELLOW '\033[1;33m'
set -l NC '\033[0m' # No Color

# Function to print colored messages
function print_info
    echo -e "$GREEN[INFO]$NC $argv"
end

function print_warn
    echo -e "$YELLOW[WARN]$NC $argv"
end

function print_error
    echo -e "$RED[ERROR]$NC $argv"
end

# Function to handle errors
function handle_error
    print_error "$argv"
    exit 1
end

# Check if running as root
if test (id -u) -ne 0
    handle_error "Please run this script as root or with sudo"
end

# Check if running on Linux
if test (uname -s | string lower) != linux
    handle_error "This script only supports Linux systems"
end

# Check if the system is Debian-based
if not test -f /etc/debian_version
    handle_error "This script is designed for Debian-based systems only"
end

print_info "Starting Docker installation on Debian-based system..."

# Check if Docker is already installed
if command -v docker &>/dev/null
    print_warn "Docker is already installed. Version: "(docker --version)
    read -P "Do you want to reinstall Docker? [y/N]: " -l choice
    if test "$choice" != y -a "$choice" != Y
        print_info "Installation cancelled by user"
        exit 0
    end
end

# Remove old Docker packages if they exist
print_info "Removing old Docker packages (if any)..."
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc
    if dpkg -l | grep -q "^ii.*$pkg"
        print_info "Removing package: $pkg"
        apt-get remove -y $pkg
    end
end

print_info "Updating package database..."
apt update || handle_error "Failed to update package database"

print_info "Installing required packages..."
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release || handle_error "Failed to install required packages"

# Create directory for keyrings
print_info "Setting up Docker GPG key..."
install -m 0755 -d /etc/apt/keyrings || handle_error "Failed to create keyrings directory"

# Download Docker's GPG key (using Aliyun mirror for better speed in China)
curl -fsSL https://mirrors.aliyun.com/docker-ce/linux/debian/gpg -o /etc/apt/keyrings/docker.asc || handle_error "Failed to download Docker GPG key"
chmod a+r /etc/apt/keyrings/docker.asc || handle_error "Failed to set permissions on GPG key"

# Get system architecture and codename
set -l arch (dpkg --print-architecture)
set -l codename (lsb_release -cs)

print_info "Adding Docker repository for architecture: $arch, codename: $codename"

# Add Docker repository to sources
echo "deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://mirrors.aliyun.com/docker-ce/linux/debian $codename stable" | tee /etc/apt/sources.list.d/docker.list >/dev/null || handle_error "Failed to add Docker repository"

print_info "Updating package database with Docker repository..."
apt update || handle_error "Failed to update package database after adding Docker repository"

print_info "Installing Docker packages..."
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || handle_error "Failed to install Docker packages"

print_info "Starting and enabling Docker service..."
systemctl enable --now docker || handle_error "Failed to start Docker service"

# Add current user to docker group if not root
if test "$SUDO_USER" != ""
    print_info "Adding user $SUDO_USER to docker group..."
    usermod -aG docker $SUDO_USER || print_warn "Failed to add user to docker group"
    print_info "Please log out and log back in for group changes to take effect"
end

print_info "Cleaning up..."
apt autoremove -y >/dev/null 2>&1

# Verify installation
print_info "Verifying Docker installation..."
if docker --version >/dev/null 2>&1
    print_info "Docker installed successfully!"
    print_info "Docker version: "(docker --version)
    print_info "Docker Compose version: "(docker compose version)

    # Test Docker with hello-world
    print_info "Running Docker hello-world test..."
    if docker run --rm hello-world >/dev/null 2>&1
        print_info "Docker is working correctly!"
    else
        print_warn "Docker test failed, but installation appears complete"
    end
else
    handle_error "Docker installation verification failed"
end

print_info "Docker installation completed successfully!"
print_info "You can now use Docker and Docker Compose commands"
