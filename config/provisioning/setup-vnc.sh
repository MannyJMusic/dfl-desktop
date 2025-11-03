#!/bin/bash
# Setup TigerVNC server for KDE Plasma
set -e

# Create VNC directory
mkdir -p ~/.vnc

# Create VNC password (default: deepfacelab)
# User can change this later
echo "deepfacelab" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# Create xstartup script with KDE Plasma (with XFCE fallback)
cat > ~/.vnc/xstartup << 'EOF'
#!/bin/bash
# Redirect output to log file for debugging
LOG_FILE="$HOME/.vnc/xstartup.log"
exec > "$LOG_FILE" 2>&1

echo "=== VNC xstartup script starting at $(date) ==="

# Load X resources if available
[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources

export XKL_XMODMAP_DISABLE=1
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Start D-Bus session
echo "Starting D-Bus session..."
eval $(dbus-launch --sh-syntax)
export DBUS_SESSION_BUS_ADDRESS
export DBUS_SESSION_BUS_PID
echo "D-Bus started: $DBUS_SESSION_BUS_ADDRESS"

# Wait for D-Bus to be ready
sleep 2

# Try to start KDE Plasma first
KDE_STARTED=false
if command -v startplasma-x11 >/dev/null 2>&1; then
    echo "Attempting to start KDE Plasma..."
    export DESKTOP_SESSION=plasma
    export XDG_CURRENT_DESKTOP=KDE
    export XDG_SESSION_DESKTOP=kde-plasma
    export XDG_CONFIG_DIRS=/etc/xdg/xdg-plasma:/etc/xdg
    export XDG_DATA_DIRS=/usr/share/plasma:/usr/local/share:/usr/share
    
    # Start KDE in background
    startplasma-x11 &
    KDE_PID=$!
    
    # Wait a few seconds to see if KDE starts successfully
    sleep 5
    
    # Check if KDE process is still running and check for KDE processes
    if kill -0 $KDE_PID 2>/dev/null || pgrep -f "plasma" >/dev/null 2>&1; then
        echo "KDE Plasma appears to be running (PID: $KDE_PID)"
        KDE_STARTED=true
        # Keep waiting for KDE (this keeps the session alive)
        wait $KDE_PID 2>/dev/null || echo "KDE Plasma process ended"
    else
        echo "KDE Plasma failed to start or exited quickly, falling back to XFCE4"
        KDE_STARTED=false
    fi
fi

# Fallback to XFCE4 if KDE failed or not available
if [ "$KDE_STARTED" = "false" ]; then
    echo "Starting XFCE4 desktop environment..."
    export DESKTOP_SESSION=xfce
    export XDG_CURRENT_DESKTOP=XFCE
    export XDG_SESSION_DESKTOP=xfce
    
    # Start XFCE session using exec to replace shell and keep session alive
    if command -v startxfce4 >/dev/null 2>&1; then
        echo "Using startxfce4 command"
        exec startxfce4
    elif command -v xfce4-session >/dev/null 2>&1; then
        echo "Using xfce4-session command"
        exec xfce4-session
    else
        echo "ERROR: Neither KDE nor XFCE available, starting xterm as last resort"
        xterm -geometry 80x24+0+0 &
        wait
    fi
fi
EOF

chmod +x ~/.vnc/xstartup

echo "VNC server configured successfully"

