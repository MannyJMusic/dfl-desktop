#!/bin/bash
# Vast.ai Provisioning Script for DeepFaceLab with Machine Video Editor
# This script runs on first boot to set up the environment
set -eo pipefail

# Define paths (everything goes to /opt/)
export DFL_MVE_PATH=/opt/DFL-MVE
export DEEPFACELAB_PATH=/opt/DFL-MVE/DeepFaceLab
export MVE_PATH=/opt/MachineVideoEditor
export CONDA_ENV_NAME=deepfacelab
export CONDA_ENV_PATH=/opt/conda-envs/${CONDA_ENV_NAME}

# Change to workspace for persistence
cd /workspace/

echo "=== Starting DeepFaceLab Provisioning ==="

# Install system dependencies
echo "Installing system dependencies..."
apt-get update && \
    apt-get install -y --no-install-recommends \
    git \
    wget \
    unzip \
    curl \
    build-essential \
    python3-dev \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    kde-plasma-desktop \
    kde-standard \
    kde-config-screenlocker \
    tigervnc-standalone-server \
    tigervnc-tools \
    tigervnc-xorg-extension \
    tigervnc-common \
    dbus-x11 \
    x11-xserver-utils \
    websockify \
    novnc \
    network-manager \
    openssh-server \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Configure SSH server (skip if already running)
if pgrep -x sshd > /dev/null 2>&1 || ss -tlnp 2>/dev/null | grep -q "sshd"; then
    echo "SSH server already running - skipping SSH configuration"
else
    echo "Configuring SSH server..."
    mkdir -p /var/run/sshd
    mkdir -p /root/.ssh
    # Ensure /run/sshd exists with correct ownership/permissions (Ubuntu expects this path)
    mkdir -p /run/sshd
    chown root:root /run/sshd
    chmod 755 /run/sshd

    # Configure SSH for container use (allow root login, etc.)
    SSH_CONFIG_FILE="/etc/ssh/sshd_config"
    if [ -f "$SSH_CONFIG_FILE" ]; then
        # Enable root login (needed for containers)
        sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' "$SSH_CONFIG_FILE" 2>/dev/null || \
        sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' "$SSH_CONFIG_FILE" 2>/dev/null || \
        echo "PermitRootLogin yes" >> "$SSH_CONFIG_FILE"
        
        # Allow password authentication (for Vast.ai SSH key injection)
        sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' "$SSH_CONFIG_FILE" 2>/dev/null || \
        sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' "$SSH_CONFIG_FILE" 2>/dev/null || \
        echo "PasswordAuthentication yes" >> "$SSH_CONFIG_FILE"
        
        # Ensure PubkeyAuthentication is enabled (for Vast.ai SSH keys)
        grep -q "^PubkeyAuthentication" "$SSH_CONFIG_FILE" || echo "PubkeyAuthentication yes" >> "$SSH_CONFIG_FILE"
        
        # Disable strict mode checking (helps in container environments)
        sed -i 's/#StrictModes yes/StrictModes no/' "$SSH_CONFIG_FILE" 2>/dev/null || \
        sed -i 's/StrictModes yes/StrictModes no/' "$SSH_CONFIG_FILE" 2>/dev/null
    fi

    # Generate host keys if they don't exist (required for SSH server)
    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        echo "Generating SSH host keys..."
        ssh-keygen -A
    fi

    # Start SSH service (Vast.ai base image should manage service lifecycle, but ensure it's available)
    if command -v service &> /dev/null; then
        service ssh start || service sshd start || true
    elif command -v systemctl &> /dev/null; then
        systemctl enable ssh || systemctl enable sshd || true
        systemctl start ssh || systemctl start sshd || true
    else
        # Manual start if service/systemctl not available (run in background)
        if [ -f /usr/sbin/sshd ]; then
            /usr/sbin/sshd &
        elif [ -f /usr/bin/sshd ]; then
            /usr/bin/sshd &
        fi
    fi

    echo "SSH server configured and started"
fi

# Fix cron crash loop issue early (Vast.ai base image tries to manage cron but it conflicts with system cron)
# This must be done early to prevent log spam and potential service conflicts
echo "Fixing cron crash loop issue..."

# First, try to stop via supervisorctl
if command -v supervisorctl &> /dev/null; then
    # Stop and remove cron service from supervisor
    supervisorctl stop cron 2>/dev/null || true
    supervisorctl remove cron 2>/dev/null || true
fi

# Disable cron in supervisor config files if they exist
for SUPERVISOR_CONFIG in /etc/supervisor/conf.d/*.conf /etc/supervisord.conf; do
    if [ -f "$SUPERVISOR_CONFIG" ]; then
        # Comment out any cron program entries
        sed -i 's/^\[program:cron\]/;[program:cron] DISABLED/' "$SUPERVISOR_CONFIG" 2>/dev/null || true
        sed -i 's/^command=.*cron.*/;command=cron DISABLED/' "$SUPERVISOR_CONFIG" 2>/dev/null || true
    fi
done

# Reload supervisor config after changes
if command -v supervisorctl &> /dev/null; then
    # Remove any dedicated cron program file if present to avoid parse errors
    if [ -f "/etc/supervisor/conf.d/cron.conf" ]; then
        rm -f /etc/supervisor/conf.d/cron.conf || true
    fi
    supervisorctl reread 2>/dev/null || true
    supervisorctl update 2>/dev/null || true
    # Make sure cron is still stopped
    supervisorctl stop cron 2>/dev/null || true
    supervisorctl remove cron 2>/dev/null || true
fi

# Kill any supervisor-spawned cron processes (but NOT the system cron daemon)
# Find all cron processes and kill only those not started by systemd/init
CRON_PIDS=$(pgrep -f "^/usr/sbin/cron" 2>/dev/null || true)
if [ -n "$CRON_PIDS" ]; then
    for CRON_PID in $CRON_PIDS; do
        # Check if this is the system cron (usually PID 1 or started by init)
        # If parent is supervisor, kill it
        PARENT=$(ps -o ppid= -p "$CRON_PID" 2>/dev/null | tr -d ' ' || echo "")
        if [ -n "$PARENT" ] && pgrep -f "supervisor" | grep -q "^${PARENT}$" 2>/dev/null; then
            echo "Killing supervisor-managed cron process (PID: $CRON_PID)"
            kill "$CRON_PID" 2>/dev/null || true
        fi
    done
fi

# Clean up stale cron lock files only if they're not from the system cron
if [ -f /var/run/crond.pid ]; then
    LOCK_PID=$(cat /var/run/crond.pid 2>/dev/null || echo "")
    if [ -n "$LOCK_PID" ]; then
        # Check if the lock PID is actually a running cron process
        if ! ps -p "$LOCK_PID" > /dev/null 2>&1; then
            echo "Cleaning up stale cron lock file (PID: $LOCK_PID is not running)"
            rm -f /var/run/crond.pid
        fi
    fi
fi

echo "Cron crash loop fixed"

# Install Miniconda if not present
if ! command -v conda &> /dev/null; then
    echo "Installing Miniconda..."
    MINICONDA_VERSION="Miniforge3-Linux-x86_64"
    MINICONDA_INSTALLER="${MINICONDA_VERSION}.sh"
    wget -q "https://github.com/conda-forge/miniforge/releases/latest/download/${MINICONDA_INSTALLER}" -O /tmp/${MINICONDA_INSTALLER}
    bash /tmp/${MINICONDA_INSTALLER} -b -p /opt/miniconda3
    rm /tmp/${MINICONDA_INSTALLER}
    
    # Initialize conda
    /opt/miniconda3/bin/conda init bash
    source /opt/miniconda3/etc/profile.d/conda.sh
    
    # Add conda to PATH
    export PATH="/opt/miniconda3/bin:${PATH}"
    conda config --add channels conda-forge
    conda config --add channels nvidia
else
    echo "Conda already installed, using existing installation"
    source "$(conda info --base)/etc/profile.d/conda.sh"
fi

# Create conda environment with Python 3.10
# Note: Base image already has CUDA 12.6.3 and cuDNN installed system-wide,
# so we don't need to install them via conda. TensorFlow will use system CUDA libraries.
echo "Creating conda environment: ${CONDA_ENV_NAME}..."
mkdir -p /opt/conda-envs

# Try to create environment with cudatoolkit for TensorFlow compatibility
# If that fails, create basic Python environment (TensorFlow will use system CUDA)
if ! conda create -y -p ${CONDA_ENV_PATH} python=3.10 cudatoolkit=11.8 -c nvidia -c conda-forge 2>/dev/null; then
    echo "Warning: cudatoolkit=11.8 not available, creating environment without it..."
    echo "TensorFlow will use system CUDA libraries from the base image."
    if ! conda create -y -p ${CONDA_ENV_PATH} python=3.10 -c conda-forge; then
        echo "Error: Failed to create conda environment. Trying with environment.yml if available..."
        if [ -f "/workspace/environment.yml" ]; then
            conda env create -p ${CONDA_ENV_PATH} -f /workspace/environment.yml || {
                echo "Error: All methods to create conda environment failed"
                exit 1
            }
        else
            echo "Error: Cannot create conda environment and no environment.yml found"
            exit 1
        fi
    fi
fi

# Activate conda environment
conda activate ${CONDA_ENV_PATH}

# Upgrade pip
python -m pip install --no-cache-dir --upgrade pip setuptools wheel

# Install TensorFlow 2.13 with GPU support
echo "Installing TensorFlow 2.13..."
python -m pip install --no-cache-dir tensorflow==2.13.0

# Install DeepFaceLab Python dependencies
echo "Installing DeepFaceLab dependencies..."
python -m pip install --no-cache-dir \
    tqdm \
    numpy==1.23.5 \
    numexpr \
    h5py==3.8.0 \
    opencv-python==4.8.1.78 \
    ffmpeg-python==0.1.17 \
    scikit-image==0.21.0 \
    scipy==1.11.3 \
    colorama \
    pyqt5 \
    tf2onnx==1.15.0 \
    Flask==2.3.3 \
    flask-socketio==5.3.5 \
    tensorboardX \
    crc32c \
    jsonschema \
    Jinja2==3.1.2 \
    werkzeug==2.3.7 \
    itsdangerous==2.1.2

# Clone DFL-MVE repository
echo "Cloning DFL-MVE repository..."
if [ ! -d "${DFL_MVE_PATH}" ]; then
    git clone https://github.com/MannyJMusic/DFL-MVE.git ${DFL_MVE_PATH}
else
    echo "DFL-MVE already exists, skipping clone"
fi

# Create workspace directories
echo "Creating workspace directories..."
mkdir -p ${DEEPFACELAB_PATH}/workspace
mkdir -p ${DEEPFACELAB_PATH}/workspace/data_src
mkdir -p ${DEEPFACELAB_PATH}/workspace/data_src/aligned
mkdir -p ${DEEPFACELAB_PATH}/workspace/data_src/aligned_debug
mkdir -p ${DEEPFACELAB_PATH}/workspace/data_dst
mkdir -p ${DEEPFACELAB_PATH}/workspace/data_dst/aligned
mkdir -p ${DEEPFACELAB_PATH}/workspace/data_dst/aligned_debug
mkdir -p ${DEEPFACELAB_PATH}/workspace/model

# Copy runtime scripts if they exist in workspace, otherwise create placeholder
echo "Setting up runtime scripts..."
if [ -d "/workspace/scripts" ]; then
    cp -r /workspace/scripts ${DEEPFACELAB_PATH}/scripts
    chmod +x ${DEEPFACELAB_PATH}/scripts/*.sh
else
    echo "Warning: Runtime scripts not found in /workspace/scripts"
    mkdir -p ${DEEPFACELAB_PATH}/scripts
fi

# Set up Machine Video Editor
echo "Setting up Machine Video Editor..."
mkdir -p ${MVE_PATH}
# Note: Machine Video Editor should be available in /workspace/machine-video-editor-0.8.2/
# or downloaded from a URL. Adjust this section based on your MVE source.
if [ -d "/workspace/machine-video-editor-0.8.2" ]; then
    cp -r /workspace/machine-video-editor-0.8.2/* ${MVE_PATH}/
    chmod +x ${MVE_PATH}/machine-video-editor 2>/dev/null || true
    ln -sf ${MVE_PATH}/machine-video-editor /usr/local/bin/machine-video-editor 2>/dev/null || true
else
    echo "Warning: Machine Video Editor not found in /workspace/machine-video-editor-0.8.2/"
    echo "You may need to upload it or configure download URL"
fi

# Configure VNC server
echo "Configuring VNC server..."
VNC_HOME=/root
mkdir -p ${VNC_HOME}/.vnc

# Use VNC_PASSWORD environment variable if set, otherwise default to "deepfacelab"
VNC_PASSWORD="${VNC_PASSWORD:-deepfacelab}"

# Ensure tigervnc-tools is installed (should already be in Dockerfile, but verify)
if ! command -v vncpasswd &> /dev/null && ! command -v tigervncpasswd &> /dev/null; then
    echo "Installing tigervnc-tools..."
    apt-get update && apt-get install -y --no-install-recommends tigervnc-tools && apt-get clean && rm -rf /var/lib/apt/lists/*
fi

# Find vncpasswd command (could be vncpasswd or tigervncpasswd)
VNCPASSWD_CMD=$(command -v vncpasswd || command -v tigervncpasswd || echo "vncpasswd")

# Create VNC password file using environment variable or default
echo "${VNC_PASSWORD}" | ${VNCPASSWD_CMD} -f > ${VNC_HOME}/.vnc/passwd
chmod 600 ${VNC_HOME}/.vnc/passwd
echo "VNC password configured (from VNC_PASSWORD env var or default)"

# Create xstartup script for KDE Plasma Desktop Environment
cat > ${VNC_HOME}/.vnc/xstartup << 'EOF'
#!/bin/bash
[ -r $HOME/.Xresources ] && xrdb $HOME/.Xresources

export XKL_XMODMAP_DISABLE=1
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Start D-Bus session (required for KDE Plasma)
if [ -x /usr/bin/dbus-launch ]; then
    eval $(dbus-launch --sh-syntax)
    export DBUS_SESSION_BUS_ADDRESS
    export DBUS_SESSION_BUS_PID
fi

# Set KDE environment variables for VNC
export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=KDE
export KDE_SESSION_VERSION=5

# Configure KDE for VNC (disable features that don't work well in VNC)
export QT_QPA_PLATFORM=xcb
export QT_X11_NO_MITSHM=1

# Start KDE Plasma Desktop Environment
if [ -x /usr/bin/startplasma-x11 ]; then
    /usr/bin/startplasma-x11 &
elif [ -x /usr/bin/startkde ]; then
    /usr/bin/startkde &
else
    # Fallback to simple window manager
    echo "Warning: KDE Plasma not found, using fallback window manager"
    [ -x /usr/bin/twm ] && /usr/bin/twm &
    [ -x /usr/bin/xterm ] && /usr/bin/xterm -geometry 80x24+10+10 -ls &
fi

# Keep the script running
wait
EOF

chmod +x ${VNC_HOME}/.vnc/xstartup

# Configure KDE Plasma for VNC environment
echo "Configuring KDE Plasma for VNC..."
mkdir -p ${VNC_HOME}/.config

# Create KDE configuration to optimize for VNC
cat > ${VNC_HOME}/.config/kdeglobals << 'EOF'
[KDE]
SingleClick=false
EOF

# Disable screen locking in VNC (can cause issues)
cat > ${VNC_HOME}/.config/kscreenlockerrc << 'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF

# Set KDE to use X11 session (required for VNC)
mkdir -p ${VNC_HOME}/.config/plasma-workspace/env
cat > ${VNC_HOME}/.config/plasma-workspace/env/set_window_manager.sh << 'EOF'
#!/bin/bash
export KDEWM=kwin
EOF
chmod +x ${VNC_HOME}/.config/plasma-workspace/env/set_window_manager.sh 2>/dev/null || true

# Start VNC server in background
echo "Starting VNC server..."
vncserver :1 -geometry 1920x1080 -depth 24 > /tmp/vnc-startup.log 2>&1 || true

# Set up websockify for web-based VNC access on port 6901
echo "Setting up websockify for web VNC access..."
# Create index.html redirect to vnc_lite.html for easier access
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

# Start websockify to forward port 6901 to VNC server on port 5901
if command -v websockify &> /dev/null; then
    echo "Starting websockify on port 6901..."
    nohup websockify --web /usr/share/novnc/ 6901 localhost:5901 > /tmp/websockify.log 2>&1 &
    echo "Web VNC access available at http://localhost:6901/"
else
    echo "Warning: websockify not found, web VNC access will not be available"
fi

# Set up PORTAL_CONFIG for Vast.ai Instance Portal
# VNC typically runs on port 5901, mapping to external port
# Instance Portal runs on port 11111 internally, accessible via port 1111 externally
echo "Configuring Vast.ai Portal..."

# Determine external ports assigned by Vast.ai (fallbacks to standard)
EXTERNAL_VNC_PORT="${VAST_TCP_PORT_5901:-5901}"
EXTERNAL_PORTAL_PORT="${VAST_TCP_PORT_11111:-1111}"

# Build PORTAL_CONFIG using detected external ports unless an explicit value was provided
DEFAULT_PORTAL_CONFIG="localhost:${EXTERNAL_VNC_PORT}:5901:/:VNC Desktop|localhost:${EXTERNAL_PORTAL_PORT}:11111:/:Instance Portal"
PORTAL_CONFIG_VALUE="${PORTAL_CONFIG:-$DEFAULT_PORTAL_CONFIG}"
export PORTAL_CONFIG="$PORTAL_CONFIG_VALUE"

# Write PORTAL_CONFIG to multiple locations for Vast.ai to pick it up
# 1. /etc/environment (for system-wide environment variables)
#    Use a safe replace that doesn't break on '|' or '/' in values
TMP_ENV_FILE=$(mktemp)
if [ -f /etc/environment ]; then
    grep -v '^PORTAL_CONFIG=' /etc/environment > "$TMP_ENV_FILE" || true
else
    : > "$TMP_ENV_FILE"
fi
printf 'PORTAL_CONFIG="%s"\n' "$PORTAL_CONFIG_VALUE" >> "$TMP_ENV_FILE"
mv "$TMP_ENV_FILE" /etc/environment

# 2. Ensure OPEN_BUTTON_PORT and OPEN_BUTTON_TOKEN are set
OPEN_BUTTON_PORT="${OPEN_BUTTON_PORT:-$EXTERNAL_PORTAL_PORT}"
OPEN_BUTTON_TOKEN="${OPEN_BUTTON_TOKEN:-1}"

TMP_ENV_FILE=$(mktemp)
if [ -f /etc/environment ]; then
    grep -v '^OPEN_BUTTON_PORT=' /etc/environment > "$TMP_ENV_FILE" || true
else
    : > "$TMP_ENV_FILE"
fi
printf 'OPEN_BUTTON_PORT=%s\n' "$OPEN_BUTTON_PORT" >> "$TMP_ENV_FILE"
mv "$TMP_ENV_FILE" /etc/environment

TMP_ENV_FILE=$(mktemp)
if [ -f /etc/environment ]; then
    grep -v '^OPEN_BUTTON_TOKEN=' /etc/environment > "$TMP_ENV_FILE" || true
else
    : > "$TMP_ENV_FILE"
fi
printf 'OPEN_BUTTON_TOKEN=%s\n' "$OPEN_BUTTON_TOKEN" >> "$TMP_ENV_FILE"
mv "$TMP_ENV_FILE" /etc/environment

# 3. Create portal.yaml file (Vast.ai base image may read this)
# Note: Vast.ai primarily uses PORTAL_CONFIG env var, but portal.yaml provides backup
mkdir -p /etc
# Write PORTAL_CONFIG in the expected string format
cat > /etc/portal.yaml << EOF
# Vast.ai Instance Portal Configuration
# This file is a backup - PORTAL_CONFIG env var is the primary source
# Format string: Interface:ExternalPort:InternalPort:Path:Name
${PORTAL_CONFIG_VALUE}
EOF

# Export for current session
export OPEN_BUTTON_PORT
export OPEN_BUTTON_TOKEN

# Create supervisor scripts if supervisor directory exists
if [ -d "/opt/supervisor-scripts" ]; then
    # Supervisor script for VNC
    cat > /opt/supervisor-scripts/vnc.sh << 'EOF'
#!/bin/bash
# Keep VNC server running
while true; do
    if ! pgrep -f "vncserver :1" > /dev/null; then
        vncserver :1 -geometry 1920x1080 -depth 24
    fi
    sleep 30
done
EOF
    chmod +x /opt/supervisor-scripts/vnc.sh
    
    # Supervisor script for SSH
    cat > /opt/supervisor-scripts/ssh.sh << 'EOF'
#!/bin/bash
# Keep SSH server running
while true; do
    if ! pgrep -f "sshd" > /dev/null; then
        if command -v service &> /dev/null; then
            service ssh start || service sshd start || true
        elif command -v systemctl &> /dev/null; then
            systemctl start ssh || systemctl start sshd || true
        elif [ -f /usr/sbin/sshd ]; then
            /usr/sbin/sshd &
        elif [ -f /usr/bin/sshd ]; then
            /usr/bin/sshd &
        fi
    fi
    sleep 60
done
EOF
    chmod +x /opt/supervisor-scripts/ssh.sh
    
    # Supervisor script for websockify
    cat > /opt/supervisor-scripts/websockify.sh << 'EOF'
#!/bin/bash
# Keep websockify running for web VNC access
while true; do
    if ! pgrep -f "websockify.*6901" > /dev/null; then
        if command -v websockify &> /dev/null; then
            nohup websockify --web /usr/share/novnc/ 6901 localhost:5901 > /tmp/websockify.log 2>&1 &
        fi
    fi
    sleep 30
done
EOF
    chmod +x /opt/supervisor-scripts/websockify.sh
fi

# Ensure cron is properly stopped (duplicate check in case supervisor restarted it)
# This is a final safeguard after creating supervisor scripts
if command -v supervisorctl &> /dev/null; then
    supervisorctl stop cron 2>/dev/null || true
    supervisorctl remove cron 2>/dev/null || true
    # Don't reload here as it might restart cron - just ensure it's stopped
fi

# Create environment setup script
cat > /opt/setup-dfl-env.sh << EOF
#!/bin/bash
# Activate DeepFaceLab conda environment
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate ${CONDA_ENV_PATH}
export DFL_PYTHON="python"
export DFL_WORKSPACE="${DEEPFACELAB_PATH}/workspace/"
export DFL_ROOT="${DEEPFACELAB_PATH}/"
export DFL_SRC="${DEEPFACELAB_PATH}/DeepFaceLab"
cd ${DEEPFACELAB_PATH}
EOF
chmod +x /opt/setup-dfl-env.sh

# Create symlink for convenience (in /opt, not /root)
ln -sf ${DEEPFACELAB_PATH}/workspace /opt/workspace 2>/dev/null || true
ln -sf ${DEEPFACELAB_PATH} /opt/DeepFaceLab 2>/dev/null || true

echo "=== Provisioning Complete ==="
echo "DeepFaceLab installed at: ${DEEPFACELAB_PATH}"
echo "Workspace available at: ${DEEPFACELAB_PATH}/workspace"
echo "Conda environment: ${CONDA_ENV_PATH}"
echo "To activate: source /opt/setup-dfl-env.sh"
echo "VNC server should be running on :1"

