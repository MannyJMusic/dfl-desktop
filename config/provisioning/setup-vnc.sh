#!/bin/bash
# Setup TigerVNC server for XFCE
# This script installs VNC server, configures it, and starts services on ports 5901 and 6901
set -e

echo "=== VNC Setup Script ==="

# Step 1: Install required packages
echo "Step 1: Installing VNC server and desktop environment..."
if ! command -v vncserver >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends \
        tigervnc-standalone-server \
        tigervnc-xorg-extension \
        tigervnc-common \
        xfce4 \
        xfce4-goodies \
        dbus-x11 \
        x11-xserver-utils
fi

# Step 2: Install websockify and noVNC for web access
echo "Step 2: Setting up websockify and noVNC..."
if ! command -v websockify >/dev/null 2>&1; then
    if command -v python3 >/dev/null 2>&1; then
        python3 -m pip install --no-cache-dir websockify
    elif command -v python >/dev/null 2>&1; then
        python -m pip install --no-cache-dir websockify
    fi
fi

# Setup noVNC web client
mkdir -p /usr/share/novnc
if [ ! -f /usr/share/novnc/vnc_lite.html ]; then
    echo "Downloading noVNC web client..."
    if command -v git >/dev/null 2>&1; then
        # Clone to a temporary location first, then move contents
        TEMP_NOVNC=$(mktemp -d)
        git clone --depth 1 https://github.com/novnc/noVNC.git "$TEMP_NOVNC" 2>&1 || true
        if [ -f "$TEMP_NOVNC/vnc_lite.html" ]; then
            # Copy contents to /usr/share/novnc
            cp -r "$TEMP_NOVNC"/* /usr/share/novnc/ 2>/dev/null || true
            cp -r "$TEMP_NOVNC"/.* /usr/share/novnc/ 2>/dev/null || true
            rm -rf "$TEMP_NOVNC"
            echo "noVNC downloaded successfully"
        else
            echo "Warning: noVNC clone failed, trying alternative..."
            rm -rf "$TEMP_NOVNC"
        fi
    fi
fi

# Create index.html redirect only if vnc_lite.html exists (otherwise keep the one from noVNC)
if [ -f /usr/share/novnc/vnc_lite.html ]; then
    cat > /usr/share/novnc/index.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta http-equiv="refresh" content="0; url=vnc_lite.html" />
    <title>VNC Server</title>
</head>
<body>
    <p>Redirecting to VNC client... <a href="vnc_lite.html">Click here if not redirected</a></p>
</body>
</html>
EOF
fi

# Step 3: Configure VNC
echo "Step 3: Configuring VNC server..."
VNC_HOME=/root
mkdir -p ${VNC_HOME}/.vnc

# Use VNC_PASSWORD environment variable if set, otherwise default to "deepfacelab"
VNC_PASSWORD="${VNC_PASSWORD:-deepfacelab}"

# Find vncpasswd command (could be vncpasswd or tigervncpasswd)
VNCPASSWD_CMD=$(command -v vncpasswd || command -v tigervncpasswd || echo "vncpasswd")

# Create VNC password
echo "${VNC_PASSWORD}" | ${VNCPASSWD_CMD} -f > ${VNC_HOME}/.vnc/passwd
chmod 600 ${VNC_HOME}/.vnc/passwd
echo "VNC password set to: ${VNC_PASSWORD}"

# Create xstartup script for XFCE
cat > ${VNC_HOME}/.vnc/xstartup << 'EOF'
#!/bin/bash
# Redirect output to log file for debugging
LOG_FILE="$HOME/.vnc/xstartup.log"
exec > "$LOG_FILE" 2>&1

echo "=== VNC xstartup (XFCE) starting at $(date) ==="

# Load X resources if available
[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources

export XKL_XMODMAP_DISABLE=1
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Start D-Bus session
if [ -x /usr/bin/dbus-launch ]; then
    eval $(dbus-launch --sh-syntax)
    export DBUS_SESSION_BUS_ADDRESS
    export DBUS_SESSION_BUS_PID
fi

# Start XFCE session (forever)
if command -v startxfce4 >/dev/null 2>&1; then
  exec startxfce4
elif command -v xfce4-session >/dev/null 2>&1; then
  exec xfce4-session
else
  echo "ERROR: XFCE not installed, starting xterm"
  [ -x /usr/bin/xterm ] && xterm -geometry 80x24+0+0 &
  wait
fi
EOF

chmod +x ${VNC_HOME}/.vnc/xstartup

echo "VNC server configured successfully"

# Step 4: Start VNC server
echo "Step 4: Starting VNC server on :1 (port 5901)..."
# Kill any existing VNC server on :1
vncserver -kill :1 2>/dev/null || true
sleep 1

# Start VNC server
vncserver :1 -geometry 1920x1080 -depth 24 > /tmp/vnc-startup.log 2>&1
echo "VNC server started on :1 (port 5901)"

# Step 5: Start websockify for web VNC access
echo "Step 5: Starting websockify on port 6901..."
if command -v websockify >/dev/null 2>&1; then
    # Kill any existing websockify on port 6901
    pkill -f "websockify.*6901" 2>/dev/null || true
    sleep 1
    
    # Start websockify (correct syntax: [options] [source_addr:]source_port target_addr:target_port)
    nohup websockify --web /usr/share/novnc/ 0.0.0.0:6901 localhost:5901 > /tmp/websockify.log 2>&1 &
    echo "websockify started on port 6901"
    echo ""
    echo "=== VNC Setup Complete! ==="
    echo "VNC server: localhost:5901 (use SSH tunnel)"
    echo "Web VNC: http://localhost:6901/"
    echo "Password: ${VNC_PASSWORD}"
else
    echo "WARNING: websockify not found. Web VNC access will not be available."
    echo "VNC server is running on port 5901 (SSH tunnel only)"
fi

