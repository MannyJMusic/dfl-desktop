#!/bin/bash

# Interactive Rsync Script for DeepFaceLab MacOS to Cloud Server

set -e

# Color codes for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

WORKSPACE_ROOT="/Volumes/MacOSNew/DFL/DeepFaceLab_MacOS"

# Function to print colored output
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

# Function to parse SSH config and get hosts
get_ssh_hosts() {
    local ssh_config="$HOME/.ssh/config"
    
    if [ ! -f "$ssh_config" ]; then
        print_error "SSH config file not found at $ssh_config"
        return 1
    fi
    
    # Extract host names from SSH config
    hosts=$(grep -E "^Host " "$ssh_config" | sed 's/^Host //' | grep -v "^\*$" | tr '\n' ' ')
    echo "$hosts"
}

# Function to get host details from SSH config
get_host_details() {
    local host=$1
    local ssh_config="$HOME/.ssh/config"
    local temp_file=$(mktemp)
    
    # Extract the host block using sed, excluding the next Host line (macOS compatible)
    sed -n "/^Host[[:space:]]*${host}[[:space:]]*$/,/^Host[[:space:]]/p" "$ssh_config" | sed '$d' > "$temp_file"
    
    # Parse the values (only take first match)
    SSH_HOSTNAME=$(grep -m1 "^[[:space:]]*HostName" "$temp_file" | sed 's/^[[:space:]]*HostName[[:space:]]*//')
    SSH_USER=$(grep -m1 "^[[:space:]]*User" "$temp_file" | sed 's/^[[:space:]]*User[[:space:]]*//')
    SSH_PORT=$(grep -m1 "^[[:space:]]*Port" "$temp_file" | sed 's/^[[:space:]]*Port[[:space:]]*//')
    SSH_IDENTITY_FILE=$(grep -m1 "^[[:space:]]*IdentityFile" "$temp_file" | sed 's/^[[:space:]]*IdentityFile[[:space:]]*//')
    
    # Clean up
    rm "$temp_file"
    
    # Use defaults if not specified
    SSH_USER="${SSH_USER:-$USER}"
    SSH_PORT="${SSH_PORT:-22}"
}

# Function to select SSH host
select_ssh_host() {
    echo ""
    echo "================================================"
    echo "  Select Server Connection"
    echo "================================================"
    echo ""
    
    # Get list of SSH hosts
    hosts=$(get_ssh_hosts)
    
    if [ -z "$hosts" ]; then
        print_warning "No hosts found in SSH config. Using manual entry."
        return 1
    fi
    
    # Count hosts
    host_array=($hosts)
    host_count=${#host_array[@]}
    
    echo "Existing SSH connections:"
    echo ""
    
    # Display hosts with details
    local idx=1
    declare -a host_names
    
    for host in $hosts; do
        get_host_details "$host"
        host_names[$idx]="$host"
        
        if [ -n "$SSH_HOSTNAME" ]; then
            if [ -n "$SSH_IDENTITY_FILE" ]; then
                printf "  %d. %s\n" "$idx" "$host"
                printf "     → %s (user: %s, port: %s, key: %s)\n" "$SSH_HOSTNAME" "$SSH_USER" "$SSH_PORT" "$SSH_IDENTITY_FILE"
            else
                printf "  %d. %s\n" "$idx" "$host"
                printf "     → %s (user: %s, port: %s)\n" "$SSH_HOSTNAME" "$SSH_USER" "$SSH_PORT"
            fi
        fi
        echo ""
        ((idx++))
    done
    
    # Manual entry option
    printf "  %d. Manual entry (specify connection details)\n\n" "$idx"
    
    echo "================================================"
    echo ""
    read -p "Select option (1-$idx): " choice
    
    if [ "$choice" -eq "$idx" ] 2>/dev/null; then
        # Manual entry
        manual_connection_entry
        return 0
    elif [ "$choice" -ge 1 ] && [ "$choice" -le $host_count ] 2>/dev/null; then
        # Selected existing host
        SERVER_HOST="${host_names[$choice]}"
        get_host_details "$SERVER_HOST"
        print_success "Selected: $SERVER_HOST ($SSH_USER@$SSH_HOSTNAME:$SSH_PORT)"
        return 0
    else
        print_error "Invalid choice"
        exit 1
    fi
}

# Function for manual connection entry
manual_connection_entry() {
    echo ""
    echo "Enter connection details manually:"
    echo ""
    
    read -p "Hostname or IP: " manual_hostname
    if [ -z "$manual_hostname" ]; then
        print_error "Hostname is required"
        exit 1
    fi
    
    read -p "Username [$USER]: " manual_user
    manual_user="${manual_user:-$USER}"
    
    read -p "Port [22]: " manual_port
    manual_port="${manual_port:-22}"
    
    read -p "SSH Key path (optional): " manual_key
    
    # Store values
    SSH_HOSTNAME="$manual_hostname"
    SSH_USER="$manual_user"
    SSH_PORT="$manual_port"
    SSH_IDENTITY_FILE="$manual_key"
    
    # Create temporary host identifier for display
    SERVER_HOST="manual-$manual_hostname"
    
    print_success "Manual entry: $SSH_USER@$SSH_HOSTNAME:$SSH_PORT"
    
    if [ -n "$SSH_IDENTITY_FILE" ]; then
        print_info "Using SSH key: $SSH_IDENTITY_FILE"
    fi
}

# Function to get sync direction
get_sync_direction() {
    echo ""
    echo "================================================"
    echo "  Sync Direction"
    echo "================================================"
    echo ""
    echo "  1. Push TO server (Mac → Cloud)"
    echo "  2. Pull FROM server (Cloud → Mac)"
    echo ""
    echo "================================================"
    echo ""
    read -p "Select direction (1-2): " direction_choice
    
    case $direction_choice in
        1)
            SYNC_DIRECTION="push"
            print_success "Direction: Push to server (Mac → Cloud)"
            ;;
        2)
            SYNC_DIRECTION="pull"
            print_success "Direction: Pull from server (Cloud → Mac)"
            ;;
        *)
            print_error "Invalid choice"
            exit 1
            ;;
    esac
}

# Function to display menu
display_menu() {
    echo ""
    echo "================================================"
    if [ "$SYNC_DIRECTION" = "push" ]; then
        echo "  Rsync to Cloud Server"
    else
        echo "  Rsync from Cloud Server"
    fi
    echo "================================================"
    echo ""
    
    if [ "$SYNC_DIRECTION" = "push" ]; then
        echo "Source (Local - Mac):"
        echo "  1. Full DeepFaceLab directory (everything)"
        echo "  2. Workspace only"
        echo "  3. .dfl directory (code only)"
        echo "  4. Custom directory"
        echo ""
        echo "Destination (Remote):"
        echo "  5. /root/DeepFaceLab/"
        echo "  6. /root/DFL-Backup/"
        echo "  7. /root/workspace/"
        echo "  8. Custom destination"
    else
        echo "Source (Remote):"
        echo "  1. /root/DeepFaceLab/"
        echo "  2. /root/DFL-Backup/"
        echo "  3. /root/workspace/"
        echo "  4. Custom source"
        echo ""
        echo "Destination (Local - Mac):"
        echo "  5. Full DeepFaceLab directory (everything)"
        echo "  6. Workspace only"
        echo "  7. .dfl directory (code only)"
        echo "  8. Custom directory"
    fi
    echo ""
    echo "================================================"
    echo ""
}

# Function to get source directory
get_source() {
    echo -e "${BLUE}Select source directory:${NC}"
    read -p "Choice (1-4): " choice
    
    if [ "$SYNC_DIRECTION" = "push" ]; then
        # Push: source is local
        case $choice in
            1)
                SOURCE="$WORKSPACE_ROOT/"
                ;;
            2)
                SOURCE="$WORKSPACE_ROOT/workspace/"
                ;;
            3)
                SOURCE="$WORKSPACE_ROOT/.dfl/"
                ;;
            4)
                echo ""
                read -p "Enter custom source path: " custom_source
                if [ ! -d "$custom_source" ]; then
                    print_error "Directory does not exist: $custom_source"
                    exit 1
                fi
                SOURCE="$custom_source/"
                ;;
            *)
                print_error "Invalid choice"
                exit 1
                ;;
        esac
    else
        # Pull: source is remote
        case $choice in
            1)
                SOURCE="/root/DeepFaceLab/"
                ;;
            2)
                SOURCE="/root/DFL-Backup/"
                ;;
            3)
                SOURCE="/root/workspace/"
                ;;
            4)
                echo ""
                read -p "Enter custom source path: " custom_source
                SOURCE="$custom_source/"
                ;;
            *)
                print_error "Invalid choice"
                exit 1
                ;;
        esac
    fi
    
    print_success "Source: $SOURCE"
}

# Function to get destination directory
get_destination() {
    echo ""
    echo -e "${BLUE}Select destination directory:${NC}"
    read -p "Choice (5-8): " choice
    
    if [ "$SYNC_DIRECTION" = "push" ]; then
        # Push: destination is remote
        case $choice in
            5)
                DEST="/root/DeepFaceLab/"
                ;;
            6)
                DEST="/root/DFL-Backup/"
                ;;
            7)
                DEST="/root/workspace/"
                ;;
            8)
                echo ""
                read -p "Enter custom destination path: " custom_dest
                DEST="$custom_dest/"
                ;;
            *)
                print_error "Invalid choice"
                exit 1
                ;;
        esac
    else
        # Pull: destination is local
        case $choice in
            5)
                DEST="$WORKSPACE_ROOT/"
                ;;
            6)
                DEST="$WORKSPACE_ROOT/workspace/"
                ;;
            7)
                DEST="$WORKSPACE_ROOT/.dfl/"
                ;;
            8)
                echo ""
                read -p "Enter custom destination path: " custom_dest
                if [ ! -d "$(dirname "$custom_dest")" ]; then
                    print_warning "Parent directory does not exist: $(dirname "$custom_dest")"
                    read -p "Create it? (y/N): " create_it
                    if [[ $create_it =~ ^[Yy]$ ]]; then
                        mkdir -p "$custom_dest"
                    else
                        print_error "Cannot proceed without destination directory"
                        exit 1
                    fi
                fi
                DEST="$custom_dest/"
                ;;
            *)
                print_error "Invalid choice"
                exit 1
                ;;
        esac
    fi
    
    print_success "Destination: $DEST"
}

# Function to confirm before syncing
confirm() {
    echo ""
    echo "================================================"
    echo -e "${YELLOW}Review Settings:${NC}"
    echo "================================================"
    echo "Server: $SERVER_HOST"
    echo "Connection: $SSH_USER@$SSH_HOSTNAME:$SSH_PORT"
    if [ -n "$SSH_IDENTITY_FILE" ]; then
        echo "SSH Key: $SSH_IDENTITY_FILE"
    fi
    echo "Source: $SOURCE"
    echo "Destination: $DEST"
    echo "================================================"
    echo ""
    read -p "Proceed with sync? (y/N): " confirm_choice
    
    case $confirm_choice in
        [Yy]* )
            return 0
            ;;
        * )
            print_warning "Sync cancelled"
            exit 0
            ;;
    esac
}

# Function to show advanced options
get_advanced_options() {
    echo ""
    echo -e "${BLUE}Advanced Options:${NC}"
    echo ""
    read -p "Exclude large video files? (y/N): " exclude_videos
    read -p "Show detailed progress? (Y/n): " show_progress
    
    if [ "$SYNC_DIRECTION" = "push" ]; then
        read -p "Delete files on server not in source? (y/N): " delete_extra
    else
        read -p "Delete files in destination not in source? (y/N): " delete_extra
    fi
    
    read -p "Dry run (test without copying)? (y/N): " dry_run
    read -p "Limit bandwidth (MB/s, or press Enter for no limit): " bandwidth
    
    # Build rsync options
    RSYNC_OPTS="-avz"
    
    if [[ $exclude_videos =~ ^[Yy]$ ]]; then
        RSYNC_OPTS="$RSYNC_OPTS --exclude='*.avi' --exclude='*.mp4' --exclude='*.mov' --exclude='*.mkv'"
    fi
    
    if [[ $show_progress =~ ^[Yy]$ ]] || [[ -z "$show_progress" ]]; then
        RSYNC_OPTS="$RSYNC_OPTS --progress"
    fi
    
    if [[ $delete_extra =~ ^[Yy]$ ]]; then
        RSYNC_OPTS="$RSYNC_OPTS --delete"
    fi
    
    if [[ $dry_run =~ ^[Yy]$ ]]; then
        RSYNC_OPTS="$RSYNC_OPTS --dry-run"
        print_warning "DRY RUN MODE - no files will be copied"
    fi
    
    if [ ! -z "$bandwidth" ]; then
        RSYNC_OPTS="$RSYNC_OPTS --bwlimit=$bandwidth"
    fi
    
    # Common exclusions for DeepFaceLab
    RSYNC_OPTS="$RSYNC_OPTS --exclude='.DS_Store'"
    RSYNC_OPTS="$RSYNC_OPTS --exclude='__pycache__/'"
    RSYNC_OPTS="$RSYNC_OPTS --exclude='*.pyc'"
    
    echo ""
    print_info "Rsync options: $RSYNC_OPTS"
}

# Function to test connection
test_connection() {
    print_info "Testing connection to $SSH_USER@$SSH_HOSTNAME:$SSH_PORT..."
    
    # Build SSH command with options
    SSH_CMD="ssh"
    SSH_OPTS="-o ConnectTimeout=10"
    
    if [ -n "$SSH_PORT" ]; then
        SSH_OPTS="$SSH_OPTS -p $SSH_PORT"
    fi
    
    if [ -n "$SSH_IDENTITY_FILE" ]; then
        SSH_OPTS="$SSH_OPTS -i $SSH_IDENTITY_FILE"
    fi
    
    # Test connection
    if $SSH_CMD $SSH_OPTS "$SSH_USER@$SSH_HOSTNAME" "echo 'Connection successful'" > /dev/null 2>&1; then
        print_success "Connection test passed"
        return 0
    else
        print_error "Cannot connect to server. Please check your settings."
        exit 1
    fi
}

# Function to perform sync
do_sync() {
    echo ""
    print_info "Starting rsync..."
    echo ""
    
    # Build SSH options for rsync
    SSH_OPTS_FOR_RSYNC="-e"
    SSH_CMD_FOR_RSYNC="ssh"
    
    if [ -n "$SSH_PORT" ]; then
        SSH_CMD_FOR_RSYNC="$SSH_CMD_FOR_RSYNC -p $SSH_PORT"
    fi
    
    if [ -n "$SSH_IDENTITY_FILE" ]; then
        SSH_CMD_FOR_RSYNC="$SSH_CMD_FOR_RSYNC -i $SSH_IDENTITY_FILE"
    fi
    
    # Build the full command based on direction
    if [ "$SYNC_DIRECTION" = "push" ]; then
        # Push: local SOURCE → remote DEST
        FULL_COMMAND="rsync $RSYNC_OPTS $SSH_OPTS_FOR_RSYNC \"$SSH_CMD_FOR_RSYNC\" $SOURCE ${SSH_USER}@${SSH_HOSTNAME}:${DEST}"
    else
        # Pull: remote SOURCE → local DEST
        FULL_COMMAND="rsync $RSYNC_OPTS $SSH_OPTS_FOR_RSYNC \"$SSH_CMD_FOR_RSYNC\" ${SSH_USER}@${SSH_HOSTNAME}:${SOURCE} $DEST"
    fi
    
    print_info "Command: $FULL_COMMAND"
    echo ""
    
    # Execute rsync
    eval "$FULL_COMMAND"
    
    # Check exit status
    if [ $? -eq 0 ]; then
        echo ""
        print_success "Sync completed successfully!"
    else
        print_error "Sync failed!"
        exit 1
    fi
}

# Main execution
main() {
    # Check if rsync is installed
    if ! command -v rsync &> /dev/null; then
        print_error "rsync is not installed. Please install it first."
        exit 1
    fi
    
    # Select SSH host
    select_ssh_host
    
    # Get sync direction
    get_sync_direction
    
    # Display menu and get input
    display_menu
    get_source
    get_destination
    
    # Show advanced options
    get_advanced_options
    
    # Confirm
    if ! confirm; then
        exit 0
    fi
    
    # Test connection
    test_connection
    
    # Perform sync
    do_sync
    
    # Show completion summary
    echo ""
    echo "================================================"
    print_success "Sync Complete!"
    echo "================================================"
    print_info "Server: $SSH_USER@$SSH_HOSTNAME:$SSH_PORT"
    print_info "Source: $SOURCE"
    print_info "Destination: $DEST"
    echo ""
}

# Run main function
main
