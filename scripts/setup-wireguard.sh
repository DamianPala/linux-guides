#!/bin/bash
#
# WireGuard Setup Script
#
# Usage: setup-wireguard [options] [interface]
#
# Auto-detects configured WireGuard interfaces and shows management menu.
# If no interfaces found, offers to run setup wizard.
#
# Arguments:
#   interface         WireGuard interface name (auto-detected or specified)
#
# Options:
#   -h, --help        Show this help
#   -i, --install     Run setup wizard (server or client)
#   -l, --list        List peers and exit
#   -a, --add         Add a peer and exit
#   -r, --remove      Remove a peer and exit
#
# Examples:
#   setup-wireguard                   # Auto-detect interfaces, show menu
#   setup-wireguard -i                # Run setup wizard
#   setup-wireguard -l                # List peers (auto-detect interface)
#   setup-wireguard -a wg1            # Add peer to wg1
#   setup-wireguard wg0               # Management menu for wg0
#
# Features:
#   1.  Auto-install WireGuard + qrencode if missing (apt)
#   2.  Server/client mode in one script
#   3.  Key generation (private + public) if not provided
#   4.  Interactive prompts with editable defaults
#   5.  Preshared key (PSK) auto-generated per peer (post-quantum layer)
#   6.  QR code for client config (scan with WireGuard mobile app)
#   7.  Client .conf file generation + save to ~/
#   8.  Peer management: add / list / remove / uninstall
#   9.  Hot-reload after adding peer (wg syncconf, no downtime)
#   10. Policy routing for full tunnel (table 200, preserves LAN access)
#   11. Idempotent PostUp/PostDown rules (grep before add)
#   12. NAT/MASQUERADE on server (auto-detect iptables or nftables)
#   13. sysctl ip_forward + src_valid_mark (idempotent, /etc/sysctl.d/)
#   14. Auto-detect default network interface
#   15. Public key as comment in config for easy reference
#   16. Peer name as comment in [Peer] block
#   17. Permissions: root:root 600 on config files
#   18. systemctl enable + start wg-quick
#   19. DNS in client config (configurable)
#   20. Client AllowedIPs / PersistentKeepalive configurable

set -euo pipefail

# --- Helpers ---

is_installed() {
    dpkg -s "$1" &>/dev/null
}

prompt() {
    local prompt_text="$1"
    local default_value="${2:-}"
    read -r -e -i "$default_value" -p "$prompt_text: " input
    echo "${input:-$default_value}"
}

get_wg_conf_dir() {
    echo "/etc/wireguard"
}

get_wg_conf_file() {
    echo "$(get_wg_conf_dir)/$1.conf"
}

get_local_interface() {
    ip route | awk '/^default/{print $5; exit}'
}

# Detect configured WireGuard interfaces from /etc/wireguard/*.conf
detect_interfaces() {
    sudo find /etc/wireguard -maxdepth 1 -name '*.conf' -printf '%f\n' 2>/dev/null \
        | sed 's/\.conf$//' | grep . | sort
}

# Pick interface: use provided name, auto-detect, or prompt
pick_interface() {
    local provided="$1"

    if [[ -n "$provided" ]]; then
        echo "$provided"
        return
    fi

    local interfaces
    interfaces="$(detect_interfaces)"
    local count
    count="$(echo "$interfaces" | grep -c . || true)"

    if [[ "$count" -eq 0 ]]; then
        echo ""
        return
    elif [[ "$count" -eq 1 ]]; then
        echo "$interfaces"
        return
    fi

    echo "Available interfaces:" >&2
    local i=1
    while IFS= read -r iface; do
        echo "  $i) $iface" >&2
        i=$((i + 1))
    done <<< "$interfaces"
    echo "" >&2

    local choice
    read -r -p "Select interface [1]: " choice
    choice="${choice:-1}"
    echo "$interfaces" | sed -n "${choice}p"
}

get_nat_postup() {
    local iface="$1"
    if command -v iptables &>/dev/null; then
        echo "iptables -t nat -A POSTROUTING -o $iface -j MASQUERADE"
    elif command -v nft &>/dev/null; then
        echo "nft delete table inet wg-nat 2>/dev/null; nft add table inet wg-nat; nft add chain inet wg-nat postrouting { type nat hook postrouting priority 100 \\; }; nft add rule inet wg-nat postrouting oifname $iface masquerade"
    else
        echo "echo 'ERROR: no iptables or nft found'"
    fi
}

get_nat_postdown() {
    local iface="$1"
    if command -v iptables &>/dev/null; then
        echo "iptables -t nat -D POSTROUTING -o $iface -j MASQUERADE"
    elif command -v nft &>/dev/null; then
        echo "nft delete table inet wg-nat"
    else
        echo "echo 'ERROR: no iptables or nft found'"
    fi
}

# --- Peer management ---

list_peers() {
    local wg_interface="$1"
    local conf_file
    conf_file="$(get_wg_conf_file "$wg_interface")"

    if ! sudo test -f "$conf_file"; then
        echo "Config file not found: $conf_file"
        return 1
    fi

    echo "Peers for $wg_interface:"
    echo "---"

    local peer_name=""
    local peer_pubkey=""
    local peer_psk=""
    local peer_allowed=""
    local peer_endpoint=""
    local count=0

    while IFS= read -r line; do
        # Trim whitespace
        line="$(echo "$line" | xargs)"

        # Detect peer comment (name)
        if [[ "$line" =~ ^\[Peer\].*#\ *(.*) ]]; then
            # Print previous peer if exists
            if [[ -n "$peer_pubkey" ]]; then
                count=$((count + 1))
                echo "  $count. ${peer_name:-<unnamed>}"
                echo "     PublicKey:  $peer_pubkey"
                echo "     AllowedIPs: $peer_allowed"
                [[ -n "$peer_endpoint" ]] && echo "     Endpoint:   $peer_endpoint"
                [[ -n "$peer_psk" ]] && echo "     PresharedKey: (set)"
                echo ""
            fi
            peer_name="${BASH_REMATCH[1]}"
            peer_pubkey=""
            peer_psk=""
            peer_allowed=""
            peer_endpoint=""
        elif [[ "$line" == "[Peer]" ]]; then
            if [[ -n "$peer_pubkey" ]]; then
                count=$((count + 1))
                echo "  $count. ${peer_name:-<unnamed>}"
                echo "     PublicKey:  $peer_pubkey"
                echo "     AllowedIPs: $peer_allowed"
                [[ -n "$peer_endpoint" ]] && echo "     Endpoint:   $peer_endpoint"
                [[ -n "$peer_psk" ]] && echo "     PresharedKey: (set)"
                echo ""
            fi
            peer_name=""
            peer_pubkey=""
            peer_psk=""
            peer_allowed=""
            peer_endpoint=""
        elif [[ "$line" =~ ^PublicKey\ *=\ *(.*) ]]; then
            peer_pubkey="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^PresharedKey\ *=\ *(.*) ]]; then
            peer_psk="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^AllowedIPs\ *=\ *(.*) ]]; then
            peer_allowed="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^Endpoint\ *=\ *(.*) ]]; then
            peer_endpoint="${BASH_REMATCH[1]}"
        fi
    done < <(sudo cat "$conf_file")

    # Print last peer
    if [[ -n "$peer_pubkey" ]]; then
        count=$((count + 1))
        echo "  $count. ${peer_name:-<unnamed>}"
        echo "     PublicKey:  $peer_pubkey"
        echo "     AllowedIPs: $peer_allowed"
        [[ -n "$peer_endpoint" ]] && echo "     Endpoint:   $peer_endpoint"
        [[ -n "$peer_psk" ]] && echo "     PresharedKey: (set)"
        echo ""
    fi

    if [[ $count -eq 0 ]]; then
        echo "  (no peers configured)"
    else
        echo "Total: $count peer(s)"
    fi
}

add_peer() {
    local wg_interface="$1"
    local conf_file
    conf_file="$(get_wg_conf_file "$wg_interface")"

    if ! sudo test -f "$conf_file"; then
        echo "Config file not found: $conf_file"
        return 1
    fi

    local peer_name
    peer_name="$(prompt "Enter Peer Name" "")"
    if [[ -z "$peer_name" ]]; then
        echo "Peer name is required."
        return 1
    fi
    if [[ ! "$peer_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Peer name can only contain letters, numbers, dashes, and underscores."
        return 1
    fi

    local peer_private_key
    peer_private_key="$(prompt "Enter Peer Private Key (leave empty to generate)" "")"
    if [[ -z "$peer_private_key" ]]; then
        peer_private_key="$(wg genkey)"
        echo "Generated Peer Private Key: $peer_private_key"
    fi
    local peer_public_key
    peer_public_key="$(echo "$peer_private_key" | wg pubkey)"
    echo "Peer Public Key: $peer_public_key"

    local peer_psk
    peer_psk="$(wg genpsk)"
    echo "Generated PresharedKey (for both sides)"

    local peer_allowed_ips
    peer_allowed_ips="$(prompt "Enter Peer AllowedIPs (on server side)" "")"

    # Append peer to server config
    {
        echo ""
        echo "[Peer] # $peer_name"
        echo "PublicKey = $peer_public_key"
        echo "PresharedKey = $peer_psk"
        echo "AllowedIPs = $peer_allowed_ips"
    } | sudo tee -a "$conf_file" > /dev/null

    echo ""
    echo "Peer '$peer_name' added to $conf_file"

    # Reload without dropping existing connections
    sudo bash -c 'wg syncconf "$1" <(wg-quick strip "$1")' -- "$wg_interface"
    echo "Config reloaded (wg syncconf)."

    # Generate client config
    echo ""
    echo "--- Client config for '$peer_name' ---"

    # Read server info from config
    local server_private_key server_listen_port server_public_key
    server_private_key="$(sudo grep -m1 '^PrivateKey' "$conf_file" | awk -F' = ' '{print $2}')"
    server_public_key="$(echo "$server_private_key" | wg pubkey)"
    server_listen_port="$(sudo grep -m1 '^ListenPort' "$conf_file" | awk -F' = ' '{print $2}')"
    local server_mtu
    server_mtu="$(sudo grep -m1 '^MTU' "$conf_file" | awk -F' = ' '{print $2}')"

    local server_endpoint
    server_endpoint="$(prompt "Enter server Endpoint (public IP or domain)" "")"

    local client_ip
    client_ip="$(prompt "Enter client IP (e.g. 10.0.0.2/24)" "")"

    local client_allowed_ips
    client_allowed_ips="$(prompt "Enter client AllowedIPs" "0.0.0.0/0")"

    local client_dns_default=""
    [[ "$client_allowed_ips" == "0.0.0.0/0" ]] && client_dns_default="1.1.1.1,8.8.8.8"
    local client_dns
    client_dns="$(prompt "Enter client DNS (empty = use system DNS)" "$client_dns_default")"

    local client_keepalive
    client_keepalive="$(prompt "Enter PersistentKeepalive (0 to disable)" "25")"

    local client_conf=""
    client_conf+="[Interface]"$'\n'
    client_conf+="PrivateKey = $peer_private_key"$'\n'
    client_conf+="Address = $client_ip"$'\n'
    [[ -n "$client_dns" ]] && client_conf+="DNS = $client_dns"$'\n'
    [[ -n "$server_mtu" ]] && client_conf+="MTU = $server_mtu"$'\n'
    client_conf+=""$'\n'
    client_conf+="[Peer]"$'\n'
    client_conf+="PublicKey = $server_public_key"$'\n'
    client_conf+="PresharedKey = $peer_psk"$'\n'
    client_conf+="Endpoint = $server_endpoint:$server_listen_port"$'\n'
    client_conf+="AllowedIPs = $client_allowed_ips"$'\n'
    [[ "$client_keepalive" != "0" ]] && client_conf+="PersistentKeepalive = $client_keepalive"$'\n'

    local client_conf_file="$HOME/${wg_interface}-client-${peer_name}.conf"
    echo "$client_conf" > "$client_conf_file"
    chmod 600 "$client_conf_file"
    echo ""
    echo "$client_conf"
    echo "Saved to: $client_conf_file"

    # QR code
    if command -v qrencode &>/dev/null; then
        echo ""
        echo "--- QR Code (scan with WireGuard mobile app) ---"
        echo "$client_conf" | qrencode -t ansiutf8
    else
        echo ""
        echo "Install qrencode for QR code: sudo apt install qrencode"
    fi
}

remove_peer() {
    local wg_interface="$1"
    local conf_file
    conf_file="$(get_wg_conf_file "$wg_interface")"

    if ! sudo test -f "$conf_file"; then
        echo "Config file not found: $conf_file"
        return 1
    fi

    # Collect peer names and their public keys
    local -a peer_names=()
    local -a peer_pubkeys=()
    local current_name=""
    local current_pubkey=""
    local in_peer=false

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[Peer\].*#\ *(.*) ]]; then
            if $in_peer && [[ -n "$current_pubkey" ]]; then
                peer_names+=("$current_name")
                peer_pubkeys+=("$current_pubkey")
            fi
            current_name="${BASH_REMATCH[1]}"
            current_pubkey=""
            in_peer=true
        elif [[ "$line" == "[Peer]" ]]; then
            if $in_peer && [[ -n "$current_pubkey" ]]; then
                peer_names+=("$current_name")
                peer_pubkeys+=("$current_pubkey")
            fi
            current_name=""
            current_pubkey=""
            in_peer=true
        elif [[ "$line" =~ ^PublicKey\ *=\ *(.*) ]]; then
            current_pubkey="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^\[Interface\] ]]; then
            if $in_peer && [[ -n "$current_pubkey" ]]; then
                peer_names+=("$current_name")
                peer_pubkeys+=("$current_pubkey")
            fi
            in_peer=false
        fi
    done < <(sudo cat "$conf_file")

    if $in_peer && [[ -n "$current_pubkey" ]]; then
        peer_names+=("$current_name")
        peer_pubkeys+=("$current_pubkey")
    fi

    if [[ ${#peer_names[@]} -eq 0 ]]; then
        echo "No peers found."
        return 0
    fi

    echo "Peers:"
    for i in "${!peer_names[@]}"; do
        echo "  $((i + 1)). ${peer_names[$i]:-<unnamed>} (${peer_pubkeys[$i]:0:20}...)"
    done

    local choice
    choice="$(prompt "Enter peer number to remove (0 to cancel)" "0")"
    if [[ "$choice" == "0" || -z "$choice" ]]; then
        echo "Cancelled."
        return 0
    fi

    local idx=$((choice - 1))
    if [[ $idx -lt 0 || $idx -ge ${#peer_names[@]} ]]; then
        echo "Invalid choice."
        return 1
    fi

    local remove_pubkey="${peer_pubkeys[$idx]}"
    local remove_name="${peer_names[$idx]:-<unnamed>}"

    # Remove peer from runtime
    sudo wg set "$wg_interface" peer "$remove_pubkey" remove

    # Remove peer block from config file
    # awk paragraph mode: RS="" splits on blank lines, each section = one record
    # index() for exact string match (no regex issues with base64 +/)
    local tmp_file
    tmp_file="$(mktemp)"
    chmod 600 "$tmp_file"

    sudo cat "$conf_file" | awk -v pubkey="$remove_pubkey" '
    BEGIN { RS=""; FS="\n"; first=1 }
    {
        found = 0
        for (i = 1; i <= NF; i++) {
            if ($i == "PublicKey = " pubkey) {
                found = 1
                break
            }
        }
        if (!found) {
            if (!first) print ""
            print
            first = 0
        }
    }
    ' > "$tmp_file"

    sudo cp "$tmp_file" "$conf_file"
    sudo chown root:root "$conf_file"
    sudo chmod 600 "$conf_file"
    rm -f "$tmp_file"

    echo "Peer '$remove_name' removed."

    # Remove client config file if exists
    local client_conf_file="$HOME/${wg_interface}-client-${remove_name}.conf"
    if [[ -f "$client_conf_file" ]]; then
        rm -f "$client_conf_file"
        echo "Removed client config: $client_conf_file"
    fi
}

# --- Initial setup ---

initial_setup() {
    sudo apt update

    if ! is_installed wireguard; then
        sudo apt install wireguard -y
    fi

    if ! command -v qrencode &>/dev/null; then
        sudo apt install qrencode -y
    fi

    # Server or client?
    local is_server
    is_server="$(prompt "Is it a server? (y/N)" "N")"
    if [[ "$is_server" =~ ^[Yy]$ ]]; then
        setup_server
    else
        setup_client
    fi
}

setup_server() {
    local private_key
    private_key="$(prompt "Enter Private Key (leave empty to generate)" "")"
    if [[ -z "$private_key" ]]; then
        private_key="$(wg genkey)"
        echo "Generated Private Key: $private_key"
    fi
    local public_key
    public_key="$(echo "$private_key" | wg pubkey)"
    echo "Public Key: $public_key"

    local wg_interface
    wg_interface="$(prompt "Enter WireGuard interface name" "wg0")"
    local wg_interface_ip
    wg_interface_ip="$(prompt "Enter Interface IP" "10.0.0.1/24")"
    local listen_port
    listen_port="$(prompt "Enter Listen Port" "51820")"
    local mtu
    mtu="$(prompt "Enter MTU" "1400")"

    local local_interface
    local_interface="$(get_local_interface)"

    local conf_file
    conf_file="$(get_wg_conf_file "$wg_interface")"

    sudo mkdir -p "$(get_wg_conf_dir)"

    local nat_postup nat_postdown
    nat_postup="$(get_nat_postup "$local_interface")"
    nat_postdown="$(get_nat_postdown "$local_interface")"

    sudo tee "$conf_file" > /dev/null <<EOF
[Interface]
PrivateKey = $private_key
# PublicKey = $public_key
Address = $wg_interface_ip
ListenPort = $listen_port
MTU = $mtu
PostUp = $nat_postup
PostDown = $nat_postdown
EOF

    echo "Created configuration file at: $conf_file"

    # sysctl
    local sysctl_file="/etc/sysctl.d/99-wireguard.conf"

    set_sysctl_kv() {
        local key="$1" value="$2" file="$3"
        if sudo grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null; then
            sudo sed -i -E "s|^[[:space:]]*${key}[[:space:]]*=.*|${key}=${value}|" "$file"
        else
            echo "${key}=${value}" | sudo tee -a "$file" >/dev/null
        fi
    }

    sudo touch "$sysctl_file"
    set_sysctl_kv "net.ipv4.ip_forward" "1" "$sysctl_file"
    set_sysctl_kv "net.ipv4.conf.all.src_valid_mark" "1" "$sysctl_file"
    sudo sysctl --system >/dev/null

    if sysctl net.ipv4.ip_forward | grep -q '= 1'; then
        echo "IP forwarding enabled."
    else
        echo "WARNING: IP forwarding still disabled."
    fi

    sudo chown root:root "$conf_file"
    sudo chmod 600 "$conf_file"

    sudo systemctl enable "wg-quick@$wg_interface"
    sudo systemctl start "wg-quick@$wg_interface"

    echo ""
    echo "WireGuard server setup complete!"
    echo "Run this script again to add peers."
}

setup_client() {
    local private_key
    private_key="$(prompt "Enter Private Key (leave empty to generate)" "")"
    if [[ -z "$private_key" ]]; then
        private_key="$(wg genkey)"
        echo "Generated Private Key: $private_key"
    fi
    local public_key
    public_key="$(echo "$private_key" | wg pubkey)"
    echo "Public Key: $public_key"

    local wg_interface
    wg_interface="$(prompt "Enter WireGuard interface name" "wg0")"
    local wg_interface_ip
    wg_interface_ip="$(prompt "Enter Interface IP" "10.0.0.2/24")"
    local mtu
    mtu="$(prompt "Enter MTU" "1400")"

    local server_public_key
    server_public_key="$(prompt "Enter WG Server Public Key" "")"
    local preshared_key
    preshared_key="$(prompt "Enter PresharedKey (leave empty to skip)" "")"
    local endpoint
    endpoint="$(prompt "Enter Endpoint" ":51820")"
    local allowed_ips
    allowed_ips="$(prompt "Enter Allowed IPs" "0.0.0.0/0")"

    local dns_default=""
    [[ "$allowed_ips" == "0.0.0.0/0" ]] && dns_default="1.1.1.1,8.8.8.8"
    local dns
    dns="$(prompt "Enter DNS (empty = use system DNS)" "$dns_default")"
    local persistent_keepalive
    persistent_keepalive="$(prompt "Enter Persistent Keepalive (0 to disable)" "25")"

    local local_interface
    local_interface="$(get_local_interface)"

    local postup_rules=""
    if [[ "$allowed_ips" == "0.0.0.0/0" ]]; then
        postup_rules="
PostUp = ip rule show | grep -q \"from $wg_interface_ip table 200\" || ip rule add from $wg_interface_ip table 200
PostUp = ip route show table 200 | grep -q \"default dev $wg_interface\" || ip route add default dev $wg_interface table 200
PostUp = ip route show 10.0.0.0/8 dev $local_interface table main | grep -q . || ip route add 10.0.0.0/8 dev $local_interface table main
PostUp = ip route show 172.16.0.0/12 dev $local_interface table main | grep -q . || ip route add 172.16.0.0/12 dev $local_interface table main
PostUp = ip route show 192.168.0.0/16 dev $local_interface table main | grep -q . || ip route add 192.168.0.0/16 dev $local_interface table main
PostDown = ip rule del from $wg_interface_ip table 200 2>/dev/null || true
PostDown = ip route del default dev $wg_interface table 200 2>/dev/null || true
PostDown = ip route del 10.0.0.0/8 dev $local_interface table main 2>/dev/null || true
PostDown = ip route del 172.16.0.0/12 dev $local_interface table main 2>/dev/null || true
PostDown = ip route del 192.168.0.0/16 dev $local_interface table main 2>/dev/null || true"
    fi

    local conf_file
    conf_file="$(get_wg_conf_file "$wg_interface")"

    sudo mkdir -p "$(get_wg_conf_dir)"

    local conf_content=""
    conf_content+="[Interface]"$'\n'
    conf_content+="PrivateKey = $private_key"$'\n'
    conf_content+="# PublicKey = $public_key"$'\n'
    conf_content+="Address = $wg_interface_ip"$'\n'
    [[ -n "$dns" ]] && conf_content+="DNS = $dns"$'\n'
    conf_content+="MTU = $mtu"$'\n'
    [[ -n "$postup_rules" ]] && conf_content+="$postup_rules"$'\n'
    conf_content+=$'\n'
    conf_content+="[Peer]"$'\n'
    conf_content+="PublicKey = $server_public_key"$'\n'
    [[ -n "$preshared_key" ]] && conf_content+="PresharedKey = $preshared_key"$'\n'
    conf_content+="Endpoint = $endpoint"$'\n'
    conf_content+="AllowedIPs = $allowed_ips"$'\n'
    [[ "$persistent_keepalive" != "0" ]] && conf_content+="PersistentKeepalive = $persistent_keepalive"$'\n'

    echo "$conf_content" | sudo tee "$conf_file" > /dev/null

    echo "Created configuration file at: $conf_file"

    sudo chown root:root "$conf_file"
    sudo chmod 600 "$conf_file"

    sudo systemctl enable "wg-quick@$wg_interface"
    sudo systemctl start "wg-quick@$wg_interface"

    echo "WireGuard client setup complete!"
}

# --- Help ---

show_help() {
    local self
    self="$(command -v "$0" || echo "$0")"
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$self"
}

# --- Main ---

management_menu() {
    local wg_interface="$1"

    echo "WireGuard [$wg_interface]"
    echo ""
    echo "  1) List peers"
    echo "  2) Add a peer"
    echo "  3) Remove a peer"
    echo "  4) Uninstall WireGuard"
    echo "  5) Exit"
    echo ""
    local choice
    choice="$(prompt "Choice" "5")"

    case "$choice" in
        1) list_peers "$wg_interface" ;;
        2) add_peer "$wg_interface" ;;
        3) remove_peer "$wg_interface" ;;
        4)
            local confirm
            confirm="$(prompt "Are you sure? This will remove WireGuard and all configs (y/N)" "N")"
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                sudo systemctl stop "wg-quick@$wg_interface" 2>/dev/null || true
                sudo systemctl disable "wg-quick@$wg_interface" 2>/dev/null || true
                sudo rm -f "$(get_wg_conf_file "$wg_interface")"
                sudo apt remove wireguard -y
                sudo rm -f /etc/sysctl.d/99-wireguard.conf
                sudo sysctl --system >/dev/null
                echo "WireGuard uninstalled."
            fi
            ;;
        5) exit 0 ;;
        *) echo "Invalid choice." ;;
    esac
}

main() {
    local action=""
    local wg_interface=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) show_help; exit 0 ;;
            -i|--install) action="install"; shift ;;
            -l|--list) action="list"; shift ;;
            -a|--add) action="add"; shift ;;
            -r|--remove) action="remove"; shift ;;
            -*) echo "Unknown option: $1"; show_help; exit 1 ;;
            *) wg_interface="$1"; shift ;;
        esac
    done

    # Install goes straight to setup wizard
    if [[ "$action" == "install" ]]; then
        initial_setup
        exit 0
    fi

    # Actions that need an interface
    if [[ -n "$action" ]]; then
        wg_interface="$(pick_interface "$wg_interface")"
        if [[ -z "$wg_interface" ]]; then
            echo "No WireGuard interfaces found. Run: setup-wireguard -i"
            exit 1
        fi
        case "$action" in
            list) list_peers "$wg_interface" ;;
            add) add_peer "$wg_interface" ;;
            remove) remove_peer "$wg_interface" ;;
        esac
        exit 0
    fi

    # Default: auto-detect and show menu or offer install
    wg_interface="$(pick_interface "$wg_interface")"
    if [[ -z "$wg_interface" ]]; then
        local run_setup
        run_setup="$(prompt "No WireGuard interfaces found. Run setup?" "Y")"
        if [[ "$run_setup" =~ ^[Yy]$ ]]; then
            initial_setup
        fi
        exit 0
    fi

    management_menu "$wg_interface"
}

main "$@"
