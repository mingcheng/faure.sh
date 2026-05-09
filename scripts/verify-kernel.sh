#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
# 
# Verify kernel parameters against the configurations defined in sysctl.d/
#
# This script parses every *.conf file under the project's sysctl.d/ directory,
# extracts each `key = value` pair, then compares it with the runtime value
# reported by `sysctl`. A summary of PASS/FAIL/MISSING entries is printed at
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
# Last Modified: 2026-05-09 16:49:48
##

set -u

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_info() { echo -e "       $1"; }
log_head() { echo -e "${CYAN}$1${NC}"; }

# Locate sysctl.d directory relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYSCTL_DIR="${SYSCTL_DIR:-$SCRIPT_DIR/../sysctl.d}"

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

# Normalize whitespace: collapse all runs of whitespace into a single space and trim
normalize() {
    # shellcheck disable=SC2001
    echo "$1" | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//'
}

check_param() {
    local key="$1"
    local expected="$2"
    local file="$3"

    local actual
    if ! actual=$(sysctl -n "$key" 2>/dev/null); then
        log_warn "$key (from $file): not available on this kernel"
        MISSING_COUNT=$((MISSING_COUNT + 1))
        return
    fi

    local exp_norm act_norm
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
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        # Strip leading whitespace
        line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        # Skip blanks, comments (# or ;)
        [ -z "$line" ] && continue
        case "$line" in
            \#*|\;*) continue ;;
        esac
        # Must contain '='
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac

        key="${line%%=*}"
        value="${line#*=}"
        # Trim
        key=$(normalize "$key")
        value=$(normalize "$value")
        # Strip trailing inline comments from value (sysctl does not support them, but be defensive)
        value="${value%%#*}"
        value=$(normalize "$value")

        [ -z "$key" ] && continue

        EXPECTED["$key"]="$value"
        SOURCE["$key"]="$(basename "$conf")"
    done < "$conf"
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
echo -e "${GREEN}Pass${NC}             : $PASS_COUNT"
echo -e "${RED}Fail${NC}             : $FAIL_COUNT"
echo -e "${YELLOW}Missing/Unknown${NC}  : $MISSING_COUNT"

if [ $FAIL_COUNT -gt 0 ]; then
    echo ""
    log_head "Mismatched parameters:"
    for d in "${FAIL_DETAILS[@]}"; do
        echo "  * $d"
    done
fi

echo ""
echo "=============================================="
if [ $FAIL_COUNT -gt 0 ]; then
    log_fail "Kernel verification FAILED"
    echo "Hint: run 'sudo sysctl --system' to reload sysctl.d configurations."
    exit 1
fi

log_pass "Kernel verification PASSED"
exit 0
