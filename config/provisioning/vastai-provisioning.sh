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

# Detect system versions
echo "Detecting system versions..."
CUDA_VERSION=""
CUDNN_VERSION=""
PYTHON_VERSION="3.10"

# Detect CUDA version
if command -v nvidia-smi &> /dev/null; then
    CUDA_VERSION=$(nvidia-smi | grep -oP "CUDA Version: \K[0-9]+\.[0-9]+" | head -1)
    echo "Detected CUDA Version: ${CUDA_VERSION}"
else
    echo "Warning: nvidia-smi not found, cannot detect CUDA version"
fi

# Detect cuDNN version
if [ -f /usr/include/cudnn_version.h ]; then
    CUDNN_MAJOR=$(grep CUDNN_MAJOR /usr/include/cudnn_version.h | awk '{print $3}')
    CUDNN_MINOR=$(grep CUDNN_MINOR /usr/include/cudnn_version.h | awk '{print $3}')
    CUDNN_VERSION="${CUDNN_MAJOR}.${CUDNN_MINOR}"
    echo "Detected cuDNN Version: ${CUDNN_VERSION}"
elif ldconfig -p | grep -q libcudnn; then
    # Try to detect from library files
    CUDNN_LIB=$(ldconfig -p | grep libcudnn.so | head -1 | awk '{print $NF}')
    if [ -n "$CUDNN_LIB" ]; then
        CUDNN_VERSION=$(echo "$CUDNN_LIB" | grep -oP "libcudnn\.so\.\K[0-9]+" | head -1)
        echo "Detected cuDNN Version: ${CUDNN_VERSION} (from library)"
    fi
else
    echo "Warning: cuDNN not detected in system"
fi

# Determine TensorFlow version based on CUDA version
if [ -n "$CUDA_VERSION" ]; then
    CUDA_MAJOR=$(echo $CUDA_VERSION | cut -d. -f1)
    if [ "$CUDA_MAJOR" -ge 12 ]; then
        TENSORFLOW_VERSION="2.16.1"
        TENSORFLOW_INSTALL="tensorflow[and-cuda]==2.16.1"
        echo "CUDA 12.x detected - will install TensorFlow $TENSORFLOW_VERSION with bundled CUDA libraries"
    elif [ "$CUDA_MAJOR" -eq 11 ]; then
        TENSORFLOW_VERSION="2.13.0"
        TENSORFLOW_INSTALL="tensorflow==$TENSORFLOW_VERSION"
        echo "CUDA 11.x detected - will install TensorFlow $TENSORFLOW_VERSION"
    else
        TENSORFLOW_VERSION="2.16.1"
        TENSORFLOW_INSTALL="tensorflow[and-cuda]==2.16.1"
        echo "CUDA version unclear - defaulting to TensorFlow $TENSORFLOW_VERSION with bundled CUDA"
    fi
else
    TENSORFLOW_VERSION="2.16.1"
    TENSORFLOW_INSTALL="tensorflow[and-cuda]==2.16.1"
    echo "CUDA not detected - will install TensorFlow with bundled CUDA libraries"
fi

# Install system dependencies
echo "Installing system dependencies..."
# Update package lists (ignore NVIDIA repo errors - CUDA is already in base image)
if ! apt-get update; then
    echo "Warning: Some repositories failed to update (non-critical)"
fi

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
    tigervnc-standalone-server \
    tigervnc-tools \
    tigervnc-xorg-extension \
    tigervnc-common \
    dbus-x11 \
    x11-xserver-utils \
    xfce4 \
    xfce4-goodies \
    xfce4-notifyd \
    kde-config-screenlocker \
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
# Note: Supervisor may log "ERROR: no such process/group: cron" messages - these are harmless and expected
echo "Fixing cron crash loop issue..."

# First, try to stop and remove via supervisorctl (suppress all output to reduce log noise)
if command -v supervisorctl &> /dev/null; then
    # Stop and remove cron service from supervisor (ignore errors as cron may not exist)
    supervisorctl stop cron >/dev/null 2>&1 || true
    supervisorctl remove cron >/dev/null 2>&1 || true
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
    # Reload supervisor config (suppress output to reduce noise)
    supervisorctl reread >/dev/null 2>&1 || true
    supervisorctl update >/dev/null 2>&1 || true
    # Make sure cron is still stopped and removed (suppress output)
    supervisorctl stop cron >/dev/null 2>&1 || true
    supervisorctl remove cron >/dev/null 2>&1 || true
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

# Create conda activation script to set OpenBLAS thread limits and CUDA library paths
mkdir -p ${CONDA_ENV_PATH}/etc/conda/activate.d
cat > ${CONDA_ENV_PATH}/etc/conda/activate.d/env_vars.sh << 'EOF'
#!/bin/bash
# Limit OpenBLAS threads to prevent resource exhaustion
export OPENBLAS_NUM_THREADS=4
export GOTO_NUM_THREADS=4
export OMP_NUM_THREADS=4

# Add NVIDIA CUDA libraries to LD_LIBRARY_PATH for TensorFlow GPU support
# Use hardcoded path since ${CONDA_PREFIX} may not be set during activation
NVIDIA_LIBS="/opt/conda-envs/deepfacelab/lib/python3.10/site-packages/nvidia"
if [ -d "$NVIDIA_LIBS" ]; then
    NVIDIA_LIB_DIRS=$(find "$NVIDIA_LIBS" -name 'lib' -type d 2>/dev/null | tr '\n' ':')
    if [ -n "$NVIDIA_LIB_DIRS" ]; then
        export LD_LIBRARY_PATH="${NVIDIA_LIB_DIRS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
fi
EOF
chmod +x ${CONDA_ENV_PATH}/etc/conda/activate.d/env_vars.sh

# Upgrade pip
python -m pip install --no-cache-dir --upgrade pip setuptools wheel

# Install TensorFlow with GPU support (version determined by CUDA detection)
echo "Installing TensorFlow ${TENSORFLOW_VERSION}..."
python -m pip install --no-cache-dir ${TENSORFLOW_INSTALL}

# Install DeepFaceLab Python dependencies
# Note: Updated versions for TensorFlow 2.16.1 compatibility
echo "Installing DeepFaceLab dependencies..."
python -m pip install --no-cache-dir \
    tqdm \
    numpy==1.23.5 \
    numexpr \
    "h5py>=3.10.0" \
    opencv-python==4.8.1.78 \
    ffmpeg-python==0.1.17 \
    scikit-image==0.21.0 \
    scipy==1.11.3 \
    colorama \
    pyqt5 \
    "tf2onnx>=1.16.0" \
    Flask==2.3.3 \
    flask-socketio==5.3.5 \
    tensorboardX \
    crc32c \
    jsonschema \
    Jinja2==3.1.2 \
    "werkzeug>=2.3.7" \
    itsdangerous==2.1.2 \
    pyyaml

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

# Create xstartup script for XFCE4 Desktop Environment
cat > ${VNC_HOME}/.vnc/xstartup << 'EOF'
#!/bin/bash
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

# Start XFCE4 Desktop Environment
if [ -x /usr/bin/startxfce4 ]; then
    /usr/bin/startxfce4 &
else
    # Fallback to simple window manager
    [ -x /usr/bin/twm ] && /usr/bin/twm &
    [ -x /usr/bin/xterm ] && /usr/bin/xterm -geometry 80x24+10+10 -ls &
fi

# Keep the script running
wait
EOF

chmod +x ${VNC_HOME}/.vnc/xstartup

# Start VNC server in background
echo "Starting VNC server..."
vncserver :1 -geometry 1920x1080 -depth 24 > /tmp/vnc-startup.log 2>&1 || true

# Set up websockify for web-based VNC access on port 6901
echo "Setting up websockify for web VNC access..."
# Ensure novnc directory exists
mkdir -p /usr/share/novnc
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
    # Kill any existing websockify processes on port 6901
    pkill -f "websockify.*6901" 2>/dev/null || true
    sleep 1
    
    # Use novnc directory if it exists, otherwise use websockify without web files
    # Bind to 0.0.0.0 to make it accessible from outside the container
    if [ -d /usr/share/novnc ]; then
        nohup websockify --web /usr/share/novnc/ --listen 0.0.0.0 6901 localhost:5901 > /tmp/websockify.log 2>&1 &
    else
        # Fallback: use websockify without web interface (raw VNC over WebSocket)
        echo "Warning: novnc web files not found, using raw websockify"
        nohup websockify --listen 0.0.0.0 6901 localhost:5901 > /tmp/websockify.log 2>&1 &
    fi
    
    # Wait a moment for websockify to start
    sleep 2
    
    # Verify websockify is running
    if pgrep -f "websockify.*6901" > /dev/null; then
        echo "Web VNC access available at http://localhost:6901/"
    else
        echo "Warning: websockify may not have started properly, check /tmp/websockify.log"
    fi
else
    echo "Warning: websockify not found, web VNC access will not be available"
fi

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
            # Use novnc directory if it exists, otherwise use raw websockify
            # Bind to 0.0.0.0 to make it accessible from outside the container
            if [ -d /usr/share/novnc ]; then
                nohup websockify --web /usr/share/novnc/ --listen 0.0.0.0 6901 localhost:5901 > /tmp/websockify.log 2>&1 &
            else
                nohup websockify --listen 0.0.0.0 6901 localhost:5901 > /tmp/websockify.log 2>&1 &
            fi
        fi
    fi
    sleep 30
done
EOF
    chmod +x /opt/supervisor-scripts/websockify.sh
fi

# Ensure cron is properly stopped (duplicate check in case supervisor restarted it)
# This is a final safeguard after creating supervisor scripts
# Note: Supervisor may log messages about cron - these are harmless
if command -v supervisorctl &> /dev/null; then
    supervisorctl stop cron >/dev/null 2>&1 || true
    supervisorctl remove cron >/dev/null 2>&1 || true
    # Don't reload here as it might restart cron - just ensure it's stopped
fi

# Create environment setup script
cat > /opt/setup-dfl-env.sh << 'EOFSETUP'
#!/bin/bash
# Activate DeepFaceLab conda environment
source "$(conda info --base 2>/dev/null || echo /opt/miniconda3)/etc/profile.d/conda.sh"
conda activate /opt/conda-envs/deepfacelab

# Limit OpenBLAS threads to prevent resource exhaustion
export OPENBLAS_NUM_THREADS=4
export GOTO_NUM_THREADS=4
export OMP_NUM_THREADS=4

# Add NVIDIA CUDA libraries to LD_LIBRARY_PATH for TensorFlow GPU support
NVIDIA_LIBS="/opt/conda-envs/deepfacelab/lib/python3.10/site-packages/nvidia"
if [ -d "$NVIDIA_LIBS" ]; then
    NVIDIA_LIB_DIRS=$(find "$NVIDIA_LIBS" -name 'lib' -type d 2>/dev/null | tr '\n' ':')
    if [ -n "$NVIDIA_LIB_DIRS" ]; then
        export LD_LIBRARY_PATH="${NVIDIA_LIB_DIRS}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
fi

export DFL_PYTHON="python"
export DFL_WORKSPACE="/opt/DFL-MVE/DeepFaceLab/workspace/"
export DFL_ROOT="/opt/DFL-MVE/DeepFaceLab/"
export DFL_SRC="/opt/DFL-MVE/DeepFaceLab/DeepFaceLab"
cd /opt/DFL-MVE/DeepFaceLab 2>/dev/null || cd /opt/DeepFaceLab 2>/dev/null || true
EOFSETUP
chmod +x /opt/setup-dfl-env.sh

# Set OpenBLAS thread limits system-wide
echo "export OPENBLAS_NUM_THREADS=4" >> /etc/environment
echo "export GOTO_NUM_THREADS=4" >> /etc/environment
echo "export OMP_NUM_THREADS=4" >> /etc/environment

# Create symlink for convenience (in /opt, not /root)
ln -sf ${DEEPFACELAB_PATH}/workspace /opt/workspace 2>/dev/null || true
ln -sf ${DEEPFACELAB_PATH} /opt/DeepFaceLab 2>/dev/null || true

echo "=== Provisioning Complete ==="
echo ""
echo "System Configuration:"
echo "  CUDA Version: ${CUDA_VERSION:-Not detected}"
echo "  cuDNN Version: ${CUDNN_VERSION:-Not detected}"
echo "  TensorFlow Version: ${TENSORFLOW_VERSION}"
echo "  Python Version: ${PYTHON_VERSION}"
echo ""
echo "Installation Paths:"
echo "  DeepFaceLab: ${DEEPFACELAB_PATH}"
echo "  Workspace: ${DEEPFACELAB_PATH}/workspace"
echo "  Conda environment: ${CONDA_ENV_PATH}"
echo ""
echo "Services:"
echo "  VNC Server: Port 5901 (Display :1)"
echo "  Web VNC: http://localhost:6901/"
echo "  VNC Password: ${VNC_PASSWORD}"
echo ""
echo "To activate environment: source /opt/setup-dfl-env.sh"

