# AGENTS.md

Bash toolkit that turns a Debian/Ubuntu box into a dual-WAN (or one-NIC side-router) gateway with TProxy. User-facing docs: [README.md](README.md), script reference and variable table: [scripts/README.md](scripts/README.md), sysctl notes: [sysctl.d/README.md](sysctl.d/README.md), compose stacks: [compose/README.md](compose/README.md).

## Lint (no test suite; CI = [.github/workflows/lint.yml](.github/workflows/lint.yml))

```bash
shellcheck -x -e SC1091 -e SC2034 -S warning scripts/*.sh install.sh
shfmt -d -i 4 -ci -bn $(find . -name '*.sh' -not -path './.git/*')
fish -n misc_scripts/*.fish
```

Scripts mutate live routing/iptables state and need root — do **not** run `setup-*.sh`, `monitor-*.sh` or `install.sh` on the dev machine to "test" changes. `bash -n` + the linters above are the safe checks; `verify-kernel.sh` is read-only. For behavioral checks, run scripts inside a throwaway namespace (`unshare -rnm`, then create `dummy` links, mount tmpfs on `/run` and sysfs on `/sys`, and point `FAURE_CONFIG` / `UPLINK_STATE_FILE` at temp files).

## Architecture

- [scripts/config.sh](scripts/config.sh) holds all defaults, then sources the first existing override of `$FAURE_CONFIG`, `/etc/faure/config.sh`, `/etc/default/faure`. Never instruct users to edit `config.sh` directly.
- [scripts/utils.sh](scripts/utils.sh) sources `config.sh`; every script only does `source "$SCRIPT_DIR/utils.sh"`. Shared helpers (`log_info/warn/error`, `use_report_logging` for the verifiers' `[PASS]/[FAIL]` style, `get_ip`, `get_gateway`, `secondary_uplink_configured`/`secondary_uplink_enabled`, `uplink_state`, `find_rules`/`delete_rules`, `apply_ttl_bypass`, `ttl_bypass_enabled`) belong in `utils.sh` — do not redefine colors/loggers per script; getters must print empty + exit 0 when nothing is found so they are safe under `pipefail`.
- systemd chain: `multipath-routing.service` → `tproxy-routing.service` (both `oneshot`, `RemainAfterExit`; tproxy `Requires=` multipath, so restarting multipath restarts tproxy); `monitor-uplink.timer` restarts multipath on uplink state change and then `start`s tproxy (`monitor-uplink.service` has no `[Install]`; only the timer is enabled). Only `setup-multipath.sh` writes `$UPLINK_STATE_FILE`, after routing is applied, so failed restarts are retried. Unit `ExecStart` paths ship as `/root/faure.sh/scripts/`; `install.sh` rewrites them to the real project dir.

## Conventions

- Shebang `#!/usr/bin/env bash`; 4-space indent, shfmt `-ci -bn` style. `setup-*.sh` use `set -o errexit -o nounset -o pipefail` — guard optional vars with `${VAR:-}` and commands that may fail with `|| true`.
- Defaults in `config.sh` use `export VAR="${VAR:-default}"` so env/override values win (use `${VAR-default}` when an explicit empty value is meaningful, e.g. `IF2`, `IF1_GW_FALLBACK`). Values derived from other variables (`LAN_IF`) are resolved after the override block.
- Every network mutation must be **idempotent** (scripts re-run on every uplink change):
  - chains: `iptables -N X 2>/dev/null || true; iptables -F X`
  - jumps: `-D ... 2>/dev/null || true` before `-I`/`-A`; when the matchers come from config (e.g. `LAN_IF`), delete via `delete_rules` by target or by an `-m comment --comment faure-*` tag so a config change leaves nothing stale
  - policy rules: `while ip rule del priority N 2>/dev/null; do :; done` before `ip rule add`
- Never flush built-in chains or append before Docker's rules — `setup-tproxy.sh` deliberately uses `-A PREROUTING` so `DOCKER`/`DOCKER-USER` run first.
- Every feature must work in **one-NIC mode** (`IF2=""` or `IF2=$IF1`): branch on `secondary_uplink_enabled` / `HAS_SECONDARY_UPLINK`, and keep [scripts/verify-network.sh](scripts/verify-network.sh) skipping IF2/TABLE2/MARK2 checks.
- `MULTIPATH_MODE` (`balance`|`failover`) only applies when both uplinks are UP; single-uplink paths ignore it.
- IPv4 changes that touch TTL/egress need an `ip6tables` (Hop-Limit) counterpart; treat ip6tables as optional (warn, don't fail).
- Files carry a header block (copyright, `File:`, `Author:`, `Last Modified:`) — preserve it and bump `Last Modified` when editing.

## Keep in sync when adding/changing a config variable

1. Default in [scripts/config.sh](scripts/config.sh)
2. Commented template in [install.sh](install.sh) (`/etc/faure/config.sh` heredoc)
3. Variable table in [scripts/README.md](scripts/README.md) and, if user-facing, the example in [README.md](README.md)
4. Checks in [scripts/verify-network.sh](scripts/verify-network.sh) if it affects tables/marks/priorities/chains

New sysctl files under [sysctl.d/](sysctl.d/) are auto-verified by [scripts/verify-kernel.sh](scripts/verify-kernel.sh); add them to the explicit uninstall file list in [README.md](README.md) (never a glob) and the table in [sysctl.d/README.md](sysctl.d/README.md). Set each key in exactly one file, and remember distro files (e.g. `/usr/lib/sysctl.d/50-default.conf`) override ours when they sort later by name. Keys that need a module at boot go with a matching entry in [modules-load.d/faure.conf](modules-load.d/faure.conf). New systemd units must also be added to `SERVICES` in [install.sh](install.sh). Compose stacks never commit credentials: use `env_file: [{path: ./<name>.env, required: false}]` plus a committed `<name>.env.example`.
