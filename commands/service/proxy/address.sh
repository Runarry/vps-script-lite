# shellcheck shell=bash
# Shared, pure IP and hostname validators; legacy names retained for callers.

_proxy_relay_forward_valid_ipv4() {
    local value="${1:-}" part
    local -a parts=()
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    IFS=. read -r -a parts <<<"$value"
    ((${#parts[@]} == 4)) || return 1
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^[0-9]{1,3}$ ]] && ((10#$part <= 255)) || return 1
    done
}

_proxy_relay_forward_valid_ipv6() {
    local value="${1:-}" normalized left right side part ipv4_tail="" compressed=0 count=0
    local -a parts=()

    [[ "$value" == *:* && "$value" != *%* ]] || return 1
    normalized="$value"
    if [[ "$normalized" == *.* ]]; then
        ipv4_tail="${normalized##*:}"
        _proxy_relay_forward_valid_ipv4 "$ipv4_tail" || return 1
        normalized="${normalized%:*}:0:0"
    fi
    [[ "$normalized" =~ ^[0-9A-Fa-f:]+$ && "$normalized" != *:::* ]] || return 1
    if [[ "$normalized" == *::* ]]; then
        compressed=1
        left="${normalized%%::*}"
        right="${normalized#*::}"
        [[ "$right" != *::* ]] || return 1
    else
        left="$normalized"
        right=""
        [[ "$left" != :* && "$left" != *: ]] || return 1
    fi
    for side in "$left" "$right"; do
        [[ -n "$side" ]] || continue
        [[ "$side" != :* && "$side" != *: ]] || return 1
        IFS=: read -r -a parts <<<"$side"
        for part in "${parts[@]}"; do
            [[ "$part" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            count=$((count + 1))
        done
    done
    if ((compressed)); then
        ((count < 8))
    else
        ((count == 8))
    fi
}

_proxy_relay_forward_valid_hostname() {
    local value="${1:-}" label
    local -a labels=()

    [[ -n "$value" && ${#value} -le 253 && "$value" != *:* ]] || return 1
    value="${value%.}"
    [[ -n "$value" && "$value" != .* && "$value" != *. && "$value" != *..* ]] || return 1
    [[ "$value" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    IFS=. read -r -a labels <<<"$value"
    for label in "${labels[@]}"; do
        ((${#label} >= 1 && ${#label} <= 63)) || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
}

_proxy_relay_forward_valid_host_value() {
    local value="${1:-}"
    if [[ "$value" == *:* ]]; then
        _proxy_relay_forward_valid_ipv6 "$value"
    elif [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _proxy_relay_forward_valid_ipv4 "$value"
    else
        _proxy_relay_forward_valid_hostname "$value"
    fi
}

