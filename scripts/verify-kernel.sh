#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
#
# Verify kernel parameters against the configurations defined in sysctl.d/
#
# This script parses every *.conf file under the project's sysctl.d/ directory,
# extracts each `key = value` pair, then compares it with the runtime value
# read from /proc/sys. A summary of PASS/FAIL/MISSING entries is printed at
# the end, and the exit code is non-zero when any mismatch is detected.
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: verify-kernel.sh
# Author: mingcheng <mingcheng@apache.org>
# File Created: 2026-05-09 16:48:36
#
# Modified By: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-10-06 19:30:00
##

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=utils.sh
source "$SCRIPT_DIR/utils.sh"
use_report_logging

# Locate sysctl.d directory relative to this script
SYSCTL_DIR="${SYSCTL_DIR:-$SCRIPT_DIR/../sysctl.d}"

# Other places systemd-sysctl reads; used to explain mismatches.
SYSTEM_SYSCTL_PATHS=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /etc/sysctl.conf)

if [ ! -d "$SYSCTL_DIR" ]; then
    log_fail "sysctl.d directory not found: $SYSCTL_DIR"
    exit 2
fi

echo "=============================================="
echo "Kernel Parameter Verification"
echo "=============================================="
echo "Source directory: $SYSCTL_DIR"
echo ""

PASS_COUNT=0
FAIL_COUNT=0
MISSING_COUNT=0
FAIL_DETAILS=()

# Collapse whitespace runs into single spaces and trim (pure bash, no fork).
normalize() {
    local -a words
    read -ra words <<<"$1"
    echo "${words[*]}"
}

# Map a sysctl key to its /proc/sys path. Per sysctl.d(5), a key containing
# '/' already uses '/' as separator; otherwise '.' separates components.
# Usage: proc_path <key>
proc_path() {
    local key=$1
    [[ $key == */* ]] || key=${key//./\/}
    echo "/proc/sys/$key"
}

# Print other system sysctl files that also set <key> (and may override us).
# Usage: other_sources <key> <our_basename>
other_sources() {
    local key_re="^[[:space:]]*-?${1//./\\.}[[:space:]]*="
    grep -rlsE -e "$key_re" "${SYSTEM_SYSCTL_PATHS[@]}" 2>/dev/null \
        | grep -v -e "/$2\$" || true
}

check_param() {
    local key="$1" expected="$2" file="$3"
    local path actual exp_norm act_norm others

    path=$(proc_path "$key")
    if [ ! -r "$path" ] || ! actual=$(<"$path") 2>/dev/null; then
        log_warn "$key (from $file): not available on this kernel"
        MISSING_COUNT=$((MISSING_COUNT + 1))
        return
    fi

    exp_norm=$(normalize "$expected")
    act_norm=$(normalize "$actual")

    if [ "$exp_norm" = "$act_norm" ]; then
        log_pass "$key = $exp_norm"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        log_fail "$key"
        log_info "expected: $exp_norm"
        log_info "actual  : $act_norm"
        log_info "source  : $file"
        others=$(other_sources "$key" "$file")
        if [ -n "$others" ]; then
            log_info "also set in: ${others//$'\n'/ }"
        fi
        FAIL_COUNT=$((FAIL_COUNT + 1))
        FAIL_DETAILS+=("$key (expected '$exp_norm', got '$act_norm')")
    fi
}

# Iterate over every conf file in sorted order
shopt -s nullglob
CONF_FILES=("$SYSCTL_DIR"/*.conf)
shopt -u nullglob

if [ ${#CONF_FILES[@]} -eq 0 ]; then
    log_warn "No *.conf files found in $SYSCTL_DIR"
    exit 0
fi

# De-duplicate keys: later files override earlier ones (sysctl.d semantics).
# We collect into associative arrays so the final value wins.
declare -A EXPECTED
declare -A SOURCE

for conf in "${CONF_FILES[@]}"; do
    conf_name=$(basename "$conf")
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line=$(normalize "$raw_line")
        # Skip blanks, comments (# or ;) and lines without '='.
        case "$line" in
            '' | \#* | \;*) continue ;;
            *=*) ;;
            *) continue ;;
        esac

        key=$(normalize "${line%%=*}")
        # A leading '-' only tells sysctl to ignore errors for this key.
        key="${key#-}"
        value=$(normalize "${line#*=}")

        [ -z "$key" ] && continue

        EXPECTED["$key"]="$value"
        SOURCE["$key"]="$conf_name"
    done <"$conf"
done

# Display per-file overview before running checks
log_head "--- Configuration Files Loaded ---"
for conf in "${CONF_FILES[@]}"; do
    echo "  - $(basename "$conf")"
done
echo ""

log_head "--- Parameter Checks ---"
# Check in stable (sorted) key order
mapfile -t SORTED_KEYS < <(printf '%s\n' "${!EXPECTED[@]}" | sort)
for key in "${SORTED_KEYS[@]}"; do
    check_param "$key" "${EXPECTED[$key]}" "${SOURCE[$key]}"
done

echo ""
log_head "--- Summary ---"
TOTAL=${#SORTED_KEYS[@]}
echo "Total parameters : $TOTAL"
echo "Pass             : $PASS_COUNT"
echo "Fail             : $FAIL_COUNT"
echo "Missing/Unknown  : $MISSING_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    log_head "Mismatched parameters:"
    for d in "${FAIL_DETAILS[@]}"; do
        echo "  * $d"
    done
fi

echo ""
echo "=============================================="
if [ "$FAIL_COUNT" -gt 0 ]; then
    log_fail "Kernel verification FAILED"
    echo "Hint: run 'sudo sysctl --system' to reload sysctl.d configurations;"
    echo "      keys listed under 'also set in' are overridden by another file."
    exit 1
fi

log_pass "Kernel verification PASSED"
exit 0
