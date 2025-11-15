#!/bin/bash
# Vast.ai Provisioning Script for DeepFaceLab with Machine Video Editor
# This script runs on first boot to set up the environment
set -eo pipefail

# Define paths (everything goes to /opt/)
export DFL_MVE_PATH=/opt/deepfacelab
export DEEPFACELAB_PATH=/opt/deepfacelab/DeepFaceLab
export MVE_PATH=/opt/machinevideoeditor
export CONDA_ENV_NAME=deepfacelab

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
    # Find conda base directory
    CONDA_BASE=$(conda info --base 2>/dev/null || echo "/opt/miniconda3")
    if [ -f "${CONDA_BASE}/etc/profile.d/conda.sh" ]; then
        source "${CONDA_BASE}/etc/profile.d/conda.sh"
    elif [ -f "/opt/miniconda3/etc/profile.d/conda.sh" ]; then
        source /opt/miniconda3/etc/profile.d/conda.sh
    else
        echo "Error: Cannot find conda.sh initialization script"
        exit 1
    fi
fi

# Verify conda is working
if ! command -v conda &> /dev/null; then
    echo "Error: conda command not available after initialization"
    exit 1
fi

# Create conda environment with Python 3.10
# Note: Base image already has CUDA 12.6.3 and cuDNN installed system-wide,
# so we don't need to install them via conda. TensorFlow will use system CUDA libraries.
echo "Creating conda environment: ${CONDA_ENV_NAME}..."

# Check if named environment already exists
if conda env list | grep -q "^${CONDA_ENV_NAME}\s"; then
    echo "Conda environment '${CONDA_ENV_NAME}' already exists, skipping creation"
else
    echo "Environment does not exist, creating new conda environment..."
    
    # Try to create named environment with cudatoolkit for TensorFlow compatibility
    # If that fails, create basic Python environment (TensorFlow will use system CUDA)
    if ! conda create -y -n ${CONDA_ENV_NAME} python=3.10 cudatoolkit=11.8 -c nvidia -c conda-forge 2>&1; then
        echo "Warning: cudatoolkit=11.8 not available, creating environment without it..."
        echo "TensorFlow will use system CUDA libraries from the base image."
        if ! conda create -y -n ${CONDA_ENV_NAME} python=3.10 -c conda-forge 2>&1; then
            echo "Error: Failed to create conda environment. Trying with environment.yml if available..."
            if [ -f "/workspace/environment.yml" ]; then
                conda env create -n ${CONDA_ENV_NAME} -f /workspace/environment.yml 2>&1 || {
                    echo "Error: All methods to create conda environment failed"
                    exit 1
                }
            else
                echo "Error: Cannot create conda environment and no environment.yml found"
                exit 1
            fi
        fi
    fi
    
    # Verify environment was created successfully
    if ! conda env list | grep -q "^${CONDA_ENV_NAME}\s"; then
        echo "Error: Conda environment '${CONDA_ENV_NAME}' was not created successfully"
        exit 1
    fi
    echo "Conda environment '${CONDA_ENV_NAME}' created successfully"
fi

# Activate conda environment (deactivate 'main' venv first if active)
echo "Activating conda environment..."
# Deactivate any existing venv/conda environment (especially 'main' from base image)
if [ -n "$VIRTUAL_ENV" ]; then
    echo "Deactivating existing venv: $VIRTUAL_ENV"
    deactivate 2>/dev/null || true
fi
if [ -n "$CONDA_DEFAULT_ENV" ] && [ "$CONDA_DEFAULT_ENV" != "${CONDA_ENV_NAME}" ]; then
    echo "Deactivating existing conda env: $CONDA_DEFAULT_ENV"
    conda deactivate 2>/dev/null || true
fi
conda activate ${CONDA_ENV_NAME} || {
    echo "Error: Failed to activate conda environment '${CONDA_ENV_NAME}'"
    exit 1
}

# Verify activation worked
if [ "$CONDA_DEFAULT_ENV" != "${CONDA_ENV_NAME}" ]; then
    echo "Warning: Environment activation may have failed (current env: ${CONDA_DEFAULT_ENV:-none}), but continuing..."
fi

# Upgrade pip
python -m pip install --no-cache-dir --upgrade pip setuptools wheel

# Install TensorFlow 2.13 with GPU support
echo "Installing TensorFlow 2.13..."
python -m pip install --no-cache-dir tensorflow==2.13.0

# ------------------------------
# Version detection helpers
# ------------------------------
ver_ge() {
    local v1="$1" v2="$2"
    [[ -z "$v1" || -z "$v2" ]] && return 1
    [[ "$v1" == "$v2" ]] && return 0
    local lower
    lower=$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)
    [[ "$lower" == "$v2" ]]
}

detect_python_version() {
    python - <<'PY' 2>/dev/null || true
import sys
print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
}

detect_cuda_version() {
    local cuda=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        # Try to query CUDA version, filtering out error messages
        local nvidia_output
        nvidia_output=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)
        if [[ -n "$nvidia_output" ]] && ! echo "$nvidia_output" | grep -qi "error\|invalid\|not.*valid"; then
            # Try driver_version first, then try to get CUDA capability
            cuda=$(nvidia-smi --query-gpu=cuda_version --format=csv,noheader 2>/dev/null 2>&1 | head -n1 | grep -E '^[0-9]+\.[0-9]+' | head -n1 | tr -d ' ')
            # If that fails, try compute_cap (CUDA capability) and map to CUDA version
            if [[ -z "$cuda" ]] || echo "$cuda" | grep -qi "error\|invalid\|not.*valid"; then
                local compute_cap
                compute_cap=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ')
                # Map compute capability to approximate CUDA version (rough approximation)
                if [[ -n "$compute_cap" ]] && [[ "$compute_cap" =~ ^[0-9]+\.[0-9]+$ ]]; then
                    # Assume modern GPU supports CUDA 11.8+
                    if ver_ge "$compute_cap" "7.0"; then
                        cuda="11.8"
                    elif ver_ge "$compute_cap" "6.0"; then
                        cuda="11.0"
                    else
                        cuda="10.0"
                    fi
                fi
            fi
        fi
    fi
    # Fallback to nvcc if still no CUDA version
    if [[ -z "$cuda" ]] || echo "$cuda" | grep -qi "error\|invalid\|not.*valid"; then
        if command -v nvcc >/dev/null 2>&1; then
            cuda=$(nvcc --version 2>/dev/null | awk '/release/ {gsub(/,/, "", $5); split($5, ver, "."); print ver[1]"."ver[2]; exit}')
        fi
    fi
    # Filter out any error messages - return empty string if we get an error
    if echo "$cuda" | grep -qi "error\|invalid\|not.*valid\|field"; then
        echo ""
    else
        echo "$cuda"
    fi
}

detect_architecture() {
    uname -m 2>/dev/null || echo ""
}

select_requirements_file() {
    local py_version="$1"
    local cuda_version="$2"
    local arch="$3"
    local candidate=""
    local modern_req="${DEEPFACELAB_PATH}/requirements-cuda-python310.txt"
    local legacy_req="${DEEPFACELAB_PATH}/requirements-cuda.txt"
    local generic_req="${DEEPFACELAB_PATH}/requirements.txt"

    # Priority 1: Python 3.10-3.13 tailored requirement sets (check architecture-specific first)
    if [[ "$py_version" =~ ^3\.(1[0-3])$ ]]; then
        local minor="${BASH_REMATCH[1]}"
        local base_req="${DEEPFACELAB_PATH}/requirements_3.${minor}"
        local arm_req="${base_req}_arm64.txt"
        local x86_req="${base_req}.txt"

        # For ARM64, prefer ARM-specific file
        if [[ "$arch" =~ (aarch64|arm64) ]] && [[ -f "$arm_req" ]] && [[ -s "$arm_req" ]]; then
            candidate="$arm_req"
        # For x86_64 or unknown, prefer x86 file (but skip if empty)
        elif [[ -f "$x86_req" ]] && [[ -s "$x86_req" ]]; then
            candidate="$x86_req"
        # Fallback: use ARM file even on x86 if x86 doesn't exist or is empty
        elif [[ -f "$arm_req" ]] && [[ -s "$arm_req" ]]; then
            candidate="$arm_req"
        fi
    fi

    # Priority 2: Python 3.10+ with CUDA 12.0+ specific requirements
    if [[ -z "$candidate" && -n "$py_version" && -n "$cuda_version" ]] && \
       ver_ge "$py_version" "3.10" && ver_ge "$cuda_version" "12.0" && \
       [[ -f "$modern_req" ]] && [[ -s "$modern_req" ]]; then
        candidate="$modern_req"
    fi

    # Priority 3: Python 3.10+ with CUDA (any version) - use modern CUDA requirements
    if [[ -z "$candidate" && -n "$py_version" ]] && \
       ver_ge "$py_version" "3.10" && \
       [[ -f "$modern_req" ]] && [[ -s "$modern_req" ]]; then
        candidate="$modern_req"
    fi

    # Priority 4: Legacy CUDA requirements (for older CUDA versions)
    if [[ -z "$candidate" ]] && \
       [[ -f "$legacy_req" ]] && [[ -s "$legacy_req" ]]; then
        candidate="$legacy_req"
    fi

    # Priority 5: Generic requirements.txt (fallback)
    if [[ -z "$candidate" ]] && \
       [[ -f "$generic_req" ]] && [[ -s "$generic_req" ]]; then
        candidate="$generic_req"
    fi

    # Final fallback: use modern_req as default (even if it might not exist - will be handled later)
    if [[ -z "$candidate" ]]; then
        candidate="$modern_req"
    fi

    echo "$candidate"
}

# Clone DFL-MVE repository first (before requirements file selection)
echo "Cloning DFL-MVE repository..."
if [ ! -d "${DFL_MVE_PATH}" ]; then
    git clone https://github.com/MannyJMusic/dfl-desktop.git ${DFL_MVE_PATH}
else
    echo "DFL-MVE already exists, skipping clone"
fi

# Clone DeepFaceLab if it doesn't exist (it may be part of dfl-desktop or separate)
if [ ! -d "${DEEPFACELAB_PATH}" ]; then
    echo "DeepFaceLab not found, cloning..."
    # Check if DeepFaceLab is a subdirectory in DFL-MVE first
    if [ -d "${DFL_MVE_PATH}/DeepFaceLab" ]; then
        echo "DeepFaceLab found in DFL-MVE, creating symlink or copying..."
        # Create parent directory if needed
        mkdir -p "$(dirname "${DEEPFACELAB_PATH}")"
        # Try symlink first, fall back to copy if symlink fails
        ln -sf "${DFL_MVE_PATH}/DeepFaceLab" "${DEEPFACELAB_PATH}" 2>/dev/null || \
        cp -r "${DFL_MVE_PATH}/DeepFaceLab" "${DEEPFACELAB_PATH}" 2>/dev/null || true
    else
        # Clone DeepFaceLab separately if not found
        mkdir -p "$(dirname "${DEEPFACELAB_PATH}")"
        git clone https://github.com/iperov/DeepFaceLab.git "${DEEPFACELAB_PATH}" 2>/dev/null || {
            echo "Warning: Could not clone DeepFaceLab from official repo, will use fallback requirements"
        }
    fi
fi

# Detect environment characteristics
PY_VERSION_DETECTED=$(detect_python_version)
CUDA_VERSION_DETECTED=$(detect_cuda_version)
ARCH_DETECTED=$(detect_architecture)
REQUIREMENTS_FILE=$(select_requirements_file "$PY_VERSION_DETECTED" "$CUDA_VERSION_DETECTED" "$ARCH_DETECTED")

echo "Detected Python version: ${PY_VERSION_DETECTED:-unknown}"
echo "Detected CUDA version: ${CUDA_VERSION_DETECTED:-unknown}"
echo "Detected architecture: ${ARCH_DETECTED:-unknown}"
echo "Using requirements file: ${REQUIREMENTS_FILE}"

DFL_ENV_INFO_FILE="/opt/DFL-MVE/.dfl_env_info"
mkdir -p /opt/DFL-MVE
cat > "${DFL_ENV_INFO_FILE}" <<EOF
You are now in the DeepFaceLab environment (conda env: deepfacelab)
Python: ${PY_VERSION_DETECTED:-unknown}
CUDA: ${CUDA_VERSION_DETECTED:-unknown}
Architecture: ${ARCH_DETECTED:-unknown}
Requirements: $(basename "${REQUIREMENTS_FILE}")
EOF

# Check if requirements file exists, if not try fallback options
if [[ ! -f "$REQUIREMENTS_FILE" ]]; then
    echo "Warning: Requirements file '${REQUIREMENTS_FILE}' not found"
    # Try to find any requirements file in DeepFaceLab directory
    if [ -d "${DEEPFACELAB_PATH}" ]; then
        # Try common fallback requirements files
        fallback_req=""
        if [ -f "${DEEPFACELAB_PATH}/requirements-cuda.txt" ]; then
            fallback_req="${DEEPFACELAB_PATH}/requirements-cuda.txt"
        elif [ -f "${DEEPFACELAB_PATH}/requirements.txt" ]; then
            fallback_req="${DEEPFACELAB_PATH}/requirements.txt"
        elif [ -f "${DEEPFACELAB_PATH}/requirements_3.10.txt" ]; then
            fallback_req="${DEEPFACELAB_PATH}/requirements_3.10.txt"
        fi
        
        if [ -n "$fallback_req" ] && [ -f "$fallback_req" ]; then
            echo "Using fallback requirements file: ${fallback_req}"
            REQUIREMENTS_FILE="$fallback_req"
        else
            echo "Error: No suitable requirements file found. DeepFaceLab may not be properly cloned."
            echo "Attempting to continue without DeepFaceLab dependencies (user can install manually)..."
            REQUIREMENTS_FILE=""
        fi
    else
        echo "Error: DeepFaceLab directory '${DEEPFACELAB_PATH}' does not exist"
        echo "Note: Provisioning encountered issues but instance startup will continue"
        REQUIREMENTS_FILE=""
    fi
fi

# Install DeepFaceLab Python dependencies if we have a valid requirements file
if [[ -n "$REQUIREMENTS_FILE" ]] && [[ -f "$REQUIREMENTS_FILE" ]]; then
    echo "Installing DeepFaceLab dependencies from ${REQUIREMENTS_FILE}..."
    python -m pip install --no-cache-dir -r "${REQUIREMENTS_FILE}"
    
    # Fix flatbuffers version conflict: TensorFlow 2.13 requires >=23.1.21, but tf2onnx installs 2.0.7
    # Install compatible version after tf2onnx to satisfy TensorFlow's requirement
    echo "Fixing flatbuffers version conflict..."
    python -m pip install --no-cache-dir --upgrade "flatbuffers>=23.1.21" || {
        echo "Warning: Could not upgrade flatbuffers, but continuing..."
    }
else
    echo "Warning: Skipping DeepFaceLab dependency installation (no valid requirements file)"
fi

# Create workspace directories
echo "Creating workspace directories..."
mkdir -p ${DFL_MVE_PATH}/workspace
mkdir -p ${DFL_MVE_PATH}/workspace/data_src
mkdir -p ${DFL_MVE_PATH}/workspace/data_src/aligned
mkdir -p ${DFL_MVE_PATH}/workspace/data_src/aligned_debug
mkdir -p ${DFL_MVE_PATH}/workspace/data_dst
mkdir -p ${DFL_MVE_PATH}/workspace/data_dst/aligned
mkdir -p ${DFL_MVE_PATH}/workspace/data_dst/aligned_debug
mkdir -p ${DFL_MVE_PATH}/workspace/model

# Copy runtime scripts if they exist in workspace, otherwise create placeholder
echo "Setting up runtime scripts..."
if [ -d "/workspace/scripts" ]; then
    cp -r /workspace/scripts ${DFL_MVE_PATH}/scripts
    chmod +x ${DEEPFACELAB_PATH}/scripts/*.sh
else
    echo "Warning: Runtime scripts not found in /workspace/scripts"
    mkdir -p ${DFL_MVE_PATH}/scripts
fi

# Copy scripts to /opt/scripts for user convenience (where users land on SSH)
echo "Setting up /opt/scripts directory..."
mkdir -p /opt/scripts

# Debug: Check what script sources exist
echo "Checking for script sources..."
[ -d "/opt/scripts-source" ] && echo "  - /opt/scripts-source exists: $(ls -A /opt/scripts-source 2>/dev/null | wc -l) files" || echo "  - /opt/scripts-source does not exist"
[ -d "${DFL_MVE_PATH}/scripts" ] && echo "  - ${DFL_MVE_PATH}/scripts exists: $(ls -A ${DFL_MVE_PATH}/scripts 2>/dev/null | wc -l) files" || echo "  - ${DFL_MVE_PATH}/scripts does not exist"
[ -d "/workspace/scripts" ] && echo "  - /workspace/scripts exists: $(ls -A /workspace/scripts 2>/dev/null | wc -l) files" || echo "  - /workspace/scripts does not exist"

# Try to copy from multiple sources (in priority order)
SCRIPTS_COPIED=0

# Copy from image source first (if scripts were baked into the image)
if [ -d "/opt/scripts-source" ] && [ "$(ls -A /opt/scripts-source 2>/dev/null)" ]; then
    echo "Copying scripts from /opt/scripts-source to /opt/scripts..."
    cp -r /opt/scripts-source/* /opt/scripts/ 2>/dev/null || true
    chmod +x /opt/scripts/*.sh 2>/dev/null || true
    SCRIPTS_COPIED=1
    echo "Successfully copied scripts from image source to /opt/scripts"
fi

# Copy from DFL-MVE repository if it exists (and we haven't copied yet)
    if [ $SCRIPTS_COPIED -eq 0 ] && [ -d "${DFL_MVE_PATH}/scripts" ] && [ "$(ls -A ${DFL_MVE_PATH}/scripts 2>/dev/null)" ]; then
    echo "Copying scripts from DFL-MVE repository to /opt/scripts..."
    cp -r ${DFL_MVE_PATH}/scripts/* /opt/scripts/ 2>/dev/null || true
    chmod +x /opt/scripts/*.sh 2>/dev/null || true
    SCRIPTS_COPIED=1
    echo "Successfully copied scripts from DFL-MVE repository to /opt/scripts"
fi

# Or copy from workspace if available (and we haven't copied yet)
if [ $SCRIPTS_COPIED -eq 0 ] && [ -d "/workspace/scripts" ] && [ "$(ls -A /workspace/scripts 2>/dev/null)" ]; then
    echo "Copying scripts from /workspace/scripts to /opt/scripts..."
    cp -r /workspace/scripts/* /opt/scripts/ 2>/dev/null || true
    chmod +x /opt/scripts/*.sh 2>/dev/null || true
    SCRIPTS_COPIED=1
    echo "Successfully copied scripts from /workspace/scripts to /opt/scripts"
fi

# Final check
if [ $SCRIPTS_COPIED -eq 0 ]; then
    echo "Warning: No scripts found to copy to /opt/scripts"
    echo "  Checked locations: /opt/scripts-source, ${DFL_MVE_PATH}/scripts, /workspace/scripts"
else
    echo "Scripts successfully set up in /opt/scripts ($(ls -1 /opt/scripts/*.sh 2>/dev/null | wc -l) scripts found)"
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
    # Bind to 0.0.0.0 to make it accessible from outside the container
    nohup websockify --web /usr/share/novnc/ --listen 0.0.0.0 6901 localhost:5901 > /tmp/websockify.log 2>&1 &
    echo "Web VNC access available at http://localhost:6901/"
else
    echo "Warning: websockify not found, web VNC access will not be available"
fi

# Set up PORTAL_CONFIG for Vast.ai Instance Portal
# VNC typically runs on port 5901, mapping to external port
# Instance Portal runs on port 11111 internally, accessible via port 1111 externally
#echo "Configuring Vast.ai Portal..."

# Determine external ports assigned by Vast.ai (fallbacks to standard)
#EXTERNAL_VNC_PORT="${VAST_TCP_PORT_5901:-5901}"
#EXTERNAL_PORTAL_PORT="${VAST_TCP_PORT_11111:-1111}"

# Build PORTAL_CONFIG using detected external ports unless an explicit value was provided
# Use port 6901 for web VNC access (websockify) instead of 5901 (raw VNC)
#DEFAULT_PORTAL_CONFIG="localhost:${EXTERNAL_VNC_PORT}:6901:/:VNC Desktop|localhost:${EXTERNAL_PORTAL_PORT}:11111:/:Instance Portal"
#PORTAL_CONFIG_VALUE="${PORTAL_CONFIG:-$DEFAULT_PORTAL_CONFIG}"
#export PORTAL_CONFIG="$PORTAL_CONFIG_VALUE"

# Write PORTAL_CONFIG to multiple locations for Vast.ai to pick it up
# 1. /etc/environment (for system-wide environment variables)
#    Use a safe replace that doesn't break on '|' or '/' in values
#TMP_ENV_FILE=$(mktemp)
#if [ -f /etc/environment ]; then
#    grep -v '^PORTAL_CONFIG=' /etc/environment > "$TMP_ENV_FILE" || true
#else
#    : > "$TMP_ENV_FILE"
#fi
#printf 'PORTAL_CONFIG="%s"\n' "$PORTAL_CONFIG_VALUE" >> "$TMP_ENV_FILE"
#mv "$TMP_ENV_FILE" /etc/environment

# 2. Ensure OPEN_BUTTON_PORT and OPEN_BUTTON_TOKEN are set
#OPEN_BUTTON_PORT="${OPEN_BUTTON_PORT:-$EXTERNAL_PORTAL_PORT}"
#OPEN_BUTTON_TOKEN="${OPEN_BUTTON_TOKEN:-1}"

#TMP_ENV_FILE=$(mktemp)
#if [ -f /etc/environment ]; then
#    grep -v '^OPEN_BUTTON_PORT=' /etc/environment > "$TMP_ENV_FILE" || true
#else
#    : > "$TMP_ENV_FILE"
#fi
#printf 'OPEN_BUTTON_PORT=%s\n' "$OPEN_BUTTON_PORT" >> "$TMP_ENV_FILE"
#mv "$TMP_ENV_FILE" /etc/environment

#TMP_ENV_FILE=$(mktemp)
#if [ -f /etc/environment ]; then
#    grep -v '^OPEN_BUTTON_TOKEN=' /etc/environment > "$TMP_ENV_FILE" || true
#else
#    : > "$TMP_ENV_FILE"
#fi
#printf 'OPEN_BUTTON_TOKEN=%s\n' "$OPEN_BUTTON_TOKEN" >> "$TMP_ENV_FILE"
#mv "$TMP_ENV_FILE" /etc/environment

# 3. Create portal.yaml file (Vast.ai base image may read this)
# Note: Vast.ai primarily uses PORTAL_CONFIG env var, but portal.yaml provides backup
#mkdir -p /etc
#Write PORTAL_CONFIG in the expected string format
#cat > /etc/portal.yaml << EOF
# Vast.ai Instance Portal Configuration
# This file is a backup - PORTAL_CONFIG env var is the primary source
# Format string: Interface:ExternalPort:InternalPort:Path:Name
#${PORTAL_CONFIG_VALUE}
#EOF

# Export for current session
#export OPEN_BUTTON_PORT
#export OPEN_BUTTON_TOKEN

# Debug: Print portal configuration for verification
#echo "Portal configuration:"
#echo "  PORTAL_CONFIG: ${PORTAL_CONFIG_VALUE}"
#echo "  OPEN_BUTTON_PORT: ${OPEN_BUTTON_PORT}"
#echo "  OPEN_BUTTON_TOKEN: ${OPEN_BUTTON_TOKEN}"

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
            # Bind to 0.0.0.0 to make it accessible from outside the container
            nohup websockify --web /usr/share/novnc/ --listen 0.0.0.0 6901 localhost:5901 > /tmp/websockify.log 2>&1 &
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
# Deactivate any existing venv/conda environment (especially 'main' from base image)
if [ -n "\$VIRTUAL_ENV" ]; then
    deactivate 2>/dev/null || true
fi
if [ -n "\$CONDA_DEFAULT_ENV" ] && [ "\$CONDA_DEFAULT_ENV" != "${CONDA_ENV_NAME}" ]; then
    conda deactivate 2>/dev/null || true
fi
conda activate ${CONDA_ENV_NAME}
export DFL_PYTHON="python"
export DFL_WORKSPACE="${DEEPFACELAB_PATH}/workspace/"
export DFL_ROOT="${DEEPFACELAB_PATH}/"
export DFL_SRC="${DEEPFACELAB_PATH}/DeepFaceLab"
cd /opt/scripts
EOF
chmod +x /opt/setup-dfl-env.sh

# Create symlink for convenience (in /opt, not /root)
#ln -sf ${DEEPFACELAB_PATH}/workspace /opt/workspace 2>/dev/null || true
#ln -sf ${DEEPFACELAB_PATH} /opt/DeepFaceLab 2>/dev/null || true

# Setup .bashrc for automatic conda activation and directory change on SSH login
if ! grep -q "DFL auto-setup" /root/.bashrc 2>/dev/null; then
    cat >> /root/.bashrc <<'BASHRC_EOF'

# DFL auto-setup: Initialize conda and activate deepfacelab environment on SSH login
if [ -f /opt/miniconda3/etc/profile.d/conda.sh ]; then
    source /opt/miniconda3/etc/profile.d/conda.sh
    # Deactivate any existing venv/conda environment (especially 'main' from base image)
    if [ -n "$VIRTUAL_ENV" ]; then
        deactivate 2>/dev/null || true
    fi
    if [ -n "$CONDA_DEFAULT_ENV" ] && [ "$CONDA_DEFAULT_ENV" != "deepfacelab" ]; then
        conda deactivate 2>/dev/null || true
    fi
    # Activate conda environment by name
    conda activate deepfacelab 2>/dev/null || true
fi
# Change to scripts directory on SSH login
if [ -d /opt/DFL-MVE/scripts ]; then
    cd /opt/DFL-MVE/scripts
fi
# Display environment info
if [ -f /opt/DFL-MVE/.dfl_env_info ]; then
    echo
    cat /opt/DFL-MVE/.dfl_env_info
    echo
fi
BASHRC_EOF
    echo "Added auto-setup to .bashrc"
fi

echo "=== Provisioning Complete ==="
echo "DeepFaceLab installed at: ${DFL_MVE_PATH}"
echo "Workspace available at: ${DFL_MVE_PATH}/workspace"
echo "Conda environment: ${CONDA_ENV_NAME}"
echo "To activate: source /opt/setup-dfl-env.sh or conda activate ${CONDA_ENV_NAME}"
echo "VNC server should be running on :1"
