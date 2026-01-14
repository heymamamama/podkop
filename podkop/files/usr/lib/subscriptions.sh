#
# Module: subscriptions.sh
#
# Purpose:
#   This script provides functions for fetching, parsing, and filtering
#   proxy subscriptions from remote URLs.
#
# Conventions:
#   - All functions are prefixed with: subscription_*
#
# Usage:
#   Include this script in your ash script with:
#     . /usr/lib/podkop/subscriptions.sh
#

# Constants
SUBSCRIPTION_CACHE_DIR="/tmp/podkop/subscriptions"
SUBSCRIPTION_USER_AGENT_SINGBOX="SFA/1.11.9"
SUBSCRIPTION_USER_AGENT_LINKS="podkop"

#######################################
# Initialize subscriptions cache directory
# Globals:
#   SUBSCRIPTION_CACHE_DIR
# Arguments:
#   None
# Outputs:
#   Creates cache directory if it doesn't exist
#######################################
subscription_init_cache() {
    mkdir -p "$SUBSCRIPTION_CACHE_DIR"
}

#######################################
# Generate cache filename for a subscription URL
# Arguments:
#   url: string, subscription URL
# Outputs:
#   Writes cache filename to stdout
#######################################
subscription_get_cache_filename() {
    local url="$1"
    local hash
    
    hash=$(echo "$url" | md5sum | cut -c1-16)
    echo "${SUBSCRIPTION_CACHE_DIR}/${hash}.json"
}

#######################################
# Fetch subscription from URL with auto-detection
# Arguments:
#   url: string, subscription URL
#   type: string, subscription type (auto, singbox, base64)
# Outputs:
#   Writes subscription content to stdout (JSON format)
# Returns:
#   0 on success, 1 on failure
#######################################
subscription_fetch() {
    local url="$1"
    local type="${2:-auto}"
    local content
    local user_agent

    subscription_init_cache

    case "$type" in
    singbox)
        user_agent="$SUBSCRIPTION_USER_AGENT_SINGBOX"
        ;;
    base64)
        user_agent="$SUBSCRIPTION_USER_AGENT_LINKS"
        ;;
    auto)
        # Try sing-box format first
        content=$(curl -sf -A "$SUBSCRIPTION_USER_AGENT_SINGBOX" -m 30 "$url" 2>/dev/null)
        if [ -n "$content" ] && echo "$content" | jq -e '.outbounds' >/dev/null 2>&1; then
            log "Subscription detected as sing-box format" "debug"
            echo "$content"
            return 0
        fi
        # Fallback to base64 links
        user_agent="$SUBSCRIPTION_USER_AGENT_LINKS"
        ;;
    *)
        log "Unknown subscription type: $type" "error"
        return 1
        ;;
    esac

    content=$(curl -sf -A "$user_agent" -m 30 "$url" 2>/dev/null)
    if [ -z "$content" ]; then
        log "Failed to fetch subscription from $url" "error"
        return 1
    fi

    if [ "$type" = "singbox" ]; then
        echo "$content"
        return 0
    fi

    # Parse base64 content
    subscription_parse_base64 "$content"
}

#######################################
# Parse base64-encoded subscription links
# Arguments:
#   content: string, base64-encoded content
# Outputs:
#   Writes JSON with outbounds array to stdout
#######################################
subscription_parse_base64() {
    local content="$1"
    local decoded
    local outbounds='[]'
    local i=1

    # Decode base64
    decoded=$(echo "$content" | base64 -d 2>/dev/null)
    if [ -z "$decoded" ]; then
        log "Failed to decode base64 subscription" "error"
        echo '{"outbounds":[]}'
        return 1
    fi

    # Parse each line as a proxy link
    echo "$decoded" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        local tag scheme
        scheme=$(url_get_scheme "$line")
        tag=$(echo "$line" | sed -n 's/.*#\(.*\)$/\1/p')
        tag=$(url_decode "$tag")
        
        [ -z "$tag" ] && tag="proxy-$i"
        
        # Store link and tag for later processing
        echo "$line|$tag"
        i=$((i + 1))
    done
}

#######################################
# Get outbounds from subscription with optional filtering
# Arguments:
#   url: string, subscription URL
#   type: string, subscription type (auto, singbox, base64)
#   filters: string, space-separated list of filter tags (optional)
# Outputs:
#   Writes list of outbound tags (one per line) to stdout
#######################################
subscription_get_outbound_tags() {
    local url="$1"
    local type="${2:-auto}"
    local filters="$3"
    
    local cache_file
    cache_file=$(subscription_get_cache_filename "$url")
    
    # Fetch subscription
    local content
    content=$(subscription_fetch "$url" "$type")
    if [ -z "$content" ]; then
        return 1
    fi
    
    # Check if it's sing-box format
    if echo "$content" | jq -e '.outbounds' >/dev/null 2>&1; then
        # Extract tags from sing-box JSON
        local tags
        tags=$(echo "$content" | jq -r '.outbounds[]?.tag // empty')
        
        if [ -z "$filters" ]; then
            echo "$tags"
        else
            # Filter by tags
            echo "$tags" | while IFS= read -r tag; do
                for filter in $filters; do
                    if echo "$tag" | grep -qi "$filter"; then
                        echo "$tag"
                        break
                    fi
                done
            done
        fi
    else
        # Base64 format - tags are after the pipe
        echo "$content" | while IFS='|' read -r link tag; do
            if [ -z "$filters" ]; then
                echo "$tag"
            else
                for filter in $filters; do
                    if echo "$tag" | grep -qi "$filter"; then
                        echo "$tag"
                        break
                    fi
                done
            fi
        done
    fi
}

#######################################
# Get outbounds JSON from subscription
# Arguments:
#   url: string, subscription URL
#   type: string, subscription type (auto, singbox, base64)
#   filters: string, space-separated list of filter tags (optional)
#   section: string, section name for tagging
# Outputs:
#   Writes JSON array of outbounds to stdout
#######################################
subscription_get_outbounds_json() {
    local url="$1"
    local type="${2:-auto}"
    local filters="$3"
    local section="$4"
    
    local content
    content=$(subscription_fetch "$url" "$type")
    if [ -z "$content" ]; then
        echo '[]'
        return 1
    fi
    
    # Check if it's sing-box format
    if echo "$content" | jq -e '.outbounds' >/dev/null 2>&1; then
        if [ -z "$filters" ]; then
            echo "$content" | jq '.outbounds'
        else
            # Build jq filter for tags
            local jq_filter
            jq_filter=$(echo "$filters" | tr ' ' '\n' | sed 's/.*/"&"/' | paste -sd, | sed 's/^/[/;s/$/]/')
            
            echo "$content" | jq --argjson filters "$jq_filter" '
                .outbounds | map(
                    select(
                        .tag as $tag | 
                        $filters | any(. as $f | $tag | test($f; "i"))
                    )
                )
            '
        fi
    else
        # Base64 format - return empty for now, needs proxy string parsing
        log "Base64 subscription requires proxy string parsing" "debug"
        echo '[]'
    fi
}

#######################################
# Get proxy links from base64 subscription with filtering
# Arguments:
#   url: string, subscription URL
#   filters: string, space-separated list of filter tags (optional)
# Outputs:
#   Writes list of proxy links (one per line) to stdout
#######################################
subscription_get_proxy_links() {
    local url="$1"
    local filters="$2"
    
    local content
    content=$(curl -sf -A "$SUBSCRIPTION_USER_AGENT_LINKS" -m 30 "$url" 2>/dev/null)
    if [ -z "$content" ]; then
        log "Failed to fetch subscription from $url" "error"
        return 1
    fi
    
    # Decode base64
    local decoded
    decoded=$(echo "$content" | base64 -d 2>/dev/null)
    if [ -z "$decoded" ]; then
        log "Failed to decode base64 subscription" "error"
        return 1
    fi
    
    # Parse and filter
    echo "$decoded" | while IFS= read -r line; do
        [ -z "$line" ] && continue
        
        local tag
        tag=$(echo "$line" | sed -n 's/.*#\(.*\)$/\1/p')
        tag=$(url_decode "$tag")
        
        if [ -z "$filters" ]; then
            echo "$line"
        else
            for filter in $filters; do
                if echo "$tag" | grep -qi "$filter"; then
                    echo "$line"
                    break
                fi
            done
        fi
    done
}

#######################################
# Cache subscription data
# Arguments:
#   url: string, subscription URL
#   content: string, subscription content (JSON)
#######################################
subscription_cache_save() {
    local url="$1"
    local content="$2"
    
    local cache_file
    cache_file=$(subscription_get_cache_filename "$url")
    
    echo "$content" > "$cache_file"
    log "Subscription cached to $cache_file" "debug"
}

#######################################
# Load cached subscription
# Arguments:
#   url: string, subscription URL
# Outputs:
#   Writes cached content to stdout or empty string if not cached
#######################################
subscription_cache_load() {
    local url="$1"
    
    local cache_file
    cache_file=$(subscription_get_cache_filename "$url")
    
    if [ -f "$cache_file" ]; then
        cat "$cache_file"
    fi
}

#######################################
# Clear subscription cache
# Arguments:
#   url: string, subscription URL (optional, clears all if not provided)
#######################################
subscription_cache_clear() {
    local url="$1"
    
    if [ -n "$url" ]; then
        local cache_file
        cache_file=$(subscription_get_cache_filename "$url")
        rm -f "$cache_file"
    else
        rm -f "${SUBSCRIPTION_CACHE_DIR}"/*.json
    fi
}

#######################################
# Update all subscriptions for a section
# Arguments:
#   section: string, section name
# Globals:
#   Uses UCI config
#######################################
subscription_update_section() {
    local section="$1"
    
    local subscription_url subscription_type
    config_get subscription_url "$section" "subscription_url"
    config_get subscription_type "$section" "subscription_type" "auto"
    
    if [ -z "$subscription_url" ]; then
        return 0
    fi
    
    log "Updating subscription for section $section" "info"
    
    local content
    content=$(subscription_fetch "$subscription_url" "$subscription_type")
    
    if [ -n "$content" ]; then
        subscription_cache_save "$subscription_url" "$content"
        log "Subscription updated successfully for section $section" "info"
        return 0
    else
        log "Failed to update subscription for section $section" "error"
        return 1
    fi
}

#######################################
# Get selected outbounds for a section (manual selection mode)
# Arguments:
#   section: string, section name
# Outputs:
#   Writes list of selected outbound tags to stdout
#######################################
subscription_get_selected_outbounds() {
    local section="$1"
    
    local selected
    config_get selected "$section" "subscription_selected"
    
    echo "$selected"
}
