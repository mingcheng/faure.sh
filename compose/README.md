# Docker Compose Services

This directory contains Docker Compose configurations for various network and utility services.

## Services

### AdGuard Home (`adguard/`)

A network-wide DNS ad blocker and privacy protection tool. Runs in host network mode with DNS capabilities to filter unwanted content across your entire network.

**Quick Start:**
```bash
cd adguard && docker compose up -d
```

### iPerf3 (`iperf3/`)

A network performance testing tool for measuring bandwidth and network throughput. Runs as a server on port 5201 for network speed testing.

**Quick Start:**
```bash
cd iperf3 && docker compose up -d
```

### Mihomo (`mihomo/`)

A powerful proxy client with TUN support. Includes a web dashboard (Zashboard) for easy management and monitoring of proxy rules and connections.

**Quick Start:**
```bash
cd mihomo && docker compose up -d
```

### <del>sing-box (`sing-box/`)</del> (Discontinued)

A universal proxy platform with advanced routing capabilities. Supports multiple protocols and runs with TUN device support for transparent proxying.

**Quick Start:**
```bash
cd sing-box && docker compose up -d
```

## Common Features

All services include:
- Automatic restart on failure
- Health checks for monitoring
- Log rotation to prevent disk space issues
- Privileged network access where needed

## Notes

- Most services run in host network mode for optimal performance
- Configuration files are stored in respective subdirectories
- Check individual service directories for specific configuration details
