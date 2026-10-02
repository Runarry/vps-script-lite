# shellcheck shell=bash
# HY2 value normalization and feature gates. Sourcing this file has no effects.

proxy_hy2_ports_normalize() {
    local value="${1-}" normalized
    if ! normalized="$(jq -ern --arg value "$value" '
        $value | select(test("^[0-9]{1,5}(-[0-9]{1,5})?(,[0-9]{1,5}(-[0-9]{1,5})?)*$")) |
        split(",") | map(split("-") | map(tonumber) | [.[0], (.[1] // .[0])]) |
        select(all(.[]; .[0] >= 1 and .[1] <= 65535 and .[0] <= .[1])) |
        sort_by(.[0], .[1]) |
        reduce .[] as $range ([];
            if length > 0 and $range[0] <= (.[-1][1] + 1) then
                .[-1][1] = ([.[-1][1], $range[1]] | max)
            else . + [$range] end) |
        map(if .[0] == .[1] then .[0] | tostring
            else (.[0] | tostring) + "-" + (.[1] | tostring) end) | join(",")
    ' 2>/dev/null)"; then
        printf 'Hysteria2 端口集合需要 1–65535 的端口或递增范围，以逗号分隔。\n' >&2
        return 2
    fi
    printf '%s\n' "$normalized"
}

proxy_hy2_ports_first() {
    local ports
    ports="$(proxy_hy2_ports_normalize "${1-}")" || return $?
    printf '%s\n' "${ports%%[-,]*}"
}

proxy_hy2_ports_multiple() {
    local ports
    ports="$(proxy_hy2_ports_normalize "${1-}")" || return $?
    [[ "$ports" == *','* || "$ports" == *'-'* ]]
}

proxy_hy2_ports_contains() {
    local ports port="${2-}"
    ports="$(proxy_hy2_ports_normalize "${1-}")" || return $?
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)) || return 2
    jq -en --arg ports "$ports" --argjson port "$((10#$port))" '
        $ports | split(",") | any(.[];
            split("-") | map(tonumber) | .[0] <= $port and (.[1] // .[0]) >= $port)
    ' >/dev/null
}

proxy_hy2_ports_overlap() {
    local left right
    left="$(proxy_hy2_ports_normalize "${1-}")" || return $?
    right="$(proxy_hy2_ports_normalize "${2-}")" || return $?
    jq -en --arg left "$left" --arg right "$right" '
        def ranges: split(",") | map(split("-") | map(tonumber) | [.[0], (.[1] // .[0])]);
        ($left | ranges) as $a | ($right | ranges) as $b |
        any($a[]; . as $range | any($b[]; $range[0] <= .[1] and .[0] <= $range[1]))
    ' >/dev/null
}

proxy_hy2_node_ports() {
    local ports
    ports="$(jq -er '
        select(.port | type == "number" and floor == .) |
        (.port | tostring) +
        (if (.options.hop_ports // "") != "" then "," + .options.hop_ports else "" end)
    ' <<<"${1-}" 2>/dev/null)" || return 2
    proxy_hy2_ports_normalize "$ports"
}

proxy_hy2_interval_normalize() {
    local value="${1-}" minimum maximum
    [[ "$value" =~ ^([0-9]{1,10})(-([0-9]{1,10}))?$ ]] || {
        printf 'Hysteria2 跳跃间隔需要秒数 N 或 MIN-MAX。\n' >&2
        return 2
    }
    minimum=$((10#${BASH_REMATCH[1]}))
    maximum=$((10#${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}))
    # Xray represents each bound as int32; enforce the common representable range.
    ((minimum >= 5 && maximum >= minimum && maximum <= 2147483647)) || {
        printf 'Hysteria2 跳跃间隔必须为 5–2147483647 秒，最大值不能小于最小值。\n' >&2
        return 2
    }
    if ((minimum == maximum)); then printf '%s\n' "$minimum"
    else printf '%s-%s\n' "$minimum" "$maximum"; fi
}

proxy_hy2_feature_minimum() {
    case "${1-}:${2-}" in
        sing-box:base) printf '0.0.0' ;;
        sing-box:hop-ports) printf '1.11.0' ;;
        sing-box:bbr-profile | sing-box:gecko | sing-box:chrome-parrot | sing-box:hop-random) printf '1.14.0' ;;
        xray:base | xray:hop-ports | xray:hop-random) printf '26.3.27' ;;
        xray:bbr-profile) printf '26.4.13' ;;
        xray:gecko) printf '26.6.1' ;;
        xray:chrome-parrot) printf '26.9.8' ;;
        xray:hop-mask) printf '26.9.9' ;;
        *) return 2 ;;
    esac
}

proxy_hy2_capable() {
    local core="${1-}" version="${2-}" feature="${3-}" minimum
    [[ "$core:$feature" != sing-box:base ]] || return 0
    minimum="$(proxy_hy2_feature_minimum "$core" "$feature")" || return $?
    if declare -F proxy_core_version_at_least >/dev/null 2>&1; then
        proxy_core_version_at_least "$version" "$minimum"
    else
        # relay-uri.sh also supports use without the state/service helpers.
        jq -en --arg version "$version" --arg minimum "$minimum" '
            def rank:
                capture("^v?(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)(?:-(?<pre>[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$") |
                [(.major | tonumber), (.minor | tonumber), (.patch | tonumber),
                 (if .pre == null then 1 else 0 end),
                 ((.pre // "") | split(".") | map(if test("^[0-9]+$") then [0,tonumber] else [1,.] end))];
            ($version | rank) >= ($minimum | rank)
        ' >/dev/null 2>&1
    fi
}

proxy_hy2_require_feature() {
    local core="${1-}" version="${2-}" feature="${3-}" minimum
    [[ "$core:$feature" != sing-box:base ]] || return 0
    if [[ -z "$version" ]] && declare -F proxy_core_config_version >/dev/null 2>&1; then
        version="$(proxy_core_config_version "$core")" || return $?
    fi
    minimum="$(proxy_hy2_feature_minimum "$core" "$feature")" || return 2
    if ! proxy_hy2_capable "$core" "$version" "$feature"; then
        printf 'Hysteria2 %s 要求 %s >= %s；当前版本：%s。\n' "$feature" "$core" "$minimum" "${version:-未知}" >&2
        return 10
    fi
}
