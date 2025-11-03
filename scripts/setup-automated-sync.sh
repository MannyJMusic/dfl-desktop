#!/bin/bash

# Setup Automated Rsync Syncing
# This script helps you set up cron jobs for automatic syncing

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

WORKSPACE_ROOT="/Volumes/MacOSNew/DFL/DeepFaceLab_MacOS"

# Log file destination (macOS vs Linux default)
if [ "$(uname -s)" = "Darwin" ]; then
    LOG_FILE="$HOME/Library/Logs/dfl-cron.log"
else
    LOG_FILE="$HOME/dfl-cron.log"
fi

# ===== SSH helpers =====
get_ssh_hosts() {
    local ssh_config="$HOME/.ssh/config"
    [ -f "$ssh_config" ] || return 1
    # list Host entries (skip wildcard)
    grep -E "^Host[[:space:]]+" "$ssh_config" | sed 's/^Host[[:space:]]\+//' | grep -v '^\*$' | tr '\n' ' '
}

get_host_details() {
    local host="$1"; local ssh_config="$HOME/.ssh/config"
    local temp=$(mktemp)
    # extract block
    sed -n "/^Host[[:space:]]\+${host}[[:space:]]*$/,/^Host[[:space:]]/p" "$ssh_config" | sed '$d' > "$temp"
    SSH_HOSTNAME=$(grep -m1 "^[[:space:]]*HostName" "$temp" | sed 's/^[[:space:]]*HostName[[:space:]]*//')
    SSH_USER=$(grep -m1 "^[[:space:]]*User" "$temp" | sed 's/^[[:space:]]*User[[:space:]]*//')
    SSH_PORT=$(grep -m1 "^[[:space:]]*Port" "$temp" | sed 's/^[[:space:]]*Port[[:space:]]*//')
    rm -f "$temp"
    [ -n "$SSH_USER" ] || SSH_USER="$USER"
    [ -n "$SSH_PORT" ] || SSH_PORT="22"
}

resolve_ssh_port() {
    # Prefer ssh -G (resolves full config). Args: host_token
    local token="$1"
    local p
    p=$(ssh -G "$token" 2>/dev/null | awk '/^port /{print $2}' | tail -n1)
    if [ -n "$p" ]; then
        echo "$p"
    else
        echo "22"
    fi
}

resolve_ssh_user() {
    local token="$1"
    local u
    u=$(ssh -G "$token" 2>/dev/null | awk '/^user /{print $2}' | tail -n1)
    if [ -n "$u" ]; then
        echo "$u"
    else
        echo "$USER"
    fi
}

select_ssh_host_prompt() {
    local hosts_list; hosts_list=$(get_ssh_hosts || true)
    if [ -z "$hosts_list" ]; then
        print_warning "No SSH hosts found in ~/.ssh/config; falling back to manual entry."
        return 1
    fi
    local tmp_hosts; tmp_hosts=$(mktemp)
    # One host per line
    echo "$hosts_list" | tr ' ' '\n' | sed '/^$/d' > "$tmp_hosts"
    echo ""
    echo "Configured SSH hosts:"
    nl -ba "$tmp_hosts" | while read -r n h; do
        ru=$(resolve_ssh_user "$h"); rp=$(resolve_ssh_port "$h")
        printf "  %d) %s  -> %s@%s:%s\n" "$n" "$h" "$ru" "$h" "$rp"
    done
    local count; count=$(wc -l < "$tmp_hosts")
    local next=$((count+1))
    echo "  $next) Manual entry"
    echo ""
    read -p "Select host (1-$next): " sel
    if [ "$sel" = "$next" ]; then
        rm -f "$tmp_hosts"
        return 1
    fi
    if [ "$sel" -ge 1 ] 2>/dev/null && [ "$sel" -le "$count" ] 2>/dev/null; then
        local chosen; chosen=$(sed -n "${sel}p" "$tmp_hosts")
        rm -f "$tmp_hosts"
        get_host_details "$chosen"
        SELECTED_HOST_ALIAS="$chosen"
        return 0
    fi
    rm -f "$tmp_hosts"
    print_error "Invalid selection"
    return 2
}

echo "=================================================="
echo "  Automated Rsync Sync Setup"
echo "=================================================="
echo ""
echo "This will help you set up automatic syncing with cron"
echo ""

# Function to add cron job
add_cron_job() {
    local schedule=$1
    local description=$2
    local command=$3
    
    print_info "Adding: $description"
    print_info "Schedule: $schedule"
    print_info "Command: $command"
    print_info "Log file: $LOG_FILE"
    echo ""
    
    # Check if job already exists
    if crontab -l 2>/dev/null | grep -q "$description"; then
        print_warning "Job '$description' already exists. Skipping..."
        return
    fi
    
    # Add to crontab
    # Append logging redirection
    local job_cmd
    job_cmd="$command >> \"$LOG_FILE\" 2>&1"
    (crontab -l 2>/dev/null; echo "$schedule $job_cmd # DFL: $description") | crontab -
    print_success "Added: $description"
    echo ""
    print_info "Tip: tail -f \"$LOG_FILE\" to watch output"
}

# Main menu
echo "Choose sync automation:"
echo ""
echo "1. Daily workspace backup at 2 AM"
echo "2. Hourly workspace sync"
echo "3. Weekly full backup on Sunday"
echo "4. Custom cron schedule"
echo "5. Show current cron jobs"
echo "6. Remove all DFL cron jobs"
echo "7. Exit"
echo ""

read -p "Choice (1-7): " choice

case $choice in
    1)
        # Daily at 2 AM
        SCHEDULE="0 2 * * *"
        DESC="Daily workspace backup at 2 AM"
        CMD="cd $WORKSPACE_ROOT && ./scripts/quick-sync.sh workspace/ /root/workspace/"
        add_cron_job "$SCHEDULE" "$DESC" "$CMD"
        ;;
    2)
        # Every hour
        SCHEDULE="0 * * * *"
        DESC="Hourly workspace sync"
        CMD="cd $WORKSPACE_ROOT && ./scripts/quick-sync.sh workspace/ /root/workspace/"
        add_cron_job "$SCHEDULE" "$DESC" "$CMD"
        ;;
    3)
        # Weekly on Sunday at 3 AM
        SCHEDULE="0 3 * * 0"
        DESC="Weekly full backup on Sunday"
        CMD="cd $WORKSPACE_ROOT && ./scripts/quick-sync.sh ./ /root/full-backup/"
        add_cron_job "$SCHEDULE" "$DESC" "$CMD"
        ;;
    4)
        echo ""
        echo "Custom cron schedule"
        echo ""
        echo "Examples:"
        echo "  '30 4 * * *'    = Every day at 4:30 AM"
        echo "  '0 */3 * * *'   = Every 3 hours"
        echo "  '0 0 * * 1'     = Every Monday at midnight"
        echo ""
        read -p "Enter cron schedule: " custom_schedule
        read -p "Enter description: " custom_desc
        
        echo ""
        echo "Choose sync type:"
        echo "1. Workspace only"
        echo "2. Full backup"
        echo "3. Custom command"
        echo "4. Model fetch (rsync over SSH)"
        read -p "Choice (1-4): " sync_type
        
        case $sync_type in
            1)
                CMD="cd $WORKSPACE_ROOT && ./scripts/quick-sync.sh workspace/ /root/workspace/"
                ;;
            2)
                CMD="cd $WORKSPACE_ROOT && ./scripts/quick-sync.sh ./ /root/full-backup/"
                ;;
            3)
                read -p "Enter custom command: " CMD
                ;;
            4)
                echo ""
                echo "Model fetch (rsync over SSH)"
                echo "Select SSH host from ~/.ssh/config or enter manually:"
                if select_ssh_host_prompt; then
                    # Force root user while honoring ~/.ssh/config (Port, IdentityFile, Proxy, etc.)
                    RSYNC_HOST_TOKEN="root@${SELECTED_HOST_ALIAS}"
                    RSYNC_SSH_CMD="ssh -F $HOME/.ssh/config"
                else
                    read -p "Remote host (user@hostname or host alias): " REMOTE_HOST
                    # Try to resolve via ssh -G; fall back to prompt if unknown
                    RESOLVED_PORT=$(resolve_ssh_port "$REMOTE_HOST")
                    read -p "Remote port [${RESOLVED_PORT}]: " REMOTE_PORT
                    RESOLVED_PORT=${REMOTE_PORT:-$RESOLVED_PORT}
                    RSYNC_HOST_TOKEN="$REMOTE_HOST"
                    # Optional key prompt for non-alias hosts
                    read -p "Path to private key (ENTER to skip): " REMOTE_KEY
                    if [ -n "$REMOTE_KEY" ]; then
                        RSYNC_SSH_CMD="ssh -p ${RESOLVED_PORT} -i ${REMOTE_KEY} -o IdentitiesOnly=yes"
                    else
                        RSYNC_SSH_CMD="ssh -p ${RESOLVED_PORT}"
                    fi
                fi
                read -p "Remote source directory (e.g., /remote/models/): " REMOTE_DIR
                read -p "Local target directory (e.g., /local/path/to/models/): " LOCAL_DIR
                echo ""
                print_info "Will sync from ${RSYNC_HOST_TOKEN}:${REMOTE_DIR} to ${LOCAL_DIR} using ~/.ssh/config"
                CMD="rsync -avz --delete -e \"${RSYNC_SSH_CMD}\" ${RSYNC_HOST_TOKEN}:${REMOTE_DIR} ${LOCAL_DIR}"
                ;;
        esac
        
        add_cron_job "$custom_schedule" "$custom_desc" "$CMD"
        ;;
    5)
        echo ""
        print_info "Current cron jobs for DFL:"
        echo "=================================================="
        crontab -l 2>/dev/null | grep "DFL:" || echo "No DFL cron jobs found"
        echo ""
        print_info "All cron jobs:"
        echo "=================================================="
        crontab -l 2>/dev/null || echo "No cron jobs found"
        ;;
    6)
        echo ""
        print_warning "Removing all DFL cron jobs..."
        crontab -l 2>/dev/null | grep -v "DFL:" | crontab -
        print_success "All DFL cron jobs removed"
        ;;
    7)
        echo "Exiting..."
        exit 0
        ;;
    *)
        print_error "Invalid choice"
        exit 1
        ;;
esac

echo ""
echo "=================================================="
print_success "Setup complete!"
echo "=================================================="
echo ""
echo "To view your cron jobs:"
echo "  crontab -l"
echo ""
echo "To edit cron jobs:"
echo "  crontab -e"
echo ""
echo "To remove all DFL cron jobs:"
echo "  crontab -l | grep -v 'DFL:' | crontab -"
echo ""

