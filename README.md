# Faure.sh - Transparent Router Configuration Script

A lightweight and efficient transparent router solution for debian-based systems.

## System Configuration

### Prerequisites

Install required system packages:
```bash
sudo apt update
sudo apt install netplan.io iptables fish net-tools
```

and install the docker by the script which locatied at ``scripts/install_docker.fish``.

### Network Configuration

Configure network interfaces using Netplan:
```bash
sudo cp netplan/*.yaml /etc/netplan/
sudo netplan apply
```

Available configurations:
- `90-static.yaml` - Static IP configuration for router interface
- `99-dhcp.yaml` - DHCP fallback configuration

### Kernel Optimization

Apply optimized kernel parameters for routing performance:
```bash
sudo cp sysctl.d/*.conf /etc/sysctl.d/
sudo sysctl --system
```

### Firewall Rules

Configure transparent proxy and security rules:
```bash
sudo ./scripts/firewall.fish
```

you can auto start the script by enable the rc.local service:
```bash
sudo systemctl enable rc-local
```
and link the script to `/etc/rc.local`:
```bash
sudo ln -s /path/to/faure.sh/scripts/firewall.fish /etc/rc.local
```

## Service Deployment

### Docker Services

Enable Docker service and start containers:
```bash
sudo systemctl enable docker
sudo systemctl start docker
```

### Mihomo Proxy

Deploy Mihomo for transparent proxy functionality:
```bash
cd compose/mihomo
docker compose up -d
```

### AdGuard Home(Optional but Recommended)

Deploy AdGuard Home for DNS filtering:
```bash
cd compose/adguard
docker compose up -d
```

### Performance Testing(Optional)

Deploy iperf3 for network performance testing:
```bash
cd compose/iperf3
docker compose up -d
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.
