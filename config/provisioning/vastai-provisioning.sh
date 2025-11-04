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


# Install Miniconda
echo "Installing Miniconda..."
wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-Linux-x86_64.sh -b -p /opt/miniconda3
rm Miniconda3-latest-Linux-x86_64.sh

# Initialize conda for bash
/opt/miniconda3/bin/conda init bash

# Source conda.sh to use conda in this script
source /opt/miniconda3/etc/profile.d/conda.sh

# Create conda environment (use path-based for consistency)
echo "Creating conda environment..."
mkdir -p /opt/conda-envs
conda create -y -p /opt/conda-envs/${CONDA_ENV_NAME} python=3.10
conda activate /opt/conda-envs/${CONDA_ENV_NAME}

# Upgrade pip
python -m pip install --no-cache-dir --upgrade pip setuptools wheel

# Check Python version
PYTHON_VERSION=$(python --version 2>&1 | awk '{print $2}' | cut -d. -f1,2)
echo "Python version: ${PYTHON_VERSION}"

# Install TensorFlow with GPU support (version depends on Python version)
echo "Installing TensorFlow with GPU support..."
# TensorFlow 2.13.0 doesn't support Python 3.12+, so use compatible version
if python -m pip install --no-cache-dir tensorflow==2.13.0 2>&1; then
    echo "TensorFlow 2.13.0 installed successfully"
elif python -m pip install --no-cache-dir tensorflow==2.17.0 2>&1; then
    echo "TensorFlow 2.17.0 installed successfully (fallback for Python 3.12+)"
elif python -m pip install --no-cache-dir tensorflow==2.18.0 2>&1; then
    echo "TensorFlow 2.18.0 installed successfully (fallback for Python 3.12+)"
elif python -m pip install --no-cache-dir tensorflow 2>&1; then
    echo "TensorFlow latest version installed successfully"
else
    echo "ERROR: Failed to install TensorFlow"
    exit 1
fi

# Install DeepFaceLab Python dependencies
echo "Installing DeepFaceLab dependencies..."
# Check Python version for compatibility
PYTHON_MAJOR_MINOR=$(python --version 2>&1 | awk '{print $2}' | cut -d. -f1,2)
PYTHON_MINOR=$(python --version 2>&1 | awk '{print $2}' | cut -d. -f2)

# For Python 3.12+, use compatible versions
if [ "$PYTHON_MINOR" -ge 12 ]; then
    echo "Python 3.12+ detected, using compatible package versions..."
    # Don't downgrade numpy if TensorFlow already installed a newer version
    python -m pip install --no-cache-dir \
        tqdm \
        numexpr \
        'opencv-python>=4.8.1' \
        ffmpeg-python==0.1.17 \
        scikit-image==0.21.0 \
        'scipy>=1.11.0' \
        colorama \
        pyqt5 \
        'tf2onnx>=1.15.0' \
        'Flask>=2.3.0' \
        flask-socketio==5.3.5 \
        tensorboardX \
        crc32c \
        jsonschema \
        'Jinja2>=3.1.0' \
        'werkzeug>=2.3.0' \
        'itsdangerous>=2.1.0'
    # Check if numpy is already installed (from TensorFlow)
    if python -c "import numpy" 2>/dev/null; then
        NUMPY_VERSION=$(python -c "import numpy; print(numpy.__version__)" 2>/dev/null)
        echo "NumPy already installed: ${NUMPY_VERSION} (from TensorFlow), skipping..."
    else
        echo "Installing compatible NumPy version..."
        python -m pip install --no-cache-dir 'numpy>=1.26.0'
    fi
    # Check if h5py is already installed (from TensorFlow)
    if python -c "import h5py" 2>/dev/null; then
        H5PY_VERSION=$(python -c "import h5py; print(h5py.__version__)" 2>/dev/null)
        echo "h5py already installed: ${H5PY_VERSION} (from TensorFlow), skipping..."
    else
        echo "Installing compatible h5py version..."
        python -m pip install --no-cache-dir 'h5py>=3.10.0'
    fi
else
    # For Python 3.10/3.11, use original versions
    echo "Python 3.10/3.11 detected, using original package versions..."
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
fi

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



# Supervisor scripts not needed - services are managed by the image startup script
# Note: Environment setup script (/opt/setup-dfl-env.sh) is created by config/onstart/provision.sh

# Setup .bashrc for automatic conda activation and directory change on SSH login
echo "Configuring .bashrc for automatic environment setup..."
if ! grep -q "DFL auto-setup" /root/.bashrc 2>/dev/null; then
    cat >> /root/.bashrc <<'BASHRC_EOF'

# DFL auto-setup: Initialize conda and activate deepfacelab environment on SSH login
if [ -f /opt/miniconda3/etc/profile.d/conda.sh ]; then
    source /opt/miniconda3/etc/profile.d/conda.sh
    # Try to activate conda environment (either path-based or name-based)
    conda activate /opt/conda-envs/deepfacelab 2>/dev/null || conda activate deepfacelab 2>/dev/null || true
fi
# Change to scripts directory on SSH login
if [ -d /opt/scripts ]; then
    cd /opt/scripts
fi
BASHRC_EOF
    echo "Added auto-setup to .bashrc"
fi

# Note: DeepFaceLab, scripts, and workspace are now all at /opt/ level
# - /opt/DeepFaceLab (actual copy)
# - /opt/scripts (copy from workspace or repo)
# - /opt/workspace (symlink to mounted volume at ${WORKSPACE_ROOT})

echo "=== Provisioning Complete ==="
echo "DeepFaceLab installed at: ${DEEPFACELAB_PATH}"
echo "Scripts available at: ${SCRIPTS_PATH}"
echo "Workspace available at: ${WORKSPACE_PATH} (symlinked to ${WORKSPACE_ROOT})"
echo "Conda environment: ${CONDA_ENV_NAME} (activate with: conda activate ${CONDA_ENV_NAME})"
echo "To setup environment: source /opt/setup-dfl-env.sh"
echo ""
echo "Structure:"
echo "  /opt/DeepFaceLab/ - DeepFaceLab installation"
echo "  /opt/scripts/ - Runtime scripts"
echo "  /opt/workspace/ - Workspace (symlinked to mounted volume)"
echo "  Conda environment '${CONDA_ENV_NAME}' - Python environment with DeepFaceLab dependencies"



# Exit cleanly - script is done, services run in background
exit 0

