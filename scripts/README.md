# Scripts Directory

Utility scripts for setting up, monitoring, and verifying the network
configuration (multipath uplinks, transparent proxy, kernel parameters,
traffic accounting) of the **faure.sh** project.

All scripts are Bash (`#!/usr/bin/env bash`) and are designed to be invoked either
directly from the command line or from `systemd` units shipped under
[`../systemd/`](../systemd).

---

## File Layout

| File | Purpose |
|------|---------|
| [`config.sh`](config.sh) | Single source of truth for **all** tunables (interfaces, networks, route tables, fwmarks, TProxy port, etc.). Sourced by every other script via `utils.sh`. |
| [`utils.sh`](utils.sh) | Shared logging (`log_info` / `log_warn` / `log_error`; `use_report_logging` switches the verifiers to `[PASS]` / `[FAIL]` labels; colors only on a TTY and never with `NO_COLOR`), network helpers (`get_ip`, `get_subnet`, `get_gateway`, `check_connectivity`, `wait_for_ip`, `secondary_uplink_configured`, `secondary_uplink_enabled`, `uplink_state`), iptables rule helpers (`find_rules` / `delete_rules`, matching on the live `-S` output) and the per-uplink TTL / Hop-Limit normalizer (`apply_ttl_bypass` / `clear_ttl_bypass` / `ttl_bypass_enabled` / `egress_rewrite_rules`). Sources `config.sh` automatically. |
| [`setup-multipath.sh`](setup-multipath.sh) | Builds the dual-uplink load-balancing routing tables, policy rules, `MULTIPATH_MARK` mangle chain (CONNMARK based), and default route, then installs `MASQUERADE` and TTL / Hop-Limit normalization on every *configured* uplink (also inactive ones, so a reconnecting USB tether is covered immediately). Persists the uplink state for `monitor-uplink.sh`. |
| [`setup-tproxy.sh`](setup-tproxy.sh) | Installs the Mihomo / Clash transparent-proxy chain (`MIHOMO_TPROXY` in `mangle`) plus a LAN-scoped DNS REDIRECT in `nat`. **Docker-safe** (see below). |
| [`monitor-uplink.sh`](monitor-uplink.sh) | Periodic health-check that reapplies multipath + TProxy *exactly once* per run when either: (a) a routing table looks broken, or (b) the probed uplink state (`BOTH` / `IF1_ONLY` / `IF2_ONLY` / `NONE`) differs from the one `setup-multipath.sh` last recorded. A failed restart leaves the recorded state untouched, so it is retried on the next run. |
| [`monitor-traffic-limit.sh`](monitor-traffic-limit.sh) | Per-interface monthly traffic cap. Uses `vnstat` (JSON, or `--oneline` month total) when available, falls back to `/sys/class/net/*/statistics`. Hard-blocks forwarding (IPv4, plus IPv6 when available) while over the cap, re-asserting the rules on every run so the block survives reboots; optional alert script is called once per transition as `<script> <WARNING\|BLOCK> <iface> <usage_gb> <limit_gb>`. Traffic proxied by Mihomo (router-originated) is **not** blocked. |
| [`check-balance.sh`](check-balance.sh) | One-shot helper that samples TX/RX counters on two interfaces over N seconds and reports the upload/download split. |
| [`verify-network.sh`](verify-network.sh) | Run-time verification of multipath default route, policy rules, mangle chains, TProxy (chain, hook, rule, table — skipped with a warning when TProxy is not installed), TTL rewrite and per-interface internet connectivity. Exits non-zero on any FAIL. |
| [`verify-kernel.sh`](verify-kernel.sh) | Parses every `*.conf` under [`../sysctl.d/`](../sysctl.d) and compares each `key = value` against the live value in `/proc/sys` (no `sysctl` binary or root needed). Reports PASS / FAIL / MISSING with a non-zero exit on any mismatch, and names other system sysctl.d files that set a mismatched key (`also set in: …`). |

---

## Configuration

All tunables live in [`config.sh`](config.sh). The file ships with sane
defaults for a typical two-uplink router, but you should **not** edit it
directly when deploying — drop a fragment at one of the override locations
below and only redefine what you need:

1. The path in the `FAURE_CONFIG` environment variable
2. `/etc/faure/config.sh`   *(preferred system-wide override)*
3. `/etc/default/faure`     *(Debian-style alternative)*

Precedence is: override file > environment variables > defaults in
`config.sh`. `LAN_IF` is resolved after the override, so changing `IF1`
there also changes the default `LAN_IF`.

Example `/etc/faure/config.sh`:

```sh
export IF1="enp1s0"
export IF2="enx001122334455"
export LAN_NET="10.0.0.0/24"
export TPROXY_PORT="7893"
```

For a one-NIC side-router, disable the secondary uplink explicitly:

```sh
export IF1="enp1s0"
export IF2=""
export LAN_IF="$IF1"
export LAN_NET="192.168.1.0/24"
```

Variables of note:

| Variable | Default | Used by |
|----------|---------|---------|
| `IF1`, `IF2` | `eth0`, `eth1` | All multipath / verification scripts; set `IF2=""` or `IF2="$IF1"` for one-NIC side-router mode |
| `LAN_IF` | `$IF1` | `setup-tproxy.sh` (LAN-facing NIC) |
| `LAN_NET` | `192.168.1.0/24` | TProxy + multipath bypass |
| `TABLE1`, `TABLE2` | `100`, `101` | Multipath routing tables |
| `MARK1`, `MARK2` | `0x100`, `0x200` | Multipath fwmarks |
| `WEIGHT1`, `WEIGHT2` | `1`, `1` | Per-uplink ECMP weights (only used when `MULTIPATH_MODE=balance` and both uplinks are UP) |
| `MULTIPATH_MODE` | `balance` | `balance` = weighted ECMP; `failover` = active/standby. Only takes effect when **both** uplinks are UP — single-uplink scenarios always use the lone available uplink. |
| `PRIMARY_IF` | `IF1` | Which logical interface is primary in `failover` mode (`IF1` or `IF2`) |
| `TPROXY_PORT` | `8848` | Mihomo TProxy listener |
| `TPROXY_DNS_PORT` | `53` | Local DNS port for REDIRECT target |
| `TPROXY_WAIT_TIMEOUT` | `300` | Seconds `setup-tproxy.sh` waits for the Mihomo listeners before aborting (keep below `TimeoutStartSec=360` of `tproxy-routing.service`) |
| `TPROXY_WAIT_INTERVAL` | `2` | Listener poll interval in seconds |
| `TPROXY_TABLE` | `200` | TProxy routing table |
| `TPROXY_MARK` | `0x1` | TProxy fwmark |
| `CHAIN_NAME` | `MIHOMO_TPROXY` | TProxy mangle chain |
| `IF1_GW_FALLBACK` | `172.16.1.1` | Last-resort gateway when DHCP/route detection fails on `IF1`; set empty to disable |
| `PRIO_MARK1`, `PRIO_MARK2`, `PRIO_TPROXY`, `PRIO_SRC1`, `PRIO_SRC2` | `90`, `91`, `99`, `100`, `101` | `ip rule` priorities (fwmark, TProxy and source-based rules) |
| `UPLINK_STATE_FILE` | `/run/uplink_status` | State persistence for `monitor-uplink.sh` |
| `TTL_BYPASS_ENABLED` | `1` | Master switch for the WAN-egress TTL / IPv6 Hop-Limit rewrite (tethering-detection bypass). Set to `0` to disable. |
| `TTL_BYPASS_VALUE` | `65` | Egress TTL / Hop-Limit value (1..255). `65` mimics a phone forwarding tethered traffic; `64` mimics direct phone egress. |

---

## Usage

```sh
# One-shot bring-up (run as root)
sudo ./setup-multipath.sh
sudo ./setup-tproxy.sh

# Health checks
sudo ./monitor-uplink.sh                 # safe to run every minute
sudo ./verify-network.sh                 # iptables checks need root
./verify-kernel.sh

# Diagnostics
./check-balance.sh eth0 eth1 30          # 30-second TX/RX split sample

# Traffic accounting (typically driven by a systemd timer)
sudo ./monitor-traffic-limit.sh eth1 1000 80 /opt/alert.sh
```

Both `setup-multipath.sh` and `setup-tproxy.sh` are idempotent — they clean
up their own previous state before re-installing rules, so they can be
re-run at any time without leaving stale artifacts. `setup-tproxy.sh` finds
its `PREROUTING` jump by target and its DNS `REDIRECT` rules by the
`faure-tproxy-dns` comment, so changing `LAN_IF` / `LAN_NET` does not leave
the old rules behind.

If no uplink passes the connectivity probe, `setup-multipath.sh` still keeps
a default route via the first uplink that has a gateway (and records state
`NONE`), so a probe false-negative never black-holes the LAN.

---

## Docker Compatibility

These scripts are designed to coexist with a running Docker daemon. The
guarantees are:

* **`mangle` table only for routing logic.** Both the multipath
  `MULTIPATH_MARK` chain and the TProxy `MIHOMO_TPROXY` chain live in
  `mangle`, which Docker does not touch. Container port publishing
  (handled by Docker in `nat/DOCKER`) is unaffected.
* **No flushing of builtin chains.** The setup scripts never run
  `iptables -F` against `PREROUTING` / `POSTROUTING` / `INPUT` / `FORWARD`
  / `OUTPUT`. They only flush their own named chains. Docker's `DOCKER`,
  `DOCKER-USER`, `DOCKER-ISOLATION-STAGE-*` chains remain untouched.
* **Tightly scoped jumps.** TProxy rules in `mangle/PREROUTING` and DNS
  REDIRECT rules in `nat/PREROUTING` are matched by
  `-i $LAN_IF -s $LAN_NET`, so traffic from `docker0` / `br-*` bridges is
  never hijacked. The DNS rules carry `-m comment --comment faure-tproxy-dns`
  so cleanup never touches other `REDIRECT` rules.
* **Append, don't insert.** `setup-tproxy.sh` uses `-A` for its
  `PREROUTING` jump so Docker's `-j DOCKER` evaluates first; only
  LAN-sourced traffic falls through to TProxy.
* **Bypass list covers Docker subnets.** The TProxy bypass list includes
  `172.16.0.0/12`, which contains the default Docker bridge address space,
  so container destinations are never marked. Destinations owned by the
  router itself (`-m addrtype --dst-type LOCAL`) are bypassed as well.
* **MASQUERADE coexistence.** `setup-multipath.sh` appends
  `nat/POSTROUTING -o $IFx -j MASQUERADE` rules; these do not overlap with
  Docker's `-s 172.17.0.0/16 ! -o docker0 -j MASQUERADE` rule.

The one **intentional** exception is `monitor-traffic-limit.sh`: when the
monthly cap is hit, the script inserts `FORWARD -i $IFACE -j DROP` at the
top of the builtin `FORWARD` chain. This deliberately preempts the jump
to `DOCKER-USER` so that container egress through the capped uplink is
also blocked. This is documented in-script.

---

## Recommended Systemd Wiring

The companion units in [`../systemd/`](../systemd) glue these scripts
together at boot:

* `multipath-routing.service` → runs `setup-multipath.sh` after
  `network-online.target`.
* `tproxy-routing.service` → runs `setup-tproxy.sh` after
  `multipath-routing.service` and `docker.service`; the script itself polls
  for the Mihomo listeners (up to `TPROXY_WAIT_TIMEOUT`) before touching any
  firewall state.
* `monitor-uplink.service` + `monitor-uplink.timer` → periodic health
  check (the service has no `[Install]` section; only the timer is enabled)
  that calls `monitor-uplink.sh`, which restarts
  `multipath-routing.service` *exactly once* per run on state change or
  breakage (the restart propagates to `tproxy-routing.service` via
  `Requires=`), then `start`s `tproxy-routing.service` in case it had failed.
* `install.sh` rewrites the `/root/faure.sh` paths in the units to the
  actual project directory.
