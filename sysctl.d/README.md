# Kernel Parameter Configuration for Soft Router

This directory contains sysctl configuration files for optimizing Linux kernel performance and network settings specifically for soft router deployments. `install.sh` copies them to `/etc/sysctl.d/`; [`scripts/verify-kernel.sh`](../scripts/verify-kernel.sh) checks every key against the running kernel.

| File | Purpose |
| ---- | ------- |
| `10-custom-kernel-bbr.conf` | BBR congestion control |
| `10-custom-kernel-forward.conf` | IPv4 forwarding |
| `10-custom-kernel-ipv6.conf` | Disables IPv6 |
| `20-network-performance.conf` | Socket buffers, backlogs, keepalive, conntrack table size and timeouts |
| `30-security.conf` | Redirects, source routing, ICMP, SYN cookies, martian logging |
| `40-system-optimization.conf` | VM / OOM / panic behaviour, file handles, ARP table |
| `50-traffic-optimization.conf` | `fq` qdisc (pairs with BBR), TCP fast open, ECN, port range |
| `99-multipath.conf` | Loose `rp_filter` and L3+L4 multipath hashing |

Each key is set in exactly one file; keep it that way when adding parameters.

## Ordering pitfalls

- systemd-sysctl applies files from `/etc/sysctl.d`, `/run/sysctl.d` and `/usr/lib/sysctl.d` in one pass, sorted by **file name**. Distribution defaults such as `/usr/lib/sysctl.d/50-default.conf` (`net.core.default_qdisc = fq_codel`) and `50-pid-max.conf` therefore override any of our `10-*`..`40-*` files. That is why `default_qdisc` lives in `50-traffic-optimization.conf`. `verify-kernel.sh` prints `also set in: …` for such conflicts.
- `net.netfilter.nf_conntrack_*` keys only exist once the `nf_conntrack` module is loaded. [`../modules-load.d/faure.conf`](../modules-load.d/faure.conf) loads it before systemd-sysctl runs; without it these keys are silently skipped at boot.

When adding a new file here, also add it to the explicit uninstall list in the top-level [README.md](../README.md) (never use a glob).
