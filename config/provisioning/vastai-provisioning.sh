#!/bin/bash
# Vast.ai Provisioning Script for DeepFaceLab with Machine Video Editor
# This script runs on first boot to set up the environment
set -eo pipefail

# Define paths (everything goes to /opt/ at same level)
export DFL_MVE_PATH=/opt/DFL-MVE
export DEEPFACELAB_PATH=/opt/DeepFaceLab
export MVE_PATH=/opt/MachineVideoEditor
export SCRIPTS_PATH=/opt/scripts
export WORKSPACE_PATH=/opt/workspace
export CONDA_ENV_NAME=deepfacelab
export CONDA_ENV_PATH=/opt/conda-envs/${CONDA_ENV_NAME}

# Change to workspace for persistence (support both /workspace and /data/workspace)
if [ -d "/data/workspace" ]; then
    cd /data/workspace/
    WORKSPACE_ROOT="/data/workspace"
elif [ -d "/workspace" ]; then
    cd /workspace/
    WORKSPACE_ROOT="/workspace"
else
    # Create workspace if it doesn't exist
    mkdir -p /workspace
    cd /workspace/
    WORKSPACE_ROOT="/workspace"
fi
export WORKSPACE_ROOT

echo "=== Starting DeepFaceLab Provisioning ==="

# Install system dependencies needed for DeepFaceLab
# Vast.ai base image has minimal packages, so we install what we need
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
    xfce4 \
    xfce4-goodies \
    openssh-server \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Configure SSH server
echo "Configuring SSH server..."
mkdir -p /var/run/sshd /root/.ssh /run/sshd
chown root:root /run/sshd
chmod 755 /run/sshd

# Configure SSH for container use
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
if [ -f "$SSH_CONFIG_FILE" ]; then
    # Enable root login (needed for containers)
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' "$SSH_CONFIG_FILE" 2>/dev/null || \
    sed -i 's/PermitRootLogin prohibit-password/PermitRootLogin yes/' "$SSH_CONFIG_FILE" 2>/dev/null || \
    echo "PermitRootLogin yes" >> "$SSH_CONFIG_FILE"
    
    # Allow password authentication
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' "$SSH_CONFIG_FILE" 2>/dev/null || \
    sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' "$SSH_CONFIG_FILE" 2>/dev/null || \
    echo "PasswordAuthentication yes" >> "$SSH_CONFIG_FILE"
    
    # Ensure PubkeyAuthentication is enabled
    grep -q "^PubkeyAuthentication" "$SSH_CONFIG_FILE" || echo "PubkeyAuthentication yes" >> "$SSH_CONFIG_FILE"
    
    # Disable strict mode checking
    sed -i 's/#StrictModes yes/StrictModes no/' "$SSH_CONFIG_FILE" 2>/dev/null || \
    sed -i 's/StrictModes yes/StrictModes no/' "$SSH_CONFIG_FILE" 2>/dev/null
fi

# Generate host keys if they don't exist
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    echo "Generating SSH host keys..."
    ssh-keygen -A
fi

# Start SSH service (in background so script can continue and exit)
if command -v service &> /dev/null; then
    service ssh start || service sshd start || true
elif [ -f /usr/sbin/sshd ]; then
    /usr/sbin/sshd &
elif [ -f /usr/bin/sshd ]; then
    /usr/bin/sshd &
fi
echo "SSH server configured and started"
# Ensure SSH continues running in background after script exits

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

# Install Miniconda if not present (Vast.ai base image may or may not have it)
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
    # Get conda base path and source it
    CONDA_BASE=$(conda info --base 2>/dev/null || echo "/opt/miniconda3")
    if [ -f "${CONDA_BASE}/etc/profile.d/conda.sh" ]; then
        source "${CONDA_BASE}/etc/profile.d/conda.sh"
    else
        # Try common locations
        if [ -f "/opt/miniconda3/etc/profile.d/conda.sh" ]; then
            source /opt/miniconda3/etc/profile.d/conda.sh
        elif [ -f "/opt/conda/etc/profile.d/conda.sh" ]; then
            source /opt/conda/etc/profile.d/conda.sh
        else
            echo "Warning: Could not find conda.sh, conda may not work properly"
        fi
    fi
fi

# Verify conda is working
if ! command -v conda &> /dev/null; then
    echo "Error: conda command not found after installation"
    exit 1
fi

# Ensure conda is initialized for this script
if ! conda info --envs &> /dev/null; then
    echo "Error: conda is not properly initialized"
    exit 1
fi

echo "Conda initialized successfully"

# Use Vast.ai base image's venv instead of creating conda environment
# The base image automatically activates /venv/main/ on SSH, so we'll install there
echo "Using Vast.ai base image's venv for DeepFaceLab dependencies..."

# Determine the venv path (Vast.ai base image uses /venv/main/)
VENV_PATH="/venv/main"
if [ -n "$VIRTUAL_ENV" ]; then
    VENV_PATH="$VIRTUAL_ENV"
    echo "Using existing venv: ${VENV_PATH}"
elif [ -d "/venv/main" ]; then
    VENV_PATH="/venv/main"
    echo "Using Vast.ai base image venv: ${VENV_PATH}"
    # Activate it
    if [ -f "/venv/main/bin/activate" ]; then
        source /venv/main/bin/activate
    fi
else
    echo "Warning: Vast.ai venv not found at /venv/main, checking workspace..."
    # Check for workspace environment sync venv
    if [ -d "${WORKSPACE_ROOT}/.environment_sync" ]; then
        ENV_SYNC_DIR=$(find ${WORKSPACE_ROOT}/.environment_sync -type d -name "venv" -o -type d -name "main" 2>/dev/null | head -1)
        if [ -n "$ENV_SYNC_DIR" ] && [ -f "${ENV_SYNC_DIR}/bin/activate" ]; then
            VENV_PATH="$ENV_SYNC_DIR"
            source "${ENV_SYNC_DIR}/bin/activate"
            echo "Using workspace environment sync venv: ${VENV_PATH}"
        fi
    fi
fi

# Verify we have a venv and activate it
if [ -n "$VIRTUAL_ENV" ]; then
    VENV_PATH="$VIRTUAL_ENV"
    echo "Virtual environment already active: ${VENV_PATH}"
elif [ -f "${VENV_PATH}/bin/activate" ]; then
    source "${VENV_PATH}/bin/activate"
    echo "Activated venv: ${VENV_PATH}"
else
    echo "Error: Could not find or activate venv"
    exit 1
fi

# Verify Python is available
if ! command -v python &> /dev/null; then
    echo "Error: python command not found"
    exit 1
fi

# Check Python version and location
PYTHON_VERSION=$(python --version 2>&1)
PYTHON_PATH=$(which python)
echo "Python version: ${PYTHON_VERSION}"
echo "Python path: ${PYTHON_PATH}"
echo "Virtual environment: ${VIRTUAL_ENV}"

# Verify we're using venv Python
if [[ "$PYTHON_PATH" != *"${VENV_PATH}"* ]] && [[ "$PYTHON_PATH" != *"venv"* ]]; then
    echo "Warning: Python is not from venv, updating PATH..."
    export PATH="${VENV_PATH}/bin:${PATH}"
    PYTHON_PATH=$(which python)
    echo "Updated Python path: ${PYTHON_PATH}"
fi

echo "Virtual environment ready for DeepFaceLab installation"

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

# Clone DFL-MVE repository (temporary location)
echo "Cloning DFL-MVE repository..."
if [ ! -d "${DFL_MVE_PATH}" ]; then
    git clone https://github.com/MannyJMusic/DFL-MVE.git ${DFL_MVE_PATH}
else
    echo "DFL-MVE already exists, skipping clone"
fi

# Copy DeepFaceLab to /opt/DeepFaceLab (same level, not nested)
echo "Setting up DeepFaceLab at /opt/DeepFaceLab..."
if [ -d "${DFL_MVE_PATH}/DeepFaceLab" ]; then
    if [ -d "${DEEPFACELAB_PATH}" ]; then
        echo "DeepFaceLab already exists at ${DEEPFACELAB_PATH}, skipping copy"
    else
        cp -r ${DFL_MVE_PATH}/DeepFaceLab ${DEEPFACELAB_PATH}
        echo "DeepFaceLab copied to ${DEEPFACELAB_PATH}"
    fi
else
    echo "Error: DeepFaceLab not found in ${DFL_MVE_PATH}/DeepFaceLab"
    exit 1
fi

# Install DeepFaceLab CUDA requirements from requirement-cuda.txt
echo "Installing DeepFaceLab CUDA requirements from requirement-cuda.txt..."
REQUIREMENTS_FILE="${DEEPFACELAB_PATH}/requirement-cuda.txt"
if [ -f "${REQUIREMENTS_FILE}" ]; then
    echo "Found requirement-cuda.txt at ${REQUIREMENTS_FILE}"
    python -m pip install --no-cache-dir -r "${REQUIREMENTS_FILE}"
    echo "DeepFaceLab CUDA requirements installed successfully"
else
    echo "Warning: requirement-cuda.txt not found at ${REQUIREMENTS_FILE}"
    echo "Trying alternative location: ${DEEPFACELAB_PATH}/DeepFaceLab/requirement-cuda.txt"
    if [ -f "${DEEPFACELAB_PATH}/DeepFaceLab/requirement-cuda.txt" ]; then
        python -m pip install --no-cache-dir -r "${DEEPFACELAB_PATH}/DeepFaceLab/requirement-cuda.txt"
        echo "DeepFaceLab CUDA requirements installed successfully"
    else
        echo "Warning: requirement-cuda.txt not found in alternative location either"
        echo "Continuing without CUDA-specific requirements..."
    fi
fi

# Set up workspace - symlink to mounted volume
echo "Setting up workspace at /opt/workspace..."
# Check if workspace root is a mount point (from Vast.ai volume)
if mountpoint -q ${WORKSPACE_ROOT} 2>/dev/null || (df ${WORKSPACE_ROOT} 2>/dev/null | grep -q "^/dev" 2>/dev/null); then
    echo "Detected ${WORKSPACE_ROOT} as volume mount point, symlinking /opt/workspace to it"
    # Remove existing workspace if it exists
    rm -rf ${WORKSPACE_PATH} 2>/dev/null || true
    # Create symlink from /opt/workspace to workspace root (mounted volume)
    ln -sf ${WORKSPACE_ROOT} ${WORKSPACE_PATH}
    echo "Workspace symlinked: ${WORKSPACE_PATH} -> ${WORKSPACE_ROOT}"
else
    echo "No volume mount detected, creating workspace at ${WORKSPACE_PATH}"
    mkdir -p ${WORKSPACE_PATH}
fi

# Create workspace subdirectories
mkdir -p ${WORKSPACE_PATH}/data_src
mkdir -p ${WORKSPACE_PATH}/data_src/aligned
mkdir -p ${WORKSPACE_PATH}/data_src/aligned_debug
mkdir -p ${WORKSPACE_PATH}/data_dst
mkdir -p ${WORKSPACE_PATH}/data_dst/aligned
mkdir -p ${WORKSPACE_PATH}/data_dst/aligned_debug
mkdir -p ${WORKSPACE_PATH}/model

# Set up scripts - copy to /opt/scripts (same level, not nested in DeepFaceLab)
echo "Setting up scripts at /opt/scripts..."
if [ -d "${WORKSPACE_ROOT}/scripts" ]; then
    if [ -d "${SCRIPTS_PATH}" ]; then
        echo "Scripts already exist at ${SCRIPTS_PATH}, skipping copy"
    else
        cp -r ${WORKSPACE_ROOT}/scripts ${SCRIPTS_PATH}
        chmod +x ${SCRIPTS_PATH}/*.sh 2>/dev/null || true
        echo "Scripts copied from ${WORKSPACE_ROOT}/scripts to ${SCRIPTS_PATH}"
    fi
elif [ -d "${DFL_MVE_PATH}/scripts" ]; then
    if [ -d "${SCRIPTS_PATH}" ]; then
        echo "Scripts already exist at ${SCRIPTS_PATH}, skipping copy"
    else
        cp -r ${DFL_MVE_PATH}/scripts ${SCRIPTS_PATH}
        chmod +x ${SCRIPTS_PATH}/*.sh 2>/dev/null || true
        echo "Scripts copied from ${DFL_MVE_PATH}/scripts to ${SCRIPTS_PATH}"
    fi
else
    echo "Warning: No scripts found, creating empty directory at ${SCRIPTS_PATH}"
    mkdir -p ${SCRIPTS_PATH}
fi

# Set up Machine Video Editor
echo "Setting up Machine Video Editor..."
mkdir -p ${MVE_PATH}
# Note: Machine Video Editor should be available in workspace/machine-video-editor-0.8.2/
# or downloaded from a URL. Adjust this section based on your MVE source.
if [ -d "${WORKSPACE_ROOT}/machine-video-editor-0.8.2" ]; then
    cp -r ${WORKSPACE_ROOT}/machine-video-editor-0.8.2/* ${MVE_PATH}/
    chmod +x ${MVE_PATH}/machine-video-editor 2>/dev/null || true
    ln -sf ${MVE_PATH}/machine-video-editor /usr/local/bin/machine-video-editor 2>/dev/null || true
    echo "Machine Video Editor copied from ${WORKSPACE_ROOT}/machine-video-editor-0.8.2/"
else
    echo "Warning: Machine Video Editor not found in ${WORKSPACE_ROOT}/machine-video-editor-0.8.2/"
    echo "You may need to upload it or configure download URL"
fi

# VNC setup skipped - not needed for this configuration

# Set up PORTAL_CONFIG for Vast.ai Instance Portal (if not already set)
# Instance Portal runs on port 11111 internally, accessible via port 1111 externally
echo "Configuring Vast.ai Portal..."

# Determine external ports assigned by Vast.ai (fallbacks to standard)
EXTERNAL_PORTAL_PORT="${VAST_TCP_PORT_11111:-1111}"

# Build PORTAL_CONFIG using detected external ports unless an explicit value was provided
# Only set if PORTAL_CONFIG is not already provided via environment variable
if [ -z "$PORTAL_CONFIG" ]; then
    DEFAULT_PORTAL_CONFIG="localhost:${EXTERNAL_PORTAL_PORT}:11111:/:Instance Portal"
    PORTAL_CONFIG_VALUE="$DEFAULT_PORTAL_CONFIG"
    export PORTAL_CONFIG="$PORTAL_CONFIG_VALUE"
else
    PORTAL_CONFIG_VALUE="$PORTAL_CONFIG"
    echo "Using existing PORTAL_CONFIG: $PORTAL_CONFIG_VALUE"
fi

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

# Supervisor scripts not needed - services are managed by the image startup script

# Create environment setup script (for venv)
cat > /opt/setup-dfl-env.sh << 'EOFSCRIPT'
#!/bin/bash
# Activate DeepFaceLab venv environment
# Vast.ai base image automatically activates /venv/main/ on SSH

# Try to activate venv if not already active
if [ -z "$VIRTUAL_ENV" ]; then
    if [ -f "/venv/main/bin/activate" ]; then
        source /venv/main/bin/activate
    elif [ -d "${WORKSPACE_ROOT}/.environment_sync" ]; then
        ENV_SYNC_DIR=$(find ${WORKSPACE_ROOT}/.environment_sync -type d -name "venv" -o -type d -name "main" 2>/dev/null | head -1)
        if [ -n "$ENV_SYNC_DIR" ] && [ -f "${ENV_SYNC_DIR}/bin/activate" ]; then
            source "${ENV_SYNC_DIR}/bin/activate"
        fi
    fi
fi

# Set DeepFaceLab environment variables
export DFL_PYTHON="python"
export DFL_WORKSPACE="/opt/workspace/"
export DFL_ROOT="/opt/DeepFaceLab/"
export DFL_SRC="/opt/DeepFaceLab"
cd /opt/DeepFaceLab

echo "DeepFaceLab environment ready"
echo "Python: $(which python)"
echo "Python version: $(python --version)"
echo "Virtual environment: ${VIRTUAL_ENV:-/venv/main}"
EOFSCRIPT
chmod +x /opt/setup-dfl-env.sh

# Note: DeepFaceLab, scripts, and workspace are now all at /opt/ level
# - /opt/DeepFaceLab (actual copy)
# - /opt/scripts (copy from workspace or repo)
# - /opt/workspace (symlink to mounted volume at ${WORKSPACE_ROOT})

echo "=== Provisioning Complete ==="
echo "DeepFaceLab installed at: ${DEEPFACELAB_PATH}"
echo "Scripts available at: ${SCRIPTS_PATH}"
echo "Workspace available at: ${WORKSPACE_PATH} (symlinked to ${WORKSPACE_ROOT})"
echo "Virtual environment: ${VIRTUAL_ENV:-/venv/main}"
echo "To setup environment: source /opt/setup-dfl-env.sh"
echo ""
echo "Structure:"
echo "  /opt/DeepFaceLab/ - DeepFaceLab installation"
echo "  /opt/scripts/ - Runtime scripts"
echo "  /opt/workspace/ - Workspace (symlinked to mounted volume)"
echo "  ${VIRTUAL_ENV:-/venv/main}/ - Python virtual environment with DeepFaceLab dependencies"

# Ensure SSH is still running before exit
if ! pgrep -x sshd > /dev/null 2>&1; then
    echo "Ensuring SSH is running before exit..."
    if command -v service &> /dev/null; then
        service ssh start || service sshd start || true
        if ! pgrep -x sshd > /dev/null 2>&1; then
            if [ -f /usr/sbin/sshd ]; then
                /usr/sbin/sshd &
            elif [ -f /usr/bin/sshd ]; then
                /usr/bin/sshd &
            fi
        fi
    else
        if [ -f /usr/sbin/sshd ]; then
            /usr/sbin/sshd &
        elif [ -f /usr/bin/sshd ]; then
            /usr/bin/sshd &
        fi
    fi
    sleep 2
fi

# Exit cleanly - script is done, services run in background
exit 0

