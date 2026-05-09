# Scripts Directory

Utility scripts for setting up, monitoring, and verifying the network
configuration (multipath uplinks, transparent proxy, kernel parameters,
traffic accounting) of the **faure.sh** project.

All scripts are POSIX-shell-friendly and are designed to be invoked either
directly from the command line or from `systemd` units shipped under
[`../systemd/`](../systemd).

---

## File Layout

| File | Purpose |
|------|---------|
| [`config.sh`](config.sh) | Single source of truth for **all** tunables (interfaces, networks, route tables, fwmarks, TProxy port, etc.). Sourced by every other script via `utils.sh`. |
| [`utils.sh`](utils.sh) | Shared logging (`log_info` / `log_warn` / `log_error`) and network helpers (`get_ip`, `get_subnet`, `get_gateway`, `check_connectivity`, `wait_for_ip`). Sources `config.sh` automatically. |
| [`setup-multipath.sh`](setup-multipath.sh) | Builds the dual-uplink load-balancing routing tables, policy rules, `MULTIPATH_MARK` mangle chain (CONNMARK based) and `MASQUERADE` rules. |
| [`setup-tproxy.sh`](setup-tproxy.sh) | Installs the Mihomo / Clash transparent-proxy chain (`MIHOMO_TPROXY` in `mangle`) plus a LAN-scoped DNS REDIRECT in `nat`. **Docker-safe** (see below). |
| [`monitor-uplink.sh`](monitor-uplink.sh) | Periodic health-check that reapplies multipath + TProxy *exactly once* per run when either: (a) a routing table looks broken, or (b) the uplink state machine transitions (`BOTH` / `IF1_ONLY` / `IF2_ONLY` / `NONE`). |
| [`monitor-traffic-limit.sh`](monitor-traffic-limit.sh) | Per-interface monthly traffic cap. Uses `vnstat` when available, falls back to `/sys/class/net/*/statistics`. Hard-blocks forwarding when the cap is hit. |
| [`check-balance.sh`](check-balance.sh) | One-shot helper that samples TX/RX counters on two interfaces over N seconds and reports the upload/download split. |
| [`verify-network.sh`](verify-network.sh) | Run-time verification of multipath default route, policy rules, mangle chains and per-interface internet connectivity. |
| [`verify-kernel.sh`](verify-kernel.sh) | Parses every `*.conf` under [`../sysctl.d/`](../sysctl.d) and compares each `key = value` against the live `sysctl` value. Reports PASS / FAIL / MISSING with a non-zero exit on any mismatch. |

---

## Configuration

All tunables live in [`config.sh`](config.sh). The file ships with sane
defaults for a typical two-uplink router, but you should **not** edit it
directly when deploying — drop a fragment at one of the override locations
below and only redefine what you need:

1. The path in the `FAURE_CONFIG` environment variable
2. `/etc/faure/config.sh`   *(preferred system-wide override)*
3. `/etc/default/faure`     *(Debian-style alternative)*

Example `/etc/faure/config.sh`:

```sh
export IF1="enp1s0"
export IF2="enx001122334455"
export LAN_NET="10.0.0.0/24"
export TPROXY_PORT="7893"
```

Variables of note:

| Variable | Default | Used by |
|----------|---------|---------|
| `IF1`, `IF2` | `eth0`, `eth1` | All multipath / verification scripts |
| `LAN_IF` | `$IF1` | `setup-tproxy.sh` (LAN-facing NIC) |
| `LAN_NET` | `192.168.1.0/24` | TProxy + multipath bypass |
| `TABLE1`, `TABLE2` | `100`, `101` | Multipath routing tables |
| `MARK1`, `MARK2` | `0x100`, `0x200` | Multipath fwmarks |
| `TPROXY_PORT` | `8848` | Mihomo TProxy listener |
| `TPROXY_DNS_PORT` | `53` | Local DNS port for REDIRECT target |
| `TPROXY_TABLE` | `200` | TProxy routing table |
| `TPROXY_MARK` | `0x1` | TProxy fwmark |
| `CHAIN_NAME` | `MIHOMO_TPROXY` | TProxy mangle chain |
| `IF1_GW_FALLBACK` | `172.16.1.1` | Last-resort gateway when DHCP/route detection fails on `IF1`; set empty to disable |
| `UPLINK_STATE_FILE` | `/run/uplink_status` | State persistence for `monitor-uplink.sh` |

---

## Usage

```sh
# One-shot bring-up (run as root)
sudo ./setup-multipath.sh
sudo ./setup-tproxy.sh

# Health checks
sudo ./monitor-uplink.sh                 # safe to run every minute
./verify-network.sh
./verify-kernel.sh

# Diagnostics
./check-balance.sh eth0 eth1 30          # 30-second TX/RX split sample

# Traffic accounting (typically driven by a systemd timer)
sudo ./monitor-traffic-limit.sh eth1 1000 80 /opt/alert.sh
```

Both `setup-multipath.sh` and `setup-tproxy.sh` are idempotent — they clean
up their own previous state before re-installing rules, so they can be
re-run at any time without leaving stale artifacts.

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
  never hijacked.
* **Append, don't insert.** `setup-tproxy.sh` uses `-A` for its
  `PREROUTING` jump so Docker's `-j DOCKER` evaluates first; only
  LAN-sourced traffic falls through to TProxy.
* **Bypass list covers Docker subnets.** The TProxy bypass list includes
  `172.16.0.0/12`, which contains the default Docker bridge address space,
  so container destinations are never marked.
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
* `tproxy-routing.service` → runs `setup-tproxy.sh` after the Mihomo
  container/service is healthy.
* `monitor-uplink.service` + `monitor-uplink.timer` → periodic health
  check that calls `monitor-uplink.sh`, which in turn restarts the two
  setup services *exactly once* per run on state change or breakage.
