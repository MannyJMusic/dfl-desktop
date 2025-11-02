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
    echo ""
    
    # Check if job already exists
    if crontab -l 2>/dev/null | grep -q "$description"; then
        print_warning "Job '$description' already exists. Skipping..."
        return
    fi
    
    # Add to crontab
    (crontab -l 2>/dev/null; echo "$schedule # DFL: $description") | crontab -
    print_success "Added: $description"
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
        read -p "Choice (1-3): " sync_type
        
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

