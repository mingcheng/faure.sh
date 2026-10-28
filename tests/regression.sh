#!/usr/bin/env bash
# Copyright (c) 2026 mingcheng <mingcheng@apache.org>
#
# This source code is licensed under the MIT License,
# which is located in the LICENSE file in the source tree's root directory.
#
# File: regression.sh
# Author: mingcheng <mingcheng@apache.org>
# Last Modified: 2026-10-28 17:34:53
#
# Only source guarded scripts and exercise functions with command mocks.
# Never invoke the installer, setup or monitor entrypoints here.
# shellcheck disable=SC2317

set -o errexit -o nounset -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR=$(mktemp -d)
trap 'rm -f "$TEST_DIR/config" "$TEST_DIR/calls" "$TEST_DIR/output" "$TEST_DIR/rules" "$TEST_DIR/rules-next"; rmdir "$TEST_DIR"' EXIT
export FAURE_CONFIG="$TEST_DIR/config"
export IF1=wan0 IF2=wan1 LAN_IF=wan0
export TPROXY_PORT=8848 TPROXY_DNS_PORT=53
: >"$FAURE_CONFIG"
# shellcheck source=../scripts/utils.sh
source "$ROOT_DIR/scripts/utils.sh"

assert_equal() {
    if [ "$1" != "$2" ]; then
        printf 'Expected: %s\nActual:   %s\n' "$1" "$2" >&2
        return 1
    fi
}

assert_status() {
    local expected=$1 status=0
    shift
    "$@" >"$TEST_DIR/output" 2>&1 || status=$?
    if [ "$expected" -ne "$status" ]; then
        cat "$TEST_DIR/output" >&2
        assert_equal "$expected" "$status"
    fi
}

assert_calls() {
    local count
    count=$(FAURE_TEST_TEXT="$1" awk 'index($0, ENVIRON["FAURE_TEST_TEXT"]) { n++ } END { print n+0 }' "$TEST_DIR/calls")
    assert_equal "$2" "$count"
}

test_config_precedence() (
    unset IF1 IF2 LAN_IF
    # shellcheck source=../scripts/config.sh
    source "$ROOT_DIR/scripts/config.sh"
    assert_equal "eth0/eth1/eth0" "$IF1/$IF2/$LAN_IF"
    IF1=environment0
    IF2=""
    unset LAN_IF
    # shellcheck source=../scripts/config.sh
    source "$ROOT_DIR/scripts/config.sh"
    assert_equal "environment0//environment0" "$IF1/$IF2/$LAN_IF"
    printf '%s\n' 'export IF1=override0' >"$FAURE_CONFIG"
    unset LAN_IF
    # shellcheck source=../scripts/config.sh
    source "$ROOT_DIR/scripts/config.sh"
    assert_equal "override0//override0" "$IF1/$IF2/$LAN_IF"
    assert_equal "$FAURE_CONFIG" "$FAURE_CONFIG_LOADED"
)

test_single_uplink() (
    get_ip() { printf '%s' "${ADDRESS:-}"; }
    IF2=""
    assert_status 1 secondary_uplink_configured
    IF2="$IF1"
    assert_status 1 secondary_uplink_enabled
    IF2=wan1
    assert_status 0 secondary_uplink_configured
    assert_status 1 secondary_uplink_enabled
    ADDRESS=192.0.2.2
    assert_status 0 secondary_uplink_enabled
    assert_equal BOTH "$(uplink_state 1 1)"
    assert_equal IF1_ONLY "$(uplink_state 1 0)"
    assert_equal IF2_ONLY "$(uplink_state 0 1)"
    assert_equal NONE "$(uplink_state 0 0)"
)

test_empty_getters() (
    ip() { return 1; }
    IF1_GW_FALLBACK=""
    assert_equal "" "$(get_ip wan0)"
    assert_equal "" "$(get_subnet wan0)"
    assert_equal "" "$(get_gateway wan0 100)"
)

test_gateway_prefers_updated_routes() (
    ip() {
        case "$*" in
            "-4 route show default dev wan0") printf '%s\n' "$MAIN_ROUTES" ;;
            "-4 route show table 100 default dev wan0")
                printf '%s\n' 'default via 192.0.2.1 dev wan0 src 192.0.2.2'
                ;;
            "route get 192.0.2.1 dev wan0") return 0 ;;
            *) return 99 ;;
        esac
    }
    MAIN_ROUTES=$'default via 192.0.2.1 dev wan0\ndefault via 192.0.2.254 dev wan0 proto dhcp metric 100'
    assert_equal 192.0.2.254 "$(get_gateway wan0 100)"
    MAIN_ROUTES='default via 192.0.2.253 dev wan0 proto static'
    assert_equal 192.0.2.253 "$(get_gateway wan0 100)"
    MAIN_ROUTES='default via 192.0.2.254 dev wan0 proto dhcp linkdown'
    assert_equal 192.0.2.1 "$(get_gateway wan0 100)"
    MAIN_ROUTES=""
    assert_equal 192.0.2.1 "$(get_gateway wan0 100)"
)

mock_probes() {
    ip() {
        printf 'ip %s\n' "$*" >>"$TEST_DIR/calls"
        case "$*" in
            "link show wan0") return 0 ;;
            "-4 route add "*) return "${ADD_STATUS:-0}" ;;
            "-4 route del "*) return "${DELETE_STATUS:-0}" ;;
            *) return 99 ;;
        esac
    }
    ping() {
        printf 'ping %s\n' "$*" >>"$TEST_DIR/calls"
        return "${PING_STATUS:-0}"
    }
    timeout() {
        printf 'timeout %s\n' "$*" >>"$TEST_DIR/calls"
        return "${TCP_STATUS:-0}"
    }
}

test_probe_preserves_existing_routes() (
    mock_probes
    ADD_STATUS=2 PING_STATUS=1
    assert_status 1 check_connectivity wan0 192.0.2.1
    assert_calls "ip -4 route add " 2
    assert_calls "route replace" 0
    assert_calls "route del" 0
    assert_calls "ping " 2
    assert_calls "timeout " 0
)

test_probe_existing_route_icmp() (
    mock_probes
    ADD_STATUS=2
    assert_status 0 check_connectivity wan0 192.0.2.1
    assert_calls "ping " 1
    assert_calls "route del" 0
    assert_calls "timeout " 0
)

test_probe_icmp_cleanup() (
    mock_probes
    assert_status 0 check_connectivity wan0 192.0.2.1
    assert_calls "ip -4 route add 223.5.5.5/32 via 192.0.2.1 dev wan0 metric 0" 1
    assert_calls "ip -4 route del 223.5.5.5/32 via 192.0.2.1 dev wan0 metric 0" 1
    assert_calls "timeout " 0
)

test_probe_tcp_cleanup() (
    mock_probes
    PING_STATUS=1
    assert_status 0 check_connectivity wan0 192.0.2.1
    assert_calls "timeout " 1
    assert_calls "route del" 1
)

test_probe_failure_cleanup() (
    mock_probes
    PING_STATUS=1 TCP_STATUS=1
    assert_status 1 check_connectivity wan0 192.0.2.1
    assert_calls "route add" 2
    assert_calls "route del" 2
)

test_probe_without_gateway() (
    mock_probes
    PING_STATUS=1
    assert_status 1 check_connectivity wan0 ""
    assert_calls "route add" 0
    assert_calls "route del" 0
    assert_calls "timeout " 0
)

test_probe_cleanup_failure() (
    mock_probes
    DELETE_STATUS=1
    assert_status 1 check_connectivity wan0 192.0.2.1
)

test_probe_termination_cleanup() (
    mock_probes
    # Signal only the dedicated probe subshell, not the test runner.
    ping() { /bin/sh -c 'kill -TERM "$PPID"'; }
    assert_status 1 check_connectivity wan0 192.0.2.1
    assert_calls "route add" 1
    assert_calls "route del" 1
)

mock_firewall() {
    iptables() {
        printf 'iptables %s\n' "$*" >>"$TEST_DIR/calls"
        case "$3" in
            -S)
                [ "${LIST_STATUS:-0}" -eq 0 ] || return 1
                printf '%s\n' "-P $4 ACCEPT"
                cat "$TEST_DIR/rules"
                if [ "${INSERT_AFTER_LIST:-0}" -eq 1 ]; then
                    {
                        printf '%s\n' '-A PREROUTING -j DOCKER'
                        cat "$TEST_DIR/rules"
                    } >"$TEST_DIR/rules-next"
                    mv "$TEST_DIR/rules-next" "$TEST_DIR/rules"
                fi
                ;;
            -D)
                [ "${DELETE_STATUS:-0}" -eq 0 ] || return 1
                local comment="" arg previous="" quoted line found=0
                for arg in "$@"; do
                    if [ "$previous" = --comment ]; then
                        comment=$arg
                        break
                    fi
                    previous=$arg
                done
                [ -n "$comment" ] || return 1
                printf 'comment=<%s>\n' "$comment" >>"$TEST_DIR/calls"
                quoted=${comment//\\/\\\\}
                quoted=${quoted//\"/\\\"}
                while IFS= read -r line; do
                    if [ "$found" -eq 0 ] && [[ $line == *"--comment \"$quoted\" "* || $line == *"--comment $comment "* ]]; then
                        found=1
                    else
                        printf '%s\n' "$line"
                    fi
                done <"$TEST_DIR/rules" >"$TEST_DIR/rules-next"
                mv "$TEST_DIR/rules-next" "$TEST_DIR/rules"
                [ "$found" -eq 1 ]
                ;;
            -F | -X) return 0 ;;
            *) return 99 ;;
        esac
    }
}

test_delete_quoted_rules() (
    mock_firewall
    printf '%s\n' \
        '-A PREROUTING -m comment --comment "keep spaces and \"quotes\"" -j ACCEPT' \
        '-A PREROUTING -m comment --comment "remove this rule" -j REDIRECT' \
        '-A PREROUTING -m comment --comment "remove \"quotes\" \\path $HOME; *" -j REDIRECT' \
        '-A PREROUTING -m comment --comment remove -j REDIRECT' >"$TEST_DIR/rules"
    delete_rules iptables nat PREROUTING '--comment "?remove'
    assert_equal '-A PREROUTING -m comment --comment "keep spaces and \"quotes\"" -j ACCEPT' "$(cat "$TEST_DIR/rules")"
    assert_calls 'comment=<remove this rule>' 1
    assert_calls 'comment=<remove "quotes" \path $HOME; *>' 1
    assert_calls 'comment=<remove>' 1
)

test_delete_preserves_concurrent_inserts() (
    mock_firewall
    INSERT_AFTER_LIST=1
    printf '%s\n' '-A PREROUTING -m comment --comment remove -j REDIRECT' >"$TEST_DIR/rules"
    delete_rules iptables nat PREROUTING '--comment remove( |$)'
    assert_equal '-A PREROUTING -j DOCKER' "$(cat "$TEST_DIR/rules")"
)

test_dns_cleanup_idempotent() (
    # shellcheck source=../scripts/setup-tproxy.sh
    source "$ROOT_DIR/scripts/setup-tproxy.sh"
    mock_firewall
    ip() {
        printf 'ip %s\n' "$*" >>"$TEST_DIR/calls"
        [[ $* == "route flush table "* ]]
    }
    printf '%s\n' \
        '-A PREROUTING -j DOCKER' \
        '-A PREROUTING -i old0 -m comment --comment "faure-tproxy-dns" -j REDIRECT' \
        '-A PREROUTING -i old1 -m comment --comment faure-tproxy-dns -j REDIRECT' \
        '-A PREROUTING -m comment --comment "faure-tproxy-dns-other" -j ACCEPT' >"$TEST_DIR/rules"
    cleanup_firewall >/dev/null
    cleanup_firewall >/dev/null
    assert_equal $'-A PREROUTING -j DOCKER\n-A PREROUTING -m comment --comment "faure-tproxy-dns-other" -j ACCEPT' "$(cat "$TEST_DIR/rules")"
    assert_calls 'comment=<faure-tproxy-dns>' 2
    assert_calls "ip rule del priority $PRIO_TPROXY" 2
)

test_firewall_errors() (
    mock_firewall
    LIST_STATUS=1
    assert_status 1 delete_rules iptables nat PREROUTING REDIRECT
    LIST_STATUS=0 DELETE_STATUS=1
    printf '%s\n' '-A PREROUTING -m comment --comment remove -j REDIRECT' >"$TEST_DIR/rules"
    assert_status 1 delete_rules iptables nat PREROUTING REDIRECT
    DELETE_STATUS=0
    printf '%s\n' '-A PREROUTING -m comment --comment "unterminated -j REDIRECT' >"$TEST_DIR/rules"
    assert_status 1 delete_rules iptables nat PREROUTING REDIRECT
)

test_optional_ipv6_cleanup() (
    mock_firewall
    ip6tables() { return 1; }
    assert_status 0 clear_ttl_bypass wan0
)

mock_listeners() {
    ss() {
        printf 'ss %s\n' "$*" >>"$TEST_DIR/calls"
        [ "${SS_STATUS:-0}" -eq 0 ] || return 1
        [ "$*" != "${MISSING_SOCKET:-}" ] || return 0
        printf '%s\n' 'LISTEN 0 128 0.0.0.0:8848 0.0.0.0:*'
    }
}

test_all_listener_protocols() (
    # shellcheck source=../scripts/setup-tproxy.sh
    source "$ROOT_DIR/scripts/setup-tproxy.sh"
    mock_listeners
    TPROXY_WAIT_TIMEOUT=0
    assert_status 0 check_listeners
    local proto port
    for proto in t u; do
        for port in "$TPROXY_PORT" "$TPROXY_DNS_PORT"; do
            MISSING_SOCKET="-H -ln$proto sport = :$port"
            assert_status 1 check_listeners
        done
    done
)

test_listener_query_failure() (
    # shellcheck source=../scripts/setup-tproxy.sh
    source "$ROOT_DIR/scripts/setup-tproxy.sh"
    mock_listeners
    SS_STATUS=1
    assert_status 1 check_listeners
)

test_listener_deadline() (
    # shellcheck source=../scripts/setup-tproxy.sh
    source "$ROOT_DIR/scripts/setup-tproxy.sh"
    mock_listeners
    MISSING_SOCKET="-H -lnu sport = :$TPROXY_PORT"
    TPROXY_WAIT_TIMEOUT=3 TPROXY_WAIT_INTERVAL=10
    sleep() {
        printf 'sleep %s\n' "$*" >>"$TEST_DIR/calls"
        SECONDS=$((SECONDS + $1))
    }
    SECONDS=0
    assert_status 1 check_listeners
    assert_calls "sleep 3" 1
    assert_calls "sleep 10" 0
)

test_tproxy_config_validation() (
    # shellcheck source=../scripts/setup-tproxy.sh
    source "$ROOT_DIR/scripts/setup-tproxy.sh"
    assert_status 0 validate_tproxy_config
    local value
    for value in 1 65535; do
        TPROXY_PORT="$value"
        assert_status 0 validate_tproxy_config
    done
    for value in 0 65536 08 -1 abc 999999999999999999999; do
        TPROXY_PORT="$value"
        assert_status 1 validate_tproxy_config
    done
    TPROXY_PORT=8848 TPROXY_WAIT_INTERVAL=0
    assert_status 1 validate_tproxy_config
    TPROXY_WAIT_INTERVAL=2 TPROXY_WAIT_TIMEOUT=invalid
    assert_status 1 validate_tproxy_config
    TPROXY_WAIT_TIMEOUT=0
    assert_status 0 validate_tproxy_config
    TPROXY_DNS_PORT=65536
    assert_status 1 validate_tproxy_config
    TPROXY_DNS_PORT=53 LAN_IF=""
    assert_status 1 validate_tproxy_config
)

test_monitor_address_changes() (
    # shellcheck source=../scripts/monitor-uplink.sh
    source "$ROOT_DIR/scripts/monitor-uplink.sh"
    get_ip() { printf '%s' "$ADDRESS"; }
    get_gateway() { printf '%s' "${GATEWAY:-192.0.2.1}"; }
    ip() {
        case "$*" in
            "-4 route show table 100 default") printf '%s' "$ROUTE" ;;
            "route get "*) return "${GATEWAY_STATUS:-0}" ;;
            *) return 99 ;;
        esac
    }
    ADDRESS=192.0.2.2
    ROUTE="default via 192.0.2.1 dev wan0 src 192.0.2.2"
    assert_status 1 needs_restore wan0 100
    ADDRESS=192.0.2.3
    assert_status 0 needs_restore wan0 100
    ROUTE=""
    assert_status 0 needs_restore wan0 100
    ADDRESS=""
    assert_status 1 needs_restore wan0 100
    ADDRESS=192.0.2.2
    ROUTE="default via 192.0.2.1 dev wan0 src 192.0.2.2"
    GATEWAY_STATUS=1
    assert_status 0 needs_restore wan0 100
    GATEWAY_STATUS=0 GATEWAY=192.0.2.254
    assert_status 0 needs_restore wan0 100
)

mock_systemd() {
    systemctl() {
        printf 'systemctl %s\n' "$*" >>"$TEST_DIR/calls"
        case "$1" in
            is-active) return "${ACTIVE_STATUS:-1}" ;;
            is-enabled)
                printf '%s\n' "${ENABLED_STATE:-enabled}"
                [ "${ENABLED_STATE:-enabled}" = enabled ]
                ;;
            start) return "${START_STATUS:-0}" ;;
            restart) return "${RESTART_STATUS:-0}" ;;
            *) return 99 ;;
        esac
    }
}

test_tproxy_retry() (
    # shellcheck source=../scripts/monitor-uplink.sh
    source "$ROOT_DIR/scripts/monitor-uplink.sh"
    mock_systemd
    START_STATUS=1
    assert_status 1 ensure_tproxy_started
    START_STATUS=0
    assert_status 0 ensure_tproxy_started
    assert_calls "systemctl start tproxy-routing.service" 2
    assert_calls "systemctl restart " 0
)

test_tproxy_disabled_or_active() (
    # shellcheck source=../scripts/monitor-uplink.sh
    source "$ROOT_DIR/scripts/monitor-uplink.sh"
    mock_systemd
    local state
    for state in disabled masked masked-runtime; do
        ENABLED_STATE="$state"
        assert_status 0 ensure_tproxy_started
    done
    ACTIVE_STATUS=0
    assert_status 0 ensure_tproxy_started
    assert_calls "systemctl start " 0
    ACTIVE_STATUS=1 ENABLED_STATE=unknown
    assert_status 1 ensure_tproxy_started
)

test_routing_restart_failures() (
    # shellcheck source=../scripts/monitor-uplink.sh
    source "$ROOT_DIR/scripts/monitor-uplink.sh"
    mock_systemd
    RESTART_STATUS=1
    assert_status 1 trigger_restart test
    assert_calls "systemctl start " 0
    RESTART_STATUS=0
    assert_status 0 trigger_restart test
    assert_calls "systemctl restart multipath-routing.service" 2
    assert_calls "systemctl start tproxy-routing.service" 1
)

test_systemd_path_escaping() (
    # shellcheck source=../install.sh
    source "$ROOT_DIR/install.sh"
    local unit="$ROOT_DIR/systemd/multipath-routing.service"
    assert_equal 'ExecStart="/srv/faure with spaces/scripts/setup-multipath.sh"' \
        "$(render_systemd_unit '/srv/faure with spaces' "$unit" | grep '^ExecStart=')"
    assert_equal 'ExecStart="/srv/quote\"back\\percent%%dollar$and&pipe|/scripts/setup-multipath.sh"' \
        "$(render_systemd_unit '/srv/quote"back\percent%dollar$and&pipe|' "$unit" | grep '^ExecStart=')"
)

tests=(
    test_config_precedence
    test_single_uplink
    test_empty_getters
    test_gateway_prefers_updated_routes
    test_probe_preserves_existing_routes
    test_probe_existing_route_icmp
    test_probe_icmp_cleanup
    test_probe_tcp_cleanup
    test_probe_failure_cleanup
    test_probe_without_gateway
    test_probe_cleanup_failure
    test_probe_termination_cleanup
    test_delete_quoted_rules
    test_delete_preserves_concurrent_inserts
    test_dns_cleanup_idempotent
    test_firewall_errors
    test_optional_ipv6_cleanup
    test_all_listener_protocols
    test_listener_query_failure
    test_listener_deadline
    test_tproxy_config_validation
    test_monitor_address_changes
    test_tproxy_retry
    test_tproxy_disabled_or_active
    test_routing_restart_failures
    test_systemd_path_escaping
)

for test in "${tests[@]}"; do
    : >"$FAURE_CONFIG"
    : >"$TEST_DIR/calls"
    : >"$TEST_DIR/rules"
    "$test"
    printf '[PASS] %s\n' "$test"
done
printf 'Passed %s regression tests (mock commands only).\n' "${#tests[@]}"
