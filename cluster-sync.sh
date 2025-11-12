#!/bin/bash
# ClusterCtrl Time Sync v1.1 – Production
# Author: UntrustedTech
# License: All Rights Reserved (no copying/distribution)

set -euo pipefail

# === Colors & Symbols ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'
CHECK="Checkmark"
CROSS="Cross"
WARN="Warning"

VERSION="v1.1"
LOGDIR="/tmp"
LOGFILE="$LOGDIR/cluster_sync_$(date +%m%d_%H%M).log"
CONFIG_FILE="$HOME/.cluster-sync.conf"

# Redirect all output to log + screen
exec > >(tee -a "$LOGFILE") 2>&1

# === Arrays ===
declare -a TASKS=()
declare -a FAILED_NODES=()
declare -A FAILURE_REASONS

# === Helper: Spinner ===
spin() {
    local pid=$1 msg=${2:-}
    local spin='⣾⣽⣻⢿⡿⣟⣯⣷'
    while kill -0 $pid 2>/dev/null; do
        printf " ${CYAN}%s${NC} %s  \r" "$msg" "${spin:i++%${#spin}:1}"
        sleep 0.1
    done
    wait $pid 2>/dev/null || true
    printf " ${GREEN}Done${NC}          \n"
}

# === Load Config ===
load_config() {
    [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" && echo -e "   ${YELLOW}Config loaded${NC}"
}

# === Save Config ===
save_config() {
    cat > "$CONFIG_FILE" <<EOF
SSH_USER="$SSH_USER"
SSH_PASS="$SSH_PASS"
MODE="$MODE"
AUTH_METHOD="$AUTH_METHOD"
EOF
    chmod 600 "$CONFIG_FILE"
    echo -e "   ${GREEN}Config saved${NC}"
}

# === Rotate Logs ===
rotate_logs() {
    find "$LOGDIR" -name "cluster_sync_*.log" | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
}

# === Wait for Node ===
wait_for_node() {
    local n=$1
    printf "   ${BLUE}Waiting for p%s${NC}" "$n"
    local t=0
    while ! ping -c1 -W2 "p${n}.local" &>/dev/null && (( t < 120 )); do
        printf "."; sleep 2; ((t++))
    done
    (( t >= 120 )) && printf " ${RED}Timeout${NC}\n" && return 1
    sleep 5
    printf " ${GREEN}Up${NC}\n"
    return 0
}

# === Power On If Offline (Pre-flight) ===
power_on_if_offline() {
    local n=$1
    if ping -c1 -W2 "p${n}.local" &>/dev/null; then
        printf "   p%s: ${GREEN}%s${NC}\n" "$n" "$CHECK Online"
        return 0
    fi
    printf "   p%s: ${RED}%s${NC} → ${YELLOW}Powering on...${NC}" "$n" "$CROSS Offline"
    command -v clusterctrl >/dev/null || { echo -e "${RED}ERROR: clusterctrl not found${NC}"; exit 1; }
    sudo clusterctrl on "p$n" >/dev/null 2>&1 || { printf " ${RED}Failed${NC}\n"; TASKS+=("Power On p$n" "Failed"); return 1; }
    wait_for_node "$n" && {
        printf "   p%s: ${GREEN}%s${NC}\n" "$n" "$CHECK Online (powered on)"
        TASKS+=("Power On p$n" "Success")
        return 0
    } || {
        printf "   p%s: ${RED}%s${NC}\n" "$n" "$CROSS Still offline"
        TASKS+=("Power On p$n" "Failed")
        return 1
    }
}

# === Pre-flight ===
pre_flight_check() {
    echo -e "\n${BOLD}${CYAN}Pre-flight Network Check${NC}\n────────────────────────────────"
    local all_up=1
    for n in {1..4}; do
        power_on_if_offline "$n" || all_up=0
    done
    (( all_up )) && echo -e "   ${GREEN}All nodes ready.${NC}\n" || echo -e "   ${YELLOW}Proceeding with powered-on nodes...${NC}\n"
}

# === Run SSH Command with Retry ===
run_ssh_cmd() {
    local n=$1 cmd=$2 phase=$3
    local max=3 delay=2
    for ((a=1; a<=max; a++)); do
        echo -n "$phase"
        if (( USE_SSH_KEYS )); then
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@p${n}.local" "$cmd" > /tmp/ssh.log 2>&1 &
        else
            sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@p${n}.local" "$cmd" > /tmp/ssh.log 2>&1 &
        fi
        local pid=$!
        spin $pid "working"
        wait $pid 2>/dev/null || true
        if grep -q "successfully" /tmp/ssh.log 2>/dev/null || [ ! -s /tmp/ssh.log ]; then
            TASKS+=("p$n: $phase" "Success"); return 0
        fi
        (( a < max )) && printf "   ${YELLOW}Retry $a (wait ${delay}s)${NC}\n" && sleep $delay && ((delay *= 2))
    done
    log_err "$n" "$phase failed" "check network"
    TASKS+=("p$n: $phase" "Failed")
    return 1
}

# === Log Error ===
log_err() {
    local n=$1 e=$2
    echo -e "${RED}ERR p$n: $e${NC}" >&2
    FAILURE_REASONS["p$n"]+="$e; "
    FAILED_NODES+=("p$n")
}

# === Ensure Node On (Worker Loop) ===
ensure_node_on() {
    local n=$1
    ping -c1 "p${n}.local" &>/dev/null && { printf "   ${GREEN}p%s online${NC}\n" "$n"; return 0; }
    printf "   ${YELLOW}p%s off → powering on${NC}\n" "$n"
    sudo clusterctrl on "p$n" >/dev/null 2>&1 || { log_err "$n" "clusterctrl failed"; return 1; }
    wait_for_node "$n" || { log_err "$n" "boot timeout"; return 1; }
    return 0
}

# === Verify Time Sync ===
verify_time_sync() {
    local n=$1
    echo -n "   ${BLUE}Verifying time sync${NC}"
    local output
    if (( USE_SSH_KEYS )); then
        output=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@p${n}.local" "chronyc sources" 2>/dev/null || echo "")
    else
        output=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@p${n}.local" "chronyc sources" 2>/dev/null || echo "")
    fi
    if echo "$output" | grep -q "^\*[[:space:]]*$MASTER_IP"; then
        printf " ${GREEN}%s${NC}\n" "$CHECK Synced"
        TASKS+=("p$n: time verify" "Success")
        return 0
    else
        printf " ${RED}%s${NC}\n" "$CROSS Not synced"
        TASKS+=("p$n: time verify" "Failed")
        return 1
    fi
}

# === Deploy SSH Keys ===
deploy_master_ssh_key() {
    echo -e "\n${PURPLE}SSH Key Setup${NC}\n────────────────────────────────────"
    [[ -f "$HOME/.ssh/id_rsa" ]] && echo "   ${YELLOW}Using existing key${NC}" || {
        echo -n "   ${BLUE}Generating key${NC}"
        ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -q -N "" >/dev/null
        printf " ${GREEN}%s${NC}\n" "$CHECK"
        TASKS+=("SSH Key Generation" "Success")
    }

    local all_good=1
    for n in {1..4}; do
        ensure_node_on "$n" || { all_good=0; continue; }
        echo -n "   ${BLUE}Deploying to p${n}${NC}"
        sshpass -p "$SSH_PASS" ssh-copy-id -o StrictHostKeyChecking=no "$SSH_USER@p${n}.local" &>/tmp/sshcopy.log &
        spin $! ""
        if grep -q "added: 1" /tmp/sshcopy.log 2>/dev/null; then
            printf " ${GREEN}%s${NC}\n" "$CHECK"
            TASKS+=("SSH Deploy p$n" "Success")
        else
            printf " ${RED}%s${NC}\n" "$CROSS"
            log_err "p$n" "ssh-copy-id failed"
            TASKS+=("SSH Deploy p$n" "Failed")
            all_good=0
        fi
    done

    (( all_good )) && {
        echo -e "\n   ${GREEN}Keys deployed${NC}"
        for i in {5..1}; do printf "   ${CYAN}→ %s${NC} " "$i"; sleep 1; done; echo; echo
        USE_SSH_KEYS=1
    } || { echo -e "   ${YELLOW}Using password auth${NC}\n"; USE_SSH_KEYS=0; }
}

# === Retry Failed ===
retry_failed_nodes() {
    (( ${#FAILED_NODES[@]} == 0 )) && return
    echo -e "\n${BOLD}${YELLOW}Retry failed nodes? [Y/n]${NC}"
    read -t 10 answer || answer="y"
    [[ "$answer" =~ ^[Nn]$ ]] && return

    local retry_list=("${FAILED_NODES[@]}")
    FAILED_NODES=(); FAILURE_REASONS=()

    for node in "${retry_list[@]}"; do
        local n=${node#p}
        echo -e "\n${BOLD}${CYAN}Retrying p$n${NC}\n──────"
        local ok=1
        ensure_node_on "$n" || ok=0
        run_ssh_cmd "$n" "sudo apt update -y" "   ${BLUE}Update${NC}" || ok=0
        run_ssh_cmd "$n" "sudo apt full-upgrade -y" "   ${BLUE}Upgrade${NC}" || ok=0
        run_ssh_cmd "$n" "sudo apt autoremove -y" "   ${BLUE}Clean${NC}" || ok=0
        # Reboot
        echo -n "   ${BLUE}Reboot${NC}"
        ( (( USE_SSH_KEYS )) && ssh -o StrictHostKeyChecking=no "$SSH_USER@p${n}.local" "sudo reboot" || sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@p${n}.local" "sudo reboot" ) &>/tmp/reboot.log &
        spin $! "rebooting"
        TASKS+=("p$n: reboot" "Success")
        wait_for_node "$n" || ok=0
        run_ssh_cmd "$n" "sudo apt install -y chrony; echo 'server $MASTER_IP iburst' | sudo tee /etc/chrony/conf.d/master.conf; sudo systemctl restart chrony; chronyc makestep" "   ${BLUE}Chrony${NC}" || ok=0
        verify_time_sync "$n" || ok=0
        (( ok )) && echo -e "   ${GREEN}p$n recovered${NC}\n"
    done
}

# === Main ===
clear
rotate_logs
load_config

echo -e "${BOLD}${YELLOW}ClusterCtrl Time Sync $VERSION${NC}\n────────────────────────────────────────"
echo -e "${CYAN}Author: UntrustedTech${NC}\nLog: $LOGFILE\n"

# === Inputs ===
MODE="${MODE:-auto}"
AUTH_METHOD="${AUTH_METHOD:-keys}"

read -p "${BOLD}Mode [1=Auto, 2=Assisted] (default: $MODE): ${NC}" mode_choice
[[ -n "$mode_choice" ]] && MODE=$(( mode_choice == 2 ? "assisted" : "auto" ))

USE_SSH_KEYS=0
read -p "${BOLD}Auth [1=Password, 2=SSH Keys] (default: $AUTH_METHOD): ${NC}" auth_choice
[[ -z "$auth_choice" ]] && auth_choice=$(( AUTH_METHOD == "keys" ? 2 : 1 ))

if [[ -z "${SSH_USER:-}" || -z "${SSH_PASS:-}" ]]; then
    read -p "Worker SSH User: " SSH_USER
    read -s -p "Worker SSH Pass: " SSH_PASS; echo
    [[ -z "$SSH_USER" || -z "$SSH_PASS" ]] && { echo -e "${RED}Credentials required${NC}"; exit 1; }
    save_config
else
    echo -e "   ${GREEN}Using saved credentials${NC}\n"
fi

(( auth_choice == 2 )) && USE_SSH_KEYS=1

pre_flight_check

# === Master ===
echo -e "${BOLD}${CYAN}Master Node${NC}\n──────────────"
run_ssh_cmd "M" "sudo apt update -y" "   ${BLUE}Update${NC}" || true
run_ssh_cmd "M" "sudo apt full-upgrade -y" "   ${BLUE}Upgrade${NC}" || true
run_ssh_cmd "M" "sudo apt install -y chrony" "   ${BLUE}Install chrony${NC}" || true
echo -n "   ${BLUE}Config chrony${NC}"
sudo bash -c "sed -i '/^#pool/d' /etc/chrony/chrony.conf; echo -e 'allow 10.55.0.0/24\nlocal stratum 10' >> /etc/chrony/chrony.conf; systemctl restart chrony" &>/dev/null && printf " ${GREEN}%s${NC}\n\n" "$CHECK" && TASKS+=("Master: config" "Success") || TASKS+=("Master: config" "Failed")

MASTER_IP=$(hostname -I | awk '{print $1}')

(( USE_SSH_KEYS )) && deploy_master_ssh_key

# === Workers ===
for n in {1..4}; do
    [[ "$MODE" == "assisted" ]] && { read -t 10 -p "Continue p$n? [Y/n/skip]: " a || a=y; [[ "$a" =~ ^[Nn]$ ]] && continue; [[ "$a" =~ ^[Ss]$ ]] && { echo "   Skipped p$n"; TASKS+=("p$n: Skipped" "User"); continue; }; }
    echo -e "${BOLD}${CYAN}p${n}${NC}\n──────"
    local ok=1
    ensure_node_on "$n" || ok=0
    run_ssh_cmd "$n" "sudo apt update -y" "   ${BLUE}Update${NC}" || ok=0
    run_ssh_cmd "$n" "sudo apt full-upgrade -y" "   ${BLUE}Upgrade${NC}" || ok=0
    run_ssh_cmd "$n" "sudo apt autoremove -y" "   ${BLUE}Clean${NC}" || ok=0
    # Reboot
    echo -n "   ${BLUE}Reboot${NC}"
    ( (( USE_SSH_KEYS )) && ssh -o StrictHostKeyChecking=no "$SSH_USER@p${n}.local" "sudo reboot" || sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@p${n}.local" "sudo reboot" ) &>/tmp/reboot.log &
    spin $! "rebooting"
    TASKS+=("p$n: reboot" "Success")
    wait_for_node "$n" || ok=0
    run_ssh_cmd "$n" "sudo apt install -y chrony; echo 'server $MASTER_IP iburst' | sudo tee /etc/chrony/conf.d/master.conf; sudo systemctl restart chrony; chronyc makestep" "   ${BLUE}Chrony${NC}" || ok=0
    verify_time_sync "$n" || ok=0
    (( ok )) && echo -e "   ${GREEN}p${n} synced${NC}\n" || echo -e "   ${RED}p${n} failed${NC}\n"
done

retry_failed_nodes

# === Final Report ===
echo -e "${BOLD}${PURPLE}FINAL TASK REPORT${NC}"
printf " ${BOLD}%-50s %-12s${NC}\n" "Task" "Status"
printf " ${BOLD}%-50s %-12s${NC}\n" "──────────────────────────────────────────────────" "────────────"
for ((i=0; i<${#TASKS[@]}; i+=2)); do
    local task="${TASKS[i]}"
    local status="${TASKS[i+1]}"
    case "$status" in
        "Success") color="$GREEN" icon="$CHECK" ;;
        "Failed")  color="$RED"   icon="$CROSS" ;;
        *)         color="$YELLOW" icon="$WARN" ;;
    esac
    printf " %-50s ${color}%s %s${NC}\n" "$task" "$icon" "$status"
done

(( ${#FAILED_NODES[@]} == 0 )) && echo -e "\n${BOLD}${GREEN}Cluster fully synchronized!${NC}" || {
    echo -e "\n${BOLD}${RED}Sync incomplete:${NC}"
    for n in "${FAILED_NODES[@]}"; do echo -e "   • ${RED}$n${NC}: ${FAILURE_REASONS[$n]}"; done
    echo -e "   ${YELLOW}Log: $LOGFILE${NC}"
}
echo

# Copyright (c) 2025 UntrustedTech. All rights reserved.
# Unauthorized copying, modification, or distribution prohibited.
