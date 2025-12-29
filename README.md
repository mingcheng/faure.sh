# Faure.sh 

__Transparent Gateway & Dual-WAN Load Balancing Suite__

`faure.sh` is a configuration suite designed for Debian/Ubuntu systems to deploy a transparent gateway. It simplifies the setup of Dual-WAN load balancing, Transparent Proxy (TProxy), network optimization, and related services.

![Architecture](./assets/route-arch.png)

## 📖 Introduction

`faure.sh` configures a Debian server (or VM) to act as a core gateway and transparent proxy, making it ideal for home or small office networks.

**Core Features:**

*   **Dual-WAN Load Balancing (Multipath Routing):** Automatically detects and utilizes two uplink interfaces (e.g., `eth0` and `eth1`) for bandwidth aggregation and failover.
*   **Transparent Proxy (TProxy):** Implements full-network transparent proxying and traffic routing based on `iptables` and `sing-box`/`mihomo`, with UDP forwarding support.
*   **Network Optimization:** Automatically configures BBR congestion control and tunes kernel parameters (sysctl) to enhance network throughput and concurrency.
*   **Traffic Monitoring & Limiting:** Includes scripts to monitor monthly traffic on specific interfaces, triggering alerts or blocking access when thresholds are reached to prevent overage charges.
*   **Service Integration:** Provides Docker Compose templates for one-click deployment of common network services like AdGuard Home (DNS) and iPerf3.

## 🏗️ Architecture

As illustrated in the diagram, the system is typically deployed on bare metal or within a virtual environment (e.g., Proxmox VE, ESXi, or bhyve on FreeBSD). Key components include:

*   **Debian Router:** The core gateway that runs the scripts and services provided by this project.
*   **Interfaces:**
    *   `eth0` (WAN1/LAN): Connects to the internal switch or main router, serving as the LAN gateway (e.g., `172.16.1.1`).
    *   `eth1` (WAN2): Connects to a secondary broadband line or 4G/5G CPE, obtaining an external IP via DHCP (e.g., `192.168.66.x`).
*   **Services:** Dockerized services, such as AdGuard Home, handle local DNS resolution and coordinate with TProxy for intelligent traffic routing.

## 🚀 Quick Start

### 1. Prerequisites

*   **OS:** Debian 11/12 or Ubuntu 20.04/22.04 LTS.
*   **Permissions:** Root privileges required.
*   **Hardware:** At least two network interfaces (physical or virtual).

### 2. Installation

1.  **Clone the Repository**
    It is recommended to clone the project to `/root/faure.sh`:
    ```bash
    git clone https://github.com/your-repo/faure.sh.git /root/faure.sh
    cd /root/faure.sh
    ```

2.  **Run the Installation Script**
    This script automatically installs dependencies (netplan, iptables, docker, etc.), copies configuration files, and starts the necessary systemd services.
    ```bash
    sudo ./install.sh
    ```

3.  **Verify the Setup**
    Run the verification script to check system status, kernel parameters, and network configuration:
    ```bash
    sudo ./verify.sh
    ```

### 3. Configuration

After installation, adjust the following configurations to match your network environment:

*   **Network Interfaces (Netplan):**
    Edit the YAML files in `netplan/` to configure static IPs or DHCP, then run `netplan apply`.
    *   `90-static.yaml`: For static IP configuration (typically LAN/WAN1).
    *   `99-dhcp.yaml`: For DHCP interfaces.

*   **Traffic Monitoring (Optional):**
    If using a metered connection (e.g., 4G/5G), use `scripts/monitor-traffic-limit.sh`.
    ```bash
    # Example: Limit eth1 to 100GB/month, alert at 80%
    # Recommended: Add to crontab to run periodically
    */5 * * * * /root/faure.sh/scripts/monitor-traffic-limit.sh eth1 100 80 <path/to/alert-script.sh>
    ```

*   **TProxy Rules:**
    Modify the `FAURE_ADDR_RANGE` variable in `scripts/setup-tproxy.sh` to match your local subnet.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
