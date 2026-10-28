#!/usr/bin/env bash
# Copyright (c) 2025 mingcheng <mingcheng@apache.org>
#
# Shared utility functions for faure.sh scripts
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: utils.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2025-12-31 10:33:40
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-10-28 17:34:53
##

# Source configuration (defaults + optional /etc/faure override).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# --- Logging Functions ---

# Colorize only on a terminal (and honor NO_COLOR) so the systemd journal does
# not fill up with raw escape sequences.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[1;33m'
    COLOR_RED='\033[0;31m'
    COLOR_CYAN='\033[0;36m'
    COLOR_NC='\033[0m'
else
    COLOR_GREEN='' COLOR_YELLOW='' COLOR_RED='' COLOR_CYAN='' COLOR_NC=''
fi

# Usage: _log <color> <label> <message...>
_log() {
    local color=$1 label=$2
    shift 2
    printf '%b[%s] %s%b %s\n' "$color" "$label" "$(date '+%Y-%m-%d %H:%M:%S')" "$COLOR_NC" "$*"
}

log_info() { _log "$COLOR_GREEN" INFO "$@"; }
log_warn() { _log "$COLOR_YELLOW" WARN "$@"; }
log_error() { _log "$COLOR_RED" ERROR "$@" >&2; }

# Switch to the timestamp-less [PASS]/[FAIL]/[WARN] style used by the
# verify-*.sh reports. Call once, right after sourcing this file.
# shellcheck disable=SC2317  # functions are defined when this is called
use_report_logging() {
    log_pass() { printf '%b[PASS]%b %s\n' "$COLOR_GREEN" "$COLOR_NC" "$*"; }
    log_fail() { printf '%b[FAIL]%b %s\n' "$COLOR_RED" "$COLOR_NC" "$*"; }
    log_warn() { printf '%b[WARN]%b %s\n' "$COLOR_YELLOW" "$COLOR_NC" "$*"; }
    log_info() { printf '       %s\n' "$*"; }
    log_head() { printf '%b%s%b\n' "$COLOR_CYAN" "$*" "$COLOR_NC"; }
}

# --- Network Helper Functions ---
# All getters print an empty string (and exit 0) when nothing is found, so
# they are safe to call from scripts running with errexit + pipefail.

# Print the first IPv4 address of an interface.
# Usage: get_ip <interface>
get_ip() {
    ip -4 -o addr show dev "$1" 2>/dev/null \
        | awk '{ split($4, a, "/"); print a[1]; exit }' || true
}

# Return success when IF2 is set and distinct from IF1 (it may still lack an
# address). Setting IF2 empty or equal to IF1 selects one-NIC mode.
secondary_uplink_configured() {
    [ -n "${IF2:-}" ] && [ "${IF2:-}" != "${IF1:-}" ]
}

# Return success when the secondary uplink is configured AND currently has
# IPv4. A configured but inactive IF2 (e.g. unplugged USB tether) keeps the
# scripts in single-uplink mode; monitor-uplink picks it up on a later run
# once the NIC appears and receives an address.
secondary_uplink_enabled() {
    secondary_uplink_configured && [ -n "$(get_ip "$IF2")" ]
}

# Print the first on-link (scope link, not linkdown) IPv4 subnet of an iface.
# Usage: get_subnet <interface>
get_subnet() {
    ip -4 route show dev "$1" scope link 2>/dev/null \
        | awk '!/linkdown/ { print $1; exit }' || true
}

# Print the gateway for an interface. Sources, in order of preference:
#   1. the main table's "default via" route (prefer DHCP / netplan updates)
#   2. the default route already installed in <table_id> (if still reachable)
#   3. heuristic: the ".1" host of the on-link subnet (typical /24 tethering)
#   4. IF1_GW_FALLBACK, only for $IF1 (empty disables)
# Usage: get_gateway <interface> [table_id]
get_gateway() {
    local iface=$1 table=${2:-} gw="" subnet

    gw=$(ip -4 route show default dev "$iface" 2>/dev/null \
        | awk '$1 == "default" && $2 == "via" && !/linkdown/ {
            if ($0 ~ / proto (dhcp|static)( |$)/) { preferred = $3; exit }
            if (gateway == "") gateway = $3
        } END { print (preferred != "" ? preferred : gateway) }' || true)

    if [ -z "$gw" ] && [ -n "$table" ]; then
        gw=$(ip -4 route show table "$table" default dev "$iface" 2>/dev/null \
            | awk '$2 == "via" { print $3; exit }' || true)
        # Drop a stale gateway that is no longer on-link for $iface.
        if [ -n "$gw" ] && ! ip route get "$gw" dev "$iface" >/dev/null 2>&1; then
            gw=""
        fi
    fi

    if [ -z "$gw" ]; then
        subnet=$(get_subnet "$iface")
        # "192.168.66.0/24" -> "192.168.66.1"
        if [ -n "$subnet" ]; then
            gw="${subnet%.*}.1"
        fi
    fi

    if [ -z "$gw" ] && [ -n "${IF1_GW_FALLBACK:-}" ] && [ "$iface" = "${IF1:-}" ]; then
        gw="$IF1_GW_FALLBACK"
    fi

    echo "$gw"
}

# Probe Internet reachability through a specific uplink.
# Usage: check_connectivity <interface> <gateway> [timeout]
#
# Probe routes are added, never replaced, and only routes we created are
# removed. A subshell keeps the cleanup traps local to this probe.
check_connectivity() (
    local iface=$1 gw=${2:-} timeout=${3:-2}
    local targets=("223.5.5.5" "119.29.29.29")
    local target pinned=""

    cleanup_probe_route() {
        [ -n "$pinned" ] || return 0
        if ! ip -4 route del "$pinned/32" via "$gw" dev "$iface" metric 0; then
            log_warn "Failed to remove probe route for $pinned on $iface."
            return 1
        fi
        pinned=""
    }

    trap 'cleanup_probe_route || exit 1' EXIT
    trap 'exit 1' HUP INT TERM

    ip link show "$iface" >/dev/null 2>&1 || return 1

    for target in "${targets[@]}"; do
        if [ -n "$gw" ]; then
            if ip -4 route add "$target/32" via "$gw" dev "$iface" metric 0 2>/dev/null; then
                pinned="$target"
            else
                log_warn "Cannot add probe route for $target on $iface; using interface-bound ICMP only."
            fi
        fi

        if ping -I "$iface" -c 1 -W "$timeout" "$target" >/dev/null 2>&1; then
            return 0
        # /dev/tcp cannot bind to a device; only trust it when the pinned
        # route above guarantees the SYN leaves via $iface.
        elif [ -n "$pinned" ] && timeout "$timeout" bash -c 'exec 9<>/dev/tcp/$1/443' bash "$target" 2>/dev/null; then
            return 0
        fi

        cleanup_probe_route || return 1
    done
    return 1
)

# Block until ANY of the given interfaces has an IPv4 address.
# Usage: wait_for_ip <max_retries> <retry_delay> <interface>...
wait_for_ip() {
    local max_retries=$1 retry_delay=$2 count iface
    shift 2

    for ((count = 0; count < max_retries; count++)); do
        for iface in "$@"; do
            if [ -n "$(get_ip "$iface")" ]; then
                return 0
            fi
        done
        # Log every 5th attempt to keep the journal quiet.
        if ((count % 5 == 0)); then
            log_info "Waiting for $* to obtain an IP address... ($((count + 1))/$max_retries)"
        fi
        sleep "$retry_delay"
    done
    return 1
}

# Map per-uplink health flags (1 = UP) to the state string persisted in
# $UPLINK_STATE_FILE and compared by monitor-uplink.sh.
# Usage: uplink_state <if1_up> <if2_up>
uplink_state() {
    case "$1$2" in
        11) echo "BOTH" ;;
        10) echo "IF1_ONLY" ;;
        01) echo "IF2_ONLY" ;;
        *) echo "NONE" ;;
    esac
}

# --- iptables helpers -------------------------------------------------------

# Print the rules of <table>/<chain> (iptables -S form) matching <ERE>.
# Prints nothing if the tool is missing or nothing matches.
# Usage: find_rules <iptables|ip6tables> <table> <chain> <regex>
find_rules() {
    local cmd=$1 table=$2 chain=$3 regex=$4
    command -v "$cmd" >/dev/null 2>&1 || return 0
    "$cmd" -t "$table" -S "$chain" 2>/dev/null | grep -E -- "$regex" || true
}

# Parse iptables' double-quoted/escaped `-S` arguments without evaluating
# shell syntax. Delete exact rules, not indices that concurrent inserts
# (e.g. Docker) could shift between listing and deletion.
# Usage: delete_rules <iptables|ip6tables> <table> <chain> <regex>
delete_rules() {
    local cmd=$1 table=$2 chain=$3 regex=$4 line rules char word index
    local quoted escaped started
    local -a rule=()
    command -v "$cmd" >/dev/null 2>&1 || return 0
    if ! rules=$("$cmd" -t "$table" -S "$chain"); then
        log_error "Cannot list $cmd rules in $table/$chain."
        return 1
    fi

    while IFS= read -r line; do
        [[ $line == "-A $chain "* && $line =~ $regex ]] || continue
        rule=()
        word="" quoted=0 escaped=0 started=0
        for ((index = 0; index < ${#line}; index++)); do
            char=${line:index:1}
            if [ "$escaped" -eq 1 ]; then
                word+="$char"
                escaped=0
            elif [ "$char" = '\' ]; then
                escaped=1
                started=1
            elif [ "$char" = '"' ]; then
                quoted=$((1 - quoted))
                started=1
            elif [ "$quoted" -eq 0 ] && [[ $char == ' ' || $char == $'\t' ]]; then
                if [ "$started" -eq 1 ]; then
                    rule+=("$word")
                    word="" started=0
                fi
            else
                word+="$char"
                started=1
            fi
        done
        if [ "$quoted" -ne 0 ] || [ "$escaped" -ne 0 ]; then
            log_error "Cannot parse quoted rule from $cmd $table/$chain."
            return 1
        fi
        [ "$started" -eq 0 ] || rule+=("$word")
        rule[0]="-D"
        if ! "$cmd" -t "$table" "${rule[@]}"; then
            log_error "Cannot delete matching rule from $cmd $table/$chain."
            return 1
        fi
    done <<<"$rules"
}

# --- Tethering / Hotspot detection bypass ---------------------------------
#
# Rewrite the IPv4 TTL (and IPv6 Hop-Limit) of every packet leaving the
# given WAN interface to a fixed value. This is applied in mangle POSTROUTING
# *after* the kernel's normal forwarding decrement, so the packet egresses
# with exactly $TTL_BYPASS_VALUE regardless of how many internal hops it
# took. Carriers that detect tethering by looking for the "off-by-one" TTL
# fingerprint (TTL = phone_default - 1) are defeated.
#
# Notes:
#   * iptables `TTL` target needs xt_TTL; ip6tables `HL` target needs xt_HL.
#     Both are part of the standard `iptables-extensions` package on Debian
#     and are auto-loaded by the kernel on first use. IPv6 is best-effort:
#     if the module is missing we warn and continue.
#   * Idempotent: any pre-existing TTL/HL rule for the interface (regardless
#     of the previous value) is removed before the new one is appended, so
#     repeated invocations (e.g. via monitor-uplink) do not stack rules.
#   * If $TTL_BYPASS_ENABLED is 0/false/empty, this becomes a no-op cleanup
#     so flipping the toggle off and re-running setup removes the rules.

# Return success when TTL_BYPASS_ENABLED is set to a truthy value.
ttl_bypass_enabled() {
    case "${TTL_BYPASS_ENABLED:-1}" in
        1 | true | TRUE | yes | on) return 0 ;;
        *) return 1 ;;
    esac
}

# Print the live mangle/POSTROUTING TTL/HL rewrite rules (iptables -S form)
# for <iface>. Prints nothing if the tool is missing or no rule matches.
# Usage: egress_rewrite_rules <iptables|ip6tables> <TTL|HL> <iface>
egress_rewrite_rules() {
    find_rules "$1" mangle POSTROUTING "$(egress_rewrite_regex "$2" "$3")"
}

# ERE matching the TTL/HL rewrite rules on <iface> (any value).
# Usage: egress_rewrite_regex <TTL|HL> <iface>
egress_rewrite_regex() {
    printf '^-A POSTROUTING .*-o %s .*-j %s( |$)' "${2//./\\.}" "$1"
}

# Remove any TTL/HL rewrite rule installed on the given iface (all values,
# so value changes or legacy duplicates are cleaned up too).
# Usage: clear_ttl_bypass <iface>
clear_ttl_bypass() {
    local iface=${1:-}
    [ -n "$iface" ] || return 0
    delete_rules iptables mangle POSTROUTING "$(egress_rewrite_regex TTL "$iface")" || return 1
    delete_rules ip6tables mangle POSTROUTING "$(egress_rewrite_regex HL "$iface")" 2>/dev/null \
        || log_warn "Could not clear IPv6 Hop-Limit rules on $iface."
}

# Apply (or, if disabled, just clean up) the TTL/HL rewrite on a WAN iface.
# Usage: apply_ttl_bypass <iface>
apply_ttl_bypass() {
    local iface=${1:-} val=${TTL_BYPASS_VALUE:-}
    [ -n "$iface" ] || return 0

    # Always clear first so toggling the feature off removes the rules.
    clear_ttl_bypass "$iface" || return 1

    if ! ttl_bypass_enabled; then
        log_info "TTL bypass disabled; skipping $iface."
        return 0
    fi

    if ! [[ $val =~ ^[0-9]+$ ]] || [ "$val" -lt 1 ] || [ "$val" -gt 255 ]; then
        log_warn "TTL_BYPASS_VALUE='$val' is not an integer in 1..255; skipping $iface."
        return 0
    fi

    if iptables -t mangle -A POSTROUTING -o "$iface" -j TTL --ttl-set "$val" 2>/dev/null; then
        log_info "TTL bypass: $iface egress TTL pinned to $val (IPv4)."
    else
        log_warn "TTL bypass: failed to install IPv4 TTL rule on $iface (xt_TTL module missing?)."
    fi

    # IPv6 is best-effort: skip silently when ip6tables is not installed.
    if command -v ip6tables >/dev/null 2>&1; then
        if ip6tables -t mangle -A POSTROUTING -o "$iface" -j HL --hl-set "$val" 2>/dev/null; then
            log_info "TTL bypass: $iface egress Hop-Limit pinned to $val (IPv6)."
        else
            log_warn "TTL bypass: failed to install IPv6 HL rule on $iface (xt_HL module missing?)."
        fi
    fi
}
