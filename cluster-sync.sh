#!/bin/bash
# =============================================================================
# Cluster HAT v2.0 Auto-Setup & Time Sync
# Version: 1.2
# Author: UntrustedTech
# GitHub: https://github.com/UntrustedTech/ClusterCtrl-Time-Sync
# =============================================================================

# -----------------------------
# Colors & Constants
# -----------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
SPINNER='⣾⣽⣻⢿⡿⣟⣯⣷'
NODES=("p1" "p2" "p3" "p4")

# -----------------------------
# Global State
# -----------------------------
ERRORS=""
UPDATE_LOG="$HOME/.clusterctrl_update.log"
TODAY=$(date +%Y-%m-%d)
MASTER_NAME=$(hostname)
MASTER_MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "Unknown")
MASTER_IP=$(ip route get 1.1.1.1 | awk '{print $7}' | head -1)

# -----------------------------
# UI: Spinner & Status
# -----------------------------
spinner() {
    local pid=$1 msg=$2
    local i=0 delay=0.12
    while kill -0 $pid 2>/dev/null; do
        printf "\r  ${MAGENTA}${SPINNER:i++%8:1}${NC} %s" "$msg"
        sleep $delay
    done
    printf "\r"
}

status()  { echo -e "  ${GREEN}Success $1${NC}"; }
warning() { echo -e "  ${YELLOW}Warning $1${NC}"; }
error()   { echo -e "  ${RED}Failed $1${NC}"; }
log_error() { ERRORS+="$1\n"; }

# -----------------------------
# Safe Execution: APT & SSH
# -----------------------------
run_cmd() {
    local cmd="$1" desc="$2" node="${3:-}"
    local prefix="${node:+${node}: }"
    local spinner_pid exit_code

    printf "  %s" "${prefix}${desc}"
    eval "$cmd" &>/dev/null &
    spinner_pid=$!
    spinner $spinner_pid "$desc..."

    wait $spinner_pid
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo -e "\r  ${prefix}${GREEN}Success $desc${NC}                    "
        return 0
    else
        echo -e "\r  ${prefix}${YELLOW}Warning Retrying...${NC}                    "
        sleep 2
        eval "$cmd" &>/dev/null &
        spinner_pid=$!
        spinner $spinner_pid "$desc (retry)..."

        wait $spinner_pid
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            echo -e "\r  ${prefix}${GREEN}Success $desc (retry)${NC}                    "
            return 0
        else
            echo -e "\r  ${prefix}${RED}Failed $desc failed${NC}          "
            log_error "$node: $desc failed (code: $exit_code)"
            return 1
        fi
    fi
}

run_apt() { run_cmd "$1" "$2"; }
run_ssh() { run_cmd "$1" "$2" "$3"; }

# -----------------------------
# Dependency: sshpass
# -----------------------------
ensure_sshpass() {
    command -v sshpass &>/dev/null && return

    print_header "Installing sshpass"
    echo -e "${YELLOW}Required: sshpass (automated login)${NC}\n"

    run_apt "sudo apt update" "Updating package list" || {
        echo -e "\n${RED}APT update failed. Check internet or sources.${NC}"
        exit 1
    }
    run_apt "sudo apt install -y sshpass" "Installing sshpass" || {
        echo -e "\n${RED}Failed to install sshpass.${NC}"
        exit 1
    }
    echo
}

# -----------------------------
# UI: Header
# -----------------------------
print_header() {
    clear
    echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║${NC}       ${CYAN}Cluster HAT v2.0 Auto-Setup & Time Sync${NC}           ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}║${NC}  ${DIM}Author: UntrustedTech${NC}  •  ${DIM}v1.2${NC}  •  ${DIM}github.com/UntrustedTech${NC}  ${BOLD}${BLUE}║${NC}"
    echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    [[ -n "$1" ]] && echo -e "${BOLD}$1${NC}\n"
}

# -----------------------------
# 1. Master Node
# -----------------------------
setup_master() {
    print_header "MASTER NODE"
    echo -e "  ${CYAN}Hardware:${NC} $MASTER_MODEL"
    echo -e "  ${CYAN}Hostname:${NC} $MASTER_NAME\n"

    [[ -f "$UPDATE_LOG" && $(cat "$UPDATE_LOG") == "$TODAY" ]] && {
        status "Already updated today"; return
    }

    read -p " $(echo -e "${YELLOW}Update master? (y/n): ${NC}")" -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { warning "Skipped"; return; }

    run_apt "sudo apt update" "Updating master"
    run_apt "sudo apt full-upgrade -y" "Upgrading master"
    echo "$TODAY" > "$UPDATE_LOG"
    status "Update logged"

    read -p " $(echo -e "${YELLOW}Reboot? (y/n): ${NC}")" -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && { echo -e "\n${GREEN}Rebooting...${NC}"; sleep 3; sudo reboot; }
}

# -----------------------------
# 2. Network Check
# -----------------------------
check_network() {
    print_header "NETWORK CHECK"
    status "Master ($MASTER_NAME) online"

    local offline=()
    for node in "${NODES[@]}"; do
        ping -c 1 -W 1 "$node.local" &>/dev/null && status "$node.local online" || {
            error "$node.local offline"; offline+=("$node")
        }
    done

    [[ ${#offline[@]} -eq 0 ]] && return

    read -p " $(echo -e "${CYAN}Power on? (all/specific/none): ${NC}")" action
    case "$action" in
        all)     clusterctrl on p1 p2 p3 p4 &>/dev/null & spinner $! "Powering all..." ;;
        specific)
            read -p " Nodes: " nodes
            clusterctrl on $nodes &>/dev/null & spinner $! "Powering $nodes..."
            ;;
        *) warning "Skipped"; return ;;
    esac

    echo -e "\n${CYAN}Waiting for boot...${NC}"
    for node in "${offline[@]}"; do
        echo -n "  $node.local: "
        while ! ping -c 1 -W 1 "$node.local" &>/dev/null; do
            for c in ⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏; do
                printf "$MAGENTA$c$NC"; sleep 0.1; printf "\b"
            done
        done
        echo -e "\r  $node.local: ${GREEN}Success online${NC}"
    done
}

# -----------------------------
# 3. SSH Credentials
# -----------------------------
get_credentials() {
    print_header "SSH CREDENTIALS"
    read -p " $(echo -e "${CYAN}Same for all? (y/n): ${NC}")" -n 1 -r; echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "  Username: " USER
        read -s -p "  Password: " PASS; echo
        USERS=("$USER" "$USER" "$USER" "$USER")
        PASSES=("$PASS" "$PASS" "$PASS" "$PASS")
        status "Shared credentials"
    else
        USERS=(); PASSES=()
        for node in "${NODES[@]}"; do
            read -p "  Username for $node: " u
            read -s -p "  Password for $node: " p; echo
            USERS+=("$u"); PASSES+=("$p")
        done
        status "Individual credentials"
    fi
}

# -----------------------------
# 4. SSH Key Setup
# -----------------------------
setup_ssh_keys() {
    print_header "SSH KEY SETUP"
    local keys_ok=true
    for i in {0..3}; do
        ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${USERS[$i]}@${NODES[$i]}.local" "exit" 2>/dev/null && keys_ok=false
    done

    $keys_ok && { status "Passwordless ready"; return; }

    read -p " $(echo -e "${CYAN}Set up keys? (y/n): ${NC}")" -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { warning "Skipped"; return; }

    [[ ! -f ~/.ssh/id_rsa ]] && {
        ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa &>/dev/null &
        spinner $! "Generating key..."
    }

    echo -e "\n${GREEN}Distributing key...${NC}"
    for i in {0..3}; do
        local node=${NODES[$i]} user=${USERS[$i]} pass=${PASSES[$i]}
        run_ssh "sshpass -p '$pass' ssh-copy-id -i ~/.ssh/id_rsa.pub '$user@$node.local'" "$node" "Copying key"
    done
}

# -----------------------------
# 5. PARALLEL WORKER UPDATES
# -----------------------------
update_workers() {
    print_header "PARALLEL WORKER UPDATES"
    read -p " $(echo -e "${CYAN}Update all in parallel? (y/n): ${NC}")" -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { warning "Skipped"; return; }

    local pids=()
    for i in {0..3}; do
        local node=${NODES[$i]} user=${USERS[$i]} pass=${PASSES[$i]}
        local label="p$((i+1))"
        local ssh_cmd="ssh $user@$node.local"
        ssh -o BatchMode=yes "$user@$node.local" "exit" 2>/dev/null || ssh_cmd="sshpass -p '$pass' ssh $user@$node.local"

        (
            echo -e "${BOLD}STARTING $label.local${NC}"
            run_ssh "$ssh_cmd 'sudo apt update && sudo apt full-upgrade -y && sudo apt autoremove -y'" "$label" "Updating" || true

            echo -n "  $label: Rebooting"
            $ssh_cmd "sudo reboot" &>/dev/null
            while ! ping -c 1 -W 1 "$node.local" &>/dev/null; do
                printf "."; sleep 2
            done
            echo -e " ${GREEN}Success back online${NC}"
        ) &
        pids+=($!)
    done

    echo -e "\n${CYAN}Waiting for all updates...${NC}"
    for pid in "${pids[@]}"; do
        wait $pid && status "Update $pid done" || log_error "Update $pid failed"
    done
}

# -----------------------------
# 6. PARALLEL NTP (CHRONY) SYNC
# -----------------------------
setup_chrony() {
    print_header "PARALLEL NTP SYNC (CHRONY)"

    # Master
    run_apt "sudo apt install -y chrony" "Installing chrony (master)"
    sudo sed -i 's/^pool/#pool/' /etc/chrony/chrony.conf 2>/dev/null
    echo -e "local stratum 10\nallow 172.19.181.0/24" | sudo tee -a /etc/chrony/chrony.conf > /dev/null
    sudo systemctl restart chrony &>/dev/null
    status "Master NTP: $MASTER_IP"

    # Workers (Parallel)
    local pids=()
    for i in {0..3}; do
        local node=${NODES[$i]} user=${USERS[$i]} pass=${PASSES[$i]}
        local label="p$((i+1))"
        local ssh_cmd="ssh $user@$node.local"
        ssh -o BatchMode=yes "$user@$node.local" "exit" 2>/dev/null || ssh_cmd="sshpass -p '$pass' ssh $user@$node.local"

        (
            run_ssh "$ssh_cmd 'sudo apt install -y chrony'" "$label" "Installing" || true
            run_ssh "$ssh_cmd 'sudo sed -i \"s/^pool/#pool/\" /etc/chrony/chrony.conf 2>/dev/null'" "$label" "Disabling pools" || true
            run_ssh "$ssh_cmd 'echo \"server $MASTER_IP iburst\" | sudo tee /etc/chrony/chrony.conf > /dev/null'" "$label" "Setting master" || true
            run_ssh "$ssh_cmd 'sudo systemctl restart chrony'" "$label" "Restarting" || true
        ) &
        pids+=($!)
    done

    echo -e "\n${CYAN}Waiting for NTP sync...${NC}"
    for pid in "${pids[@]}"; do
        wait $pid && status "NTP $pid done" || log_error "NTP $pid failed"
    done
}

# -----------------------------
# 7. Final Health Check
# -----------------------------
final_check() {
    print_header "HEALTH CHECK"
    echo -e "${CYAN}Connectivity:${NC}"
    status "Master ($MASTER_NAME) online"
    for node in "${NODES[@]}"; do
        ping -c 1 -W 1 "$node.local" &>/dev/null && status "$node.local online" || {
            error "$node.local offline"; log_error "Final: $node offline"
        }
    done

    echo -e "\n${CYAN}NTP Synchronization:${NC}"
    for i in {0..3}; do
        local node=${NODES[$i]} user=${USERS[$i]} pass=${PASSES[$i]}
        local label="p$((i+1))"
        local ssh_cmd="ssh $user@$node.local"
        ssh -o BatchMode=yes "$user@$node.local" "exit" 2>/dev/null || ssh_cmd="sshpass -p '$pass' ssh $user@$node.local"
        local sync=$($ssh_cmd "chronyc tracking 2>/dev/null | grep -i 'Reference ID' || echo 'none'" 2>/dev/null)
        [[ "$sync" == *"(172.19.181.1)"* ]] && status "$label NTP synced" || {
            error "$label NTP failed"; log_error "NTP sync failed: $label"
        }
    done
}

# -----------------------------
# 8. Summary
# -----------------------------
show_summary() {
    print_header "SETUP COMPLETE"

    if [ -z "$ERRORS" ]; then
        echo -e "${GREEN}Cluster ready in record time!${NC}\n"
        echo -e "${YELLOW}ClusterCtrl Time Sync v1.0${NC}"
        echo -e "${DIM}by UntrustedTech • https://github.com/UntrustedTech${NC}"
    else
        echo -e "${RED}ISSUES:${NC}"
        echo -e "${RED}$ERRORS${NC}\n"
        echo -e "${YELLOW}Fix and re-run.${NC}"
    fi
}

# -----------------------------
# Main
# -----------------------------
main() {
    ensure_sshpass
    setup_master
    check_network
    get_credentials
    setup_ssh_keys
    update_workers
    setup_chrony
    final_check
    show_summary
}

main
# Copyright (c) 2025 UntrustedTech. All rights reserved.
# Unauthorized copying, modification, or distribution prohibited.
