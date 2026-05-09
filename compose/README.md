# Compose Services

This directory contains optional Docker Compose stacks that complement the gateway role provided by `faure.sh`. Each subdirectory is self-contained and can be deployed independently with `docker compose up -d`.

## Prerequisites

- Docker Engine and the Compose plugin (see [misc_scripts/install-docker.fish](../misc_scripts/install-docker.fish)).
- Host network access (`network_mode: host`) and `NET_ADMIN` capability for services that bind directly to the gateway.
- Image pulls use the `docker.1ms.run` mirror; replace with the upstream registry if your network does not require a mirror.

## Notes

- Adjust DNS, IP addresses, and volume paths in each `compose.yaml` to match your environment before first launch.
- For TProxy integration, ensure Mihomo is running and reachable before enabling the `tproxy-routing.service` systemd unit.
- Logs are capped via the `json-file` driver in each stack to avoid filling the disk on long-running gateways.
