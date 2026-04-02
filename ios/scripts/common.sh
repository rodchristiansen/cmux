#!/bin/bash
# Shared helpers for iOS build scripts

copy_local_config_if_present() {
    local app_path="$1"
    local config_source="$2"
    if [ -f "$config_source" ] && [ -d "$app_path" ]; then
        cp "$config_source" "$app_path/LocalConfig.plist"
    fi
}

get_mac_reachable_ip() {
    # Prefer Tailscale IP (required for iPhone connectivity)
    local ts_ip
    ts_ip=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4 2>/dev/null || tailscale ip -4 2>/dev/null)
    if [ -n "$ts_ip" ]; then
        echo "$ts_ip"
        return
    fi
    # Fallback: scan utun interfaces for Tailscale 100.x range
    for i in $(seq 0 15); do
        local ip
        ip=$(ifconfig utun$i 2>/dev/null | grep "inet " | awk '{print $2}')
        if [ -n "$ip" ] && [[ "$ip" == 100.* ]]; then
            echo "$ip"
            return
        fi
    done
    # Last resort: LAN IP
    ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null
}

rewrite_localhost_for_device() {
    local plist_path="$1"
    local mac_ip
    mac_ip="$(get_mac_reachable_ip)"
    if [ -n "$mac_ip" ] && [ -f "$plist_path" ]; then
        local ip_source="LAN"
        if [[ "$mac_ip" == 100.* ]]; then
            ip_source="Tailscale"
        fi
        sed -i '' "s|localhost|$mac_ip|g; s|127\.0\.0\.1|$mac_ip|g" "$plist_path"
        echo "  → Rewrote localhost → $mac_ip ($ip_source) in $(basename "$plist_path")"
    fi
}
