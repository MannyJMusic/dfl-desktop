#!/bin/bash
# Setup TigerVNC server for XFCE
set -e

# Create VNC directory
mkdir -p ~/.vnc

# Create VNC password (default: deepfacelab)
# User can change this later
echo "deepfacelab" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# Create xstartup script for XFCE only
cat > ~/.vnc/xstartup << 'EOF'
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
eval $(dbus-launch --sh-syntax)
export DBUS_SESSION_BUS_ADDRESS
export DBUS_SESSION_BUS_PID

# Start XFCE session (forever)
if command -v startxfce4 >/dev/null 2>&1; then
  exec startxfce4
elif command -v xfce4-session >/dev/null 2>&1; then
  exec xfce4-session
else
  echo "ERROR: XFCE not installed, starting xterm"
  xterm -geometry 80x24+0+0 &
  wait
fi
EOF

chmod +x ~/.vnc/xstartup

echo "VNC server configured successfully"

