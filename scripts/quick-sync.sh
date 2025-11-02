#!/bin/bash

# Quick rsync script with minimal options for fast syncing

set -e

SERVER_HOST="dfl-vast"
WORKSPACE_ROOT="/Volumes/MacOSNew/DFL/DeepFaceLab_MacOS"

# Default values (can be overridden with environment variables)
SOURCE_DIR="${1:-$WORKSPACE_ROOT/workspace/}"
DEST_DIR="${2:-/root/workspace/}"

# Rsync options
RSYNC_OPTS="-avz --progress --exclude='*.avi' --exclude='*.mp4' --exclude='*.mov' --exclude='.DS_Store'"

echo "=========================================="
echo "  Quick Sync to dfl-vast Server"
echo "=========================================="
echo "Source: $SOURCE_DIR"
echo "Destination: $DEST_DIR"
echo "=========================================="
echo ""

# Test connection
echo "Testing connection..."
if ! ssh -o ConnectTimeout=10 "$SERVER_HOST" "echo OK" > /dev/null 2>&1; then
    echo "ERROR: Cannot connect to $SERVER_HOST"
    exit 1
fi

# Sync
rsync $RSYNC_OPTS "$SOURCE_DIR" "${SERVER_HOST}:${DEST_DIR}"

echo ""
echo "Sync complete!"
echo ""
echo "Usage:"
echo "  ./scripts/quick-sync.sh [source_dir] [dest_dir]"
echo ""
echo "Examples:"
echo "  ./scripts/quick-sync.sh"
echo "  ./scripts/quick-sync.sh workspace/ /root/workspace/"
echo "  ./scripts/quick-sync.sh .dfl/ /root/.dfl/"

