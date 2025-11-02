#!/bin/bash
# Setup TigerVNC server for KDE Plasma
set -e

# Create VNC directory
mkdir -p ~/.vnc

# Create VNC password (default: deepfacelab)
# User can change this later
echo "deepfacelab" | vncpasswd -f > ~/.vnc/passwd
chmod 600 ~/.vnc/passwd

# Create xstartup script for KDE Plasma
cat > ~/.vnc/xstartup << 'EOF'
#!/bin/bash
[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources
export XKL_XMODMAP_DISABLE=1
export DESKTOP_SESSION=plasma
export XDG_CURRENT_DESKTOP=KDE
export XDG_SESSION_DESKTOP=kde-plasma
export XDG_CONFIG_DIRS=/etc/xdg/xdg-plasma:/etc/xdg
export XDG_DATA_DIRS=/usr/share/plasma:/usr/local/share:/usr/share

unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Start D-Bus session
eval $(dbus-launch --sh-syntax)
export DBUS_SESSION_BUS_ADDRESS
export DBUS_SESSION_BUS_PID

# Start KDE Plasma
startplasma-x11 &
EOF

chmod +x ~/.vnc/xstartup

echo "VNC server configured successfully"

