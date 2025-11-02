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
    tigervnc-standalone-server \
    tigervnc-xorg-extension \
    dbus-x11 \
    x11-xserver-utils \
    xfce4-notifyd \
    kde-config-screenlocker \
    network-manager \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

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

# Create conda environment with Python 3.10 and CUDA support
echo "Creating conda environment: ${CONDA_ENV_NAME}..."
mkdir -p /opt/conda-envs
conda create -y -p ${CONDA_ENV_PATH} python=3.10 cudatoolkit=11.8 cudnn=8.6 -c nvidia -c conda-forge || \
    conda env create -p ${CONDA_ENV_PATH} -f /workspace/environment.yml 2>/dev/null || true

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

# Create VNC password (default: deepfacelab)
echo "deepfacelab" | vncpasswd -f > ${VNC_HOME}/.vnc/passwd
chmod 600 ${VNC_HOME}/.vnc/passwd

# Create xstartup script for KDE Plasma
cat > ${VNC_HOME}/.vnc/xstartup << 'EOF'
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

chmod +x ${VNC_HOME}/.vnc/xstartup

# Start VNC server in background
echo "Starting VNC server..."
vncserver :1 -geometry 1920x1080 -depth 24 > /tmp/vnc-startup.log 2>&1 || true

# Set up PORTAL_CONFIG for Vast.ai Instance Portal
# VNC typically runs on port 5901, mapping to external port
echo "Configuring Vast.ai Portal..."
rm -f /etc/portal.yaml
export PORTAL_CONFIG="localhost:5901:5901:/:VNC Desktop|localhost:1111:11111:/:Instance Portal"

# Configure Instance Portal open button
export OPEN_BUTTON_PORT=1111
export OPEN_BUTTON_TOKEN=1

# Create supervisor script for VNC if needed
if [ -d "/opt/supervisor-scripts" ]; then
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
fi

# Reload supervisor if it exists
if command -v supervisorctl &> /dev/null; then
    supervisorctl reload || true
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

