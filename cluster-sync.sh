#!/bin/bash

# === ClusterCtrl Time Sync v1.0 (Production) ===
# Author: UntrustedTech
# Date: 2025-11-10
# Production-ready: Config, Auto-power, Verify, Retry, Clean Icons

# Colors & Symbols
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

VERSION="v1.0"
LOGDIR="/tmp"
LOGFILE="$LOGDIR/cluster_sync_$(date +%m%d_%H%M).log"
CONFIG_FILE="$HOME/.cluster-sync.conf"
exec > >(tee -a "$LOGFILE") 2>&1

# === Load Config File ===
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        echo -e "   ${YELLOW}Config loaded: $CONFIG_FILE${NC}"
    fi
}

# === Save Config (First Run) ===
save_config() {
    cat > "$CONFIG_FILE" <<EOF
# ClusterCtrl Sync Configuration
SSH_USER="$SSH_USER"
SSH_PASS="$SSH_PASS"
MODE="$MODE"
AUTH_METHOD="$AUTH_METHOD"
EOF
    chmod 600 "$CONFIG_FILE"
    echo -e "   ${GREEN}Config saved to $CONFIG_FILE${NC}"
}

# === Log Rotation ===
rotate_logs() {
    find "$LOGDIR" -name "cluster_sync_*.log" | sort -r | tail -n +6 | xargs -I {} rm -f {} 2>/dev/null
}

# === Wait for node ===
wait_for_node() {
    local n=$1
    printf "   ${BLUE}Waiting for p%s${NC}" "$n"
    local t=0
    while ! ping -c1 "p${n}.local" >/dev/null 2>&1 && [ $t -lt 120 ]; do
        printf "."; sleep 2; ((t++))
    done
    [ $t -ge 120 ] && printf " ${RED}Timeout${NC}\n" && return 1
    sleep 5
    printf " ${GREEN}Up${NC}\n"
    return 0
}

# === Power on Pi if offline ===
power_on_if_offline() {
    local n=$1
    if ping -c1 -W2 "p${n}.local" &>/dev/null; then
        printf "   p%s: ${GREEN}%s${NC}\n" "$n" "$CHECK Online"
        return 0
    fi

    printf "   p%s: ${RED}%s${NC}" "$n" "$CROSS Offline"
    printf " → ${YELLOW}Powering on...${NC}"
    sudo clusterctrl on p${n} >/dev/null 2>&1 || { 
        printf " ${RED}clusterctrl failed${NC}\n"
        TASKS+=("Power On p$n" "Failed")
        return 1
    }

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

# === Pre-flight Network Check with Auto Power-On ===
pre_flight_check() {
    echo -e "\n${BOLD}${CYAN}Pre-flight Network Check${NC}"
    echo "────────────────────────────────"
    local all_up=1
    for n in {1..4}; do
        power_on_if_offline "$n" || all_up=0
    done

    if [ $all_up -eq 1 ]; then
        echo -e "   ${GREEN}All nodes online and ready.${NC}\n"
    else
        echo -e "   ${YELLOW}Some nodes required power-on. Proceeding...${NC}\n"
    fi
}

# === Time Sync Verification ===
verify_time_sync() {
    local n=$1
    echo -n "   ${BLUE}Verifying time sync${NC}"
    local output
    if [ $USE_SSH_KEYS -eq 1 ]; then
        output=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@p${n}.local" "chronyc sources" 2>/dev/null)
    else
        output=$(sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@p${n}.local" "chronyc sources" 2>/dev/null)
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

# === Auto-retry SSH ===
run_ssh_cmd() {
    local n=$1 cmd=$2 phase=$3
    local max=3 delay=2
    for ((a=1; a<=max; a++)); do
        echo -n "$phase"
        if [ $USE_SSH_KEYS -eq 1 ]; then
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@p${n}.local" "$cmd" > /tmp/ssh.log 2>&1 &
        else
            sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@p${n}.local" "$cmd" > /tmp/ssh.log 2>&1 &
        fi
        spin $! ""
        wait $! 2>/dev/null
        if [ $? -eq 0 ]; then
            TASKS+=("p$n: $phase" "Success")
            return 0
        fi
        ((a < max)) && printf "   ${YELLOW}Retry $a (wait ${delay}s)${NC}\n" && sleep $delay && ((delay*=2))
    done
    local err=$(tail -1 /tmp/ssh.log 2>/dev/null || echo "timeout")
    rm -f /tmp/ssh.log
    log_err "$n" "$phase: $err" "check network"
    TASKS+=("p$n: $phase" "Failed")
    return 1
}

# === Spinner ===
spin() {
    local pid=$1 msg=$2
    local spin='⣾⣽⣻⢿⡿⣟⣯⣷'
    local i=0
    while kill -0 $pid 2>/dev/null; do
        printf " ${CYAN}%s${NC} %s  " "$msg" "${spin:i++%${#spin}:1}"
        sleep 0.12
        printf "\r$(tput el)"
    done
    printf " ${GREEN}Done${NC}\n"
}

# === Power on (used elsewhere) ===
ensure_node_on() {
    local n=$1
    if ping -c1 "p${n}.local" >/dev/null 2>&1; then
        printf "   ${GREEN}p%s is online${NC}\n" "$n"; return 0
    fi
    printf "   ${YELLOW}p%s off → powering on${NC}" "$n"
    sudo clusterctrl on p${n} >/dev/null 2>&1 || { log_err "$n" "clusterctrl failed"; return 1; }
    wait_for_node "$n" || { log_err "$n" "boot timeout"; return 1; }
    return 0
}

# === Log error ===
log_err() {
    local n=$1 e=$2 f=$3
    echo -e "${RED}ERR p${n}:${NC} $e" >&2
    echo "   → $f" >&2
    FAILURE_REASONS["p${n}"]+="$e; "
    FAILED_NODES+=("p${n}")
}

# === Prompt ===
prompt_continue() {
    local node=$1
    echo -n "   Continue with p${node}? [Y/n/skip] (10s auto-yes): "
    read -t 10 answer || answer="y"
    case "${answer,,}" in
        n|no) echo "   ${RED}Canceled.${NC}"; return 1 ;;
        s|skip) echo "   ${YELLOW}Skipped p${node}.${NC}"; return 2 ;;
        *) return 0 ;;
    esac
}

# === SSH Key Setup ===
deploy_master_ssh_key() {
    echo -e "\n${PURPLE}SSH Key Setup (Master → Workers)${NC}"
    echo "────────────────────────────────────"
    echo "Generating key on master and deploying..."

    if [ ! -f "$HOME/.ssh/id_rsa" ]; then
        echo -n "   ${BLUE}Generating key${NC}"
        ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -q -N "" &>/dev/null
        printf " ${GREEN}%s${NC}\n" "$CHECK"
        TASKS+=("SSH Key Generation" "Success")
    else
        printf "   ${YELLOW}Using existing key${NC}\n"
        TASKS+=("SSH Key Generation" "Skipped")
    fi

    local all_good=1
    for n in {1..4}; do
        ensure_node_on "$n" && TASKS+=("Power On p$n" "Success") || { all_good=0; TASKS+=("Power On p$n" "Failed"); continue; }
        echo -n "   ${BLUE}Deploying to p${n}${NC}"
        sshpass -p "$SSH_PASS" ssh-copy-id -o StrictHostKeyChecking=no "$SSH_USER@p${n}.local" &>/tmp/sshcopy.log &
        spin $! ""
        if grep -q "Number of key(s) added: 1" /tmp/sshcopy.log 2>/dev/null; then
            printf " ${GREEN}%s${NC}\n" "$CHECK"
            TASKS+=("SSH Deploy p$n" "Success")
        else
            printf " ${RED}%s${NC}\n" "$CROSS"
            log_err "p${n}" "ssh-copy-id failed"
            TASKS+=("SSH Deploy p$n" "Failed")
            all_good=0
        fi
        rm -f /tmp/sshcopy.log
    done

    if [ $all_good -eq 1 ]; then
        echo -e "\n   ${GREEN}Keys deployed${NC}"
        echo -e "   ${YELLOW}Continuing in 5s...${NC}"
        for i in {5..1}; do printf "   ${CYAN}→ %s${NC} " "$i"; sleep 1; done; echo; echo
        USE_SSH_KEYS=1
    else
        echo -e "   ${YELLOW}Using password auth${NC}\n"
        USE_SSH_KEYS=0
    fi
}

# === Retry Failed Nodes ===
retry_failed_nodes() {
    [ ${#FAILED_NODES[@]} -eq 0 ] && return
    echo -e "\n${BOLD}${YELLOW}Retry failed nodes? [Y/n]${NC}"
    read -t 10 answer || answer="y"
    [[ "$answer" =~ ^[Nn]$ ]] && return

    local retry_list=("${FAILED_NODES[@]}")
    FAILED_NODES=()
    FAILURE_REASONS=()

    for n in "${retry_list[@]}"; do
        local node_num=${n#p}
        echo -e "\n${BOLD}${CYAN}Retrying p${node_num}${NC}"
        echo "──────"
        local ok=1

        ensure_node_on "$node_num" || ok=0
        run_ssh_cmd "$node_num" "sudo apt update -y" "   ${BLUE}Update${NC}" || ok=0
        run_ssh_cmd "$node_num" "sudo apt full-upgrade -y" "   ${BLUE}Upgrade${NC}" || ok=0
        run_ssh_cmd "$node_num" "sudo apt autoremove -y" "   ${BLUE}Clean${NC}" || ok=0

        echo -n "   ${BLUE}Reboot${NC}"
        if [ $USE_SSH_KEYS -eq 1 ]; then
            ssh -o StrictHostKeyChecking=no "$SSH_USER@p${node_num}.local" "sudo reboot" &>/tmp/ssh.log &
        else
            sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@p${node_num}.local" "sudo reboot" &>/tmp/ssh.log &
        fi
        spin $! "   rebooting"
        [ -s /tmp/ssh.log ] && TASKS+=("p$node_num: reboot" "Failed") || TASKS+=("p$node_num: reboot" "Success")
        rm -f /tmp/ssh.log

        wait_for_node "$node_num" || ok=0
        run_ssh_cmd "$node_num" "
            sudo apt install -y chrony &>/dev/null;
            echo 'server $MASTER_IP iburst' | sudo tee /etc/chrony/conf.d/master.conf >/dev/null;
            sudo systemctl restart chrony;
            chronyc makestep &>/dev/null
        " "   ${BLUE}Chrony${NC}" || ok=0
        verify_time_sync "$node_num" || ok=0

        [ $ok -eq 1 ] && echo -e "   ${GREEN}p${node_num} recovered${NC}\n"
    done
}

clear
rotate_logs
load_config
echo
echo "${BOLD}${YELLOW}ClusterCtrl Time Sync $VERSION${NC}"
echo "────────────────────────────────────────"
echo "${CYAN}Author: UntrustedTech${NC}"
echo "Log: $LOGFILE"
echo

# === Mode & Auth ===
MODE="${MODE:-auto}"
AUTH_METHOD="${AUTH_METHOD:-keys}"

echo "${BOLD}Select mode:${NC}"
echo "  [1] ${GREEN}Automated${NC}"
echo "  [2] ${BLUE}Assisted${NC}"
read -p "Choice [1/2] (default: $MODE): " mode_choice
[[ -n "$mode_choice" ]] && MODE=$( [[ "$mode_choice" == "2" ]] && echo "assisted" || echo "auto" )

USE_SSH_KEYS=0
TASKS=()
echo
echo "${BOLD}Authentication:${NC}"
echo "  [1] ${YELLOW}Password${NC}"
echo "  [2] ${GREEN}SSH Keys${NC}"
read -p "Choice [1/2] (default: $AUTH_METHOD): " auth_choice
[[ -z "$auth_choice" ]] && auth_choice=$( [[ "$AUTH_METHOD" == "keys" ]] && echo 2 || echo 1 )

# === Prompt for credentials only if not in config ===
if [[ -z "$SSH_USER" || -z "$SSH_PASS" ]]; then
    read -p "Worker SSH User: " SSH_USER
    echo -n "Worker SSH Pass: "; read -s SSH_PASS; echo
    [[ -z "$SSH_USER" || -z "$SSH_PASS" ]] && { echo "${RED}Credentials required.${NC}"; exit 1; }
    save_config
else
    echo -e "   ${GREEN}Using saved credentials.${NC}\n"
fi

case "$auth_choice" in
    2) USE_SSH_KEYS=1 ;;
    *) echo -e "   ${YELLOW}Using password auth.${NC}\n" ;;
esac

pre_flight_check

# === Master ===
echo -e "${BOLD}${CYAN}Master Node${NC}"
echo "──────────────"
run_ssh_cmd "M" "sudo apt update -y" "   ${BLUE}Update${NC}" || true
run_ssh_cmd "M" "sudo apt full-upgrade -y" "   ${BLUE}Upgrade${NC}" || true
run_ssh_cmd "M" "sudo apt install -y chrony" "   ${BLUE}Install chrony${NC}" || true
echo -n "   ${BLUE}Config chrony${NC}"
sudo sed -i '/^#pool /d' /etc/chrony/chrony.conf 2>/dev/null
echo -e "allow 10.55.0.0/24\nlocal stratum 10" | sudo tee -a /etc/chrony/chrony.conf >/dev/null
sudo systemctl restart chrony &>/dev/null && printf " ${GREEN}%s${NC}\n\n" "$CHECK" && TASKS+=("Master: config" "Success") || { log_err "M" "chrony config"; TASKS+=("Master: config" "Failed"); }

MASTER_IP=$(hostname -I | awk '{print $1}')

[[ "$auth_choice" == "2" ]] && deploy_master_ssh_key

# === Workers ===
declare -a FAILED_NODES=()
declare -A FAILURE_REASONS

for n in {1..4}; do
    [[ "$MODE" == "assisted" ]] && prompt_continue "$n" && case $? in 1) continue ;; 2) echo -e "   ${YELLOW}Skipped p$n${NC}\n"; TASKS+=("p$n: Skipped" "User"); continue ;; esac

    echo -e "${BOLD}${CYAN}p${n}${NC}"
    echo "──────"
    local ok=1

    ensure_node_on "$n" || ok=0
    run_ssh_cmd "$n" "sudo apt update -y" "   ${BLUE}Update${NC}" || ok=0
    run_ssh_cmd "$n" "sudo apt full-upgrade -y" "   ${BLUE}Upgrade${NC}" || ok=0
    run_ssh_cmd "$n" "sudo apt autoremove -y" "   ${BLUE}Clean${NC}" || ok=0

    echo -n "   ${BLUE}Reboot${NC}"
    if [ $USE_SSH_KEYS -eq 1 ]; then
        ssh -o StrictHostKeyChecking=no "$SSH_USER@p${n}.local" "sudo reboot" &>/tmp/ssh.log &
    else
        sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no "$SSH_USER@p${n}.local" "sudo reboot" &>/tmp/ssh.log &
    fi
    spin $! "   rebooting"
    [ -s /tmp/ssh.log ] && TASKS+=("p$n: reboot" "Failed") || TASKS+=("p$n: reboot" "Success")
    rm -f /tmp/ssh.log

    wait_for_node "$n" || ok=0
    run_ssh_cmd "$n" "
        sudo apt install -y chrony &>/dev/null;
        echo 'server $MASTER_IP iburst' | sudo tee /etc/chrony/conf.d/master.conf >/dev/null;
        sudo systemctl restart chrony;
        chronyc makestep &>/dev/null
    " "   ${BLUE}Chrony${NC}" || ok=0
    verify_time_sync "$n" || ok=0

    [ $ok -eq 1 ] && echo -e "   ${GREEN}p${n} synced${NC}\n" || echo -e "   ${RED}p${n} failed${NC}\n"
done

retry_failed_nodes

# === Final Report ===
echo -e "${BOLD}${PURPLE}FINAL TASK REPORT${NC}"
printf " ${BOLD}%-50s %-12s${NC}\n" "Task" "Status"
printf " ${BOLD}%-50s %-12s${NC}\n" "──────────────────────────────────────────────────" "────────────"
for ((i=0; i<${#TASKS[@]}; i+=2)); do
    task="${TASKS[i]}"
    status="${TASKS[i+1]}"
    case "$status" in
        "Success") color="$GREEN" icon="$CHECK" ;;
        "Failed") color="$RED" icon="$CROSS" ;;
        "Skipped*") color="$YELLOW" icon="$WARN" ;;
        *) color="$NC" icon="Circle" ;;
    esac
    printf " %-50s ${color}%s %s${NC}\n" "$task" "$icon" "$status"
done

if [ ${#FAILED_NODES[@]} -eq 0 ]; then
    echo -e "\n${BOLD}${GREEN}Cluster fully synchronized!${NC}"
else
    echo -e "\n${BOLD}${RED}Sync incomplete:${NC}"
    for n in "${FAILED_NODES[@]}"; do echo -e "   • ${RED}$n${NC}: ${FAILURE_REASONS[$n]}"; done
    echo -e "   ${YELLOW}Log: $LOGFILE${NC}"
fi
echo

# Copyright (c) 2025 UntrustedTech. All rights reserved.
# Unauthorized copying, modification, or distribution prohibited.
