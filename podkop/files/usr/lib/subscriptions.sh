#
# Module: subscriptions.sh
#
# Purpose:
#   This script provides functions for fetching, caching, parsing, and filtering
#   proxy subscriptions from remote URLs.
#

[ -z "$SUBSCRIPTION_CACHE_DIR" ] && SUBSCRIPTION_CACHE_DIR="/tmp/podkop/subscriptions"
[ -z "$SUBSCRIPTION_USER_AGENT_SINGBOX" ] && SUBSCRIPTION_USER_AGENT_SINGBOX="singbox/"
[ -z "$SUBSCRIPTION_USER_AGENT_LINKS" ] && SUBSCRIPTION_USER_AGENT_LINKS="singbox/"
[ -z "$SUBSCRIPTION_DEVICE_OS" ] && SUBSCRIPTION_DEVICE_OS="OpenWrt Linux"
[ -z "$SUBSCRIPTION_HWID_LENGTH" ] && SUBSCRIPTION_HWID_LENGTH="12"

subscription_init_cache() {
    mkdir -p "$SUBSCRIPTION_CACHE_DIR"
}

subscription_get_cache_filename() {
    local url="$1"
    local type="${2:-auto}"
    local hash

    hash=$(printf '%s|%s' "$type" "$url" | md5sum | cut -c1-16)
    echo "${SUBSCRIPTION_CACHE_DIR}/${hash}.cache"
}

subscription_get_device_model() {
    if [ -f /tmp/sysinfo/model ]; then
        tr -d '\r\n' < /tmp/sysinfo/model
    else
        echo "unknown"
    fi
}

subscription_get_kernel_version() {
    uname -r 2> /dev/null || echo "unknown"
}

subscription_get_device_mac() {
    local candidate mac

    for candidate in br-lan lan eth0 eth1; do
        if [ -f "/sys/class/net/$candidate/address" ]; then
            mac=$(tr -d '\r\n' < "/sys/class/net/$candidate/address")
            [ -n "$mac" ] && echo "$mac" && return 0
        fi
    done

    for candidate in /sys/class/net/*/address; do
        [ ! -f "$candidate" ] && continue
        case "$candidate" in
        */lo/address) continue ;;
        esac

        mac=$(tr -d '\r\n' < "$candidate")
        [ -n "$mac" ] && echo "$mac" && return 0
    done

    echo "00:00:00:00:00:00"
}

subscription_get_hwid() {
    local source

    source="$(subscription_get_device_mac)$(subscription_get_device_model)"
    printf '%s' "$source" | md5sum | cut -c1-"$SUBSCRIPTION_HWID_LENGTH"
}

subscription_fetch_http() {
    local url="$1"
    local user_agent="${2:-$SUBSCRIPTION_USER_AGENT_SINGBOX}"
    local device_model kernel_version hwid

    device_model="$(subscription_get_device_model)"
    kernel_version="$(subscription_get_kernel_version)"
    hwid="$(subscription_get_hwid)"

    curl -sf -m 30 \
        -A "$user_agent" \
        -H "X-HWID: $hwid" \
        -H "X-Device-OS: $SUBSCRIPTION_DEVICE_OS" \
        -H "X-Device-Model: $device_model" \
        -H "X-Ver-OS: $kernel_version" \
        "$url" 2> /dev/null
}

subscription_detect_format() {
    local content="$1"

    if echo "$content" | jq -e '.outbounds and (.outbounds | type == "array")' > /dev/null 2>&1; then
        echo "singbox"
    else
        echo "base64"
    fi
}

subscription_parse_base64() {
    local content="$1"
    local decoded
    local i=1

    decoded=$(printf '%s' "$content" | tr -d '\r\n\t ' | base64 -d 2> /dev/null)
    if [ -z "$decoded" ]; then
        log "Failed to decode base64 subscription" "error"
        return 1
    fi

    while IFS= read -r line; do
        [ -z "$line" ] && continue

        local tag
        tag=$(echo "$line" | sed -n 's/.*#\(.*\)$/\1/p')
        tag=$(url_decode "$tag")

        [ -z "$tag" ] && tag="proxy-$i"

        printf '%s|%s\n' "$line" "$tag"
        i=$((i + 1))
    done <<EOF
$(printf '%s\n' "$decoded" | tr -d '\r')
EOF
}

subscription_fetch_remote() {
    local url="$1"
    local type="${2:-auto}"
    local content detected_format

    subscription_init_cache

    case "$type" in
    singbox | base64 | auto) ;;
    *)
        log "Unknown subscription type: $type" "error"
        return 1
        ;;
    esac

    content=$(subscription_fetch_http "$url" "$SUBSCRIPTION_USER_AGENT_SINGBOX")
    if [ -z "$content" ]; then
        log "Failed to fetch subscription from $url" "error"
        return 1
    fi

    detected_format="$(subscription_detect_format "$content")"

    case "$type" in
    singbox)
        if [ "$detected_format" != "singbox" ]; then
            log "Subscription from $url is not in sing-box format" "error"
            return 1
        fi
        printf '%s' "$content"
        ;;
    base64)
        subscription_parse_base64 "$content"
        ;;
    auto)
        if [ "$detected_format" = "singbox" ]; then
            log "Subscription detected as sing-box format" "debug"
            printf '%s' "$content"
        else
            log "Subscription detected as base64 links format" "debug"
            subscription_parse_base64 "$content"
        fi
        ;;
    esac
}

subscription_cache_save() {
    local url="$1"
    local type="${2:-auto}"
    local content="$3"
    local cache_file

    cache_file=$(subscription_get_cache_filename "$url" "$type")

    printf '%s' "$content" > "$cache_file"
    log "Subscription cached to $cache_file" "debug"
}

subscription_cache_load() {
    local url="$1"
    local type="${2:-auto}"
    local cache_file

    cache_file=$(subscription_get_cache_filename "$url" "$type")

    if [ -f "$cache_file" ]; then
        cat "$cache_file"
    fi
}

subscription_cache_clear() {
    local url="$1"
    local type="${2:-auto}"

    if [ -n "$url" ]; then
        rm -f "$(subscription_get_cache_filename "$url" "$type")"
    else
        rm -f "${SUBSCRIPTION_CACHE_DIR}"/*.cache
    fi
}

subscription_load_content() {
    local url="$1"
    local type="${2:-auto}"
    local content

    subscription_init_cache

    content=$(subscription_cache_load "$url" "$type")
    if [ -n "$content" ]; then
        log "Using cached subscription for $url" "debug"
        printf '%s' "$content"
        return 0
    fi

    content=$(subscription_fetch_remote "$url" "$type")
    if [ -z "$content" ]; then
        return 1
    fi

    subscription_cache_save "$url" "$type" "$content"
    printf '%s' "$content"
}

subscription_append_list_item() {
    local value="$1"
    local filepath="$2"

    printf '%s\n' "$value" >> "$filepath"
}

subscription_get_config_list() {
    local section="$1"
    local option="$2"
    local tmpfile

    tmpfile=$(mktemp)
    config_list_foreach "$section" "$option" subscription_append_list_item "$tmpfile"

    if [ -s "$tmpfile" ]; then
        cat "$tmpfile"
    fi

    rm -f "$tmpfile"
}

subscription_value_matches_filters() {
    local value="$1"
    local filters="$2"

    [ -z "$filters" ] && return 0

    while IFS= read -r filter; do
        [ -z "$filter" ] && continue
        if printf '%s\n' "$value" | grep -Fqi "$filter"; then
            return 0
        fi
    done <<EOF
$filters
EOF

    return 1
}

subscription_value_in_list() {
    local value="$1"
    local list="$2"

    [ -z "$list" ] && return 1

    while IFS= read -r item; do
        [ -z "$item" ] && continue
        [ "$item" = "$value" ] && return 0
    done <<EOF
$list
EOF

    return 1
}

subscription_should_include_tag() {
    local tag="$1"
    local filters="$2"
    local selected="$3"
    local mode="${4:-filter}"
    local filter_match=1
    local selected_match=1

    if subscription_value_matches_filters "$tag" "$filters"; then
        filter_match=0
    fi

    if subscription_value_in_list "$tag" "$selected"; then
        selected_match=0
    fi

    case "$mode" in
    filter)
        [ -z "$filters" ] && return 0
        return "$filter_match"
        ;;
    select)
        [ -z "$selected" ] && return 0
        return "$selected_match"
        ;;
    both)
        [ -z "$filters" ] && [ -z "$selected" ] && return 0
        [ "$filter_match" -eq 0 ] && return 0
        [ "$selected_match" -eq 0 ] && return 0
        return 1
        ;;
    *)
        [ -z "$filters" ] && return 0
        return "$filter_match"
        ;;
    esac
}

subscription_get_outbound_tags() {
    local url="$1"
    local type="${2:-auto}"
    local filters="$3"
    local selected="$4"
    local mode="${5:-filter}"
    local outbounds_json proxy_links

    outbounds_json=$(subscription_get_outbounds_json "$url" "$type" "$filters" "$selected" "$mode")
    if [ -n "$outbounds_json" ] && [ "$outbounds_json" != "[]" ]; then
        echo "$outbounds_json" | jq -r '.[]?.tag // empty'
        return 0
    fi

    proxy_links=$(subscription_get_proxy_links "$url" "$type" "$filters" "$selected" "$mode")
    if [ -n "$proxy_links" ]; then
        while IFS='|' read -r _link tag; do
            [ -n "$tag" ] && printf '%s\n' "$tag"
        done <<EOF
$proxy_links
EOF
    fi
}

subscription_get_outbounds_json() {
    local url="$1"
    local type="${2:-auto}"
    local filters="$3"
    local selected="$4"
    local mode="${5:-filter}"
    local content tmp_candidates tmp_filtered outbound tag

    content=$(subscription_load_content "$url" "$type")
    if [ -z "$content" ]; then
        echo '[]'
        return 1
    fi

    if ! echo "$content" | jq -e '.outbounds and (.outbounds | type == "array")' > /dev/null 2>&1; then
        log "Subscription content for $url is not a sing-box JSON config" "debug"
        echo '[]'
        return 0
    fi

    tmp_candidates=$(mktemp)
    tmp_filtered=$(mktemp)

    echo "$content" | jq -c '.outbounds[]? |
        select((.tag // "") != "") |
        select((.type // "") as $type | ["selector", "urltest", "direct", "block", "dns"] | index($type) | not)' \
        > "$tmp_candidates"

    while IFS= read -r outbound; do
        [ -z "$outbound" ] && continue
        tag=$(echo "$outbound" | jq -r '.tag // empty')
        [ -z "$tag" ] && continue

        if subscription_should_include_tag "$tag" "$filters" "$selected" "$mode"; then
            printf '%s\n' "$outbound" >> "$tmp_filtered"
        fi
    done < "$tmp_candidates"

    if [ -s "$tmp_filtered" ]; then
        jq -s '.' "$tmp_filtered"
    else
        echo '[]'
    fi

    rm -f "$tmp_candidates" "$tmp_filtered"
}

subscription_get_proxy_links() {
    local url="$1"
    local type="${2:-auto}"
    local filters="$3"
    local selected="$4"
    local mode="${5:-filter}"
    local content tmp_content link tag

    content=$(subscription_load_content "$url" "$type")
    if [ -z "$content" ]; then
        return 1
    fi

    if echo "$content" | jq -e '.outbounds and (.outbounds | type == "array")' > /dev/null 2>&1; then
        log "Subscription content for $url is not a base64 links subscription" "debug"
        return 1
    fi

    tmp_content=$(mktemp)
    printf '%s\n' "$content" > "$tmp_content"

    while IFS='|' read -r link tag; do
        [ -z "$link" ] && continue

        if subscription_should_include_tag "$tag" "$filters" "$selected" "$mode"; then
            printf '%s|%s\n' "$link" "$tag"
        fi
    done < "$tmp_content"

    rm -f "$tmp_content"
}

subscription_update_section() {
    local section="$1"
    local subscription_url subscription_type content

    config_get subscription_url "$section" "subscription_url"
    config_get subscription_type "$section" "subscription_type" "auto"

    if [ -z "$subscription_url" ]; then
        return 0
    fi

    log "Updating subscription for section $section" "info"

    content=$(subscription_fetch_remote "$subscription_url" "$subscription_type")
    if [ -z "$content" ]; then
        log "Failed to update subscription for section $section" "error"
        return 1
    fi

    subscription_cache_save "$subscription_url" "$subscription_type" "$content"
    log "Subscription updated successfully for section $section" "info"
    return 0
}

subscription_get_selected_outbounds() {
    local section="$1"

    subscription_get_config_list "$section" "subscription_selected"
}
