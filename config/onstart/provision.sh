#!/usr/bin/env bash
set -eo pipefail

# Idempotent on-start provisioning for Vast.ai instances
# - Avoids re-running steps if already provisioned
# - Derives external ports from VAST_TCP_PORT_* env vars for Instance Portal

log() { echo "[onstart] $*"; }

# 0) Early: fix sshd dir; skip if sshd already running
mkdir -p /run/sshd && chown root:root /run/sshd && chmod 755 /run/sshd
if ! pgrep -x sshd >/dev/null 2>&1 && [ -x /usr/sbin/sshd ]; then
  service ssh start 2>/dev/null || service sshd start 2>/dev/null || /usr/sbin/sshd || true
  log "sshd started"
else
  log "sshd already running"
fi

# 1) Quell cron crash loop (supervisor)
if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl stop cron 2>/dev/null || true
  supervisorctl remove cron 2>/dev/null || true
  rm -f /etc/supervisor/conf.d/cron.conf 2>/dev/null || true
  supervisorctl reread 2>/dev/null || true
  supervisorctl update 2>/dev/null || true
  log "disabled supervisor cron"
fi

# 2) Build PORTAL_CONFIG from Vast-assigned external ports
EXTERNAL_VNC_PORT="${VAST_TCP_PORT_5901:-5901}"
EXTERNAL_PORTAL_PORT="${VAST_TCP_PORT_11111:-1111}"
PORTAL_CONFIG_VALUE="${PORTAL_CONFIG:-localhost:${EXTERNAL_VNC_PORT}:5901:/:VNC Desktop|localhost:${EXTERNAL_PORTAL_PORT}:11111:/:Instance Portal}"
export PORTAL_CONFIG="$PORTAL_CONFIG_VALUE"

# Determine OPEN_BUTTON settings (prefer values from Vast if present)
OPEN_BUTTON_PORT="${OPEN_BUTTON_PORT:-$EXTERNAL_PORTAL_PORT}"
OPEN_BUTTON_TOKEN="${OPEN_BUTTON_TOKEN:-${JUPYTER_TOKEN:-1}}"

# Persist to /etc/environment (safe rewrite for all three keys)
TMP_ENV_FILE=$(mktemp)
[ -f /etc/environment ] && cat /etc/environment > "$TMP_ENV_FILE" || : > "$TMP_ENV_FILE"
grep -v '^PORTAL_CONFIG=' "$TMP_ENV_FILE" > "${TMP_ENV_FILE}.1" || true
printf 'PORTAL_CONFIG="%s"\n' "$PORTAL_CONFIG_VALUE" >> "${TMP_ENV_FILE}.1"
grep -v '^OPEN_BUTTON_PORT=' "${TMP_ENV_FILE}.1" > "${TMP_ENV_FILE}.2" || true
printf 'OPEN_BUTTON_PORT=%s\n' "$OPEN_BUTTON_PORT" >> "${TMP_ENV_FILE}.2"
grep -v '^OPEN_BUTTON_TOKEN=' "${TMP_ENV_FILE}.2" > "${TMP_ENV_FILE}.3" || true
printf 'OPEN_BUTTON_TOKEN=%s\n' "$OPEN_BUTTON_TOKEN" >> "${TMP_ENV_FILE}.3"
mv "${TMP_ENV_FILE}.3" /etc/environment

# Export for current process as well
export OPEN_BUTTON_PORT OPEN_BUTTON_TOKEN
log "PORTAL_CONFIG set to: $PORTAL_CONFIG_VALUE (OPEN_BUTTON_PORT=${OPEN_BUTTON_PORT})"

# Optional: write backup portal.yaml that some base images read
cat > /etc/portal.yaml <<EOF
# Format: Interface:ExternalPort:InternalPort:Path:Name
${PORTAL_CONFIG_VALUE}
EOF

# 3) Conda install if missing
if ! command -v conda >/dev/null 2>&1; then
  log "Installing Miniforge..."
  curl -fsSL https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -o /tmp/mf.sh
  bash /tmp/mf.sh -b -p /opt/miniconda3
  /opt/miniconda3/bin/conda init bash
  # Configure conda to use conda-forge (no ToS required)
  source /opt/miniconda3/etc/profile.d/conda.sh
  conda config --set channel_priority strict
  # Remove Anaconda channels that require ToS acceptance
  conda config --remove channels https://repo.anaconda.com/pkgs/main 2>/dev/null || true
  conda config --remove channels https://repo.anaconda.com/pkgs/r 2>/dev/null || true
  conda config --remove channels defaults 2>/dev/null || true
  # Add conda-forge (idempotent)
  conda config --add channels conda-forge 2>/dev/null || true
  conda config --set channel_priority strict
fi
source /opt/miniconda3/etc/profile.d/conda.sh

# 4) Create env only once
if [ ! -d /opt/conda-envs/deepfacelab ]; then
  mkdir -p /opt/conda-envs
  # Ensure conda-forge is configured (in case conda was already installed)
  conda config --set channel_priority strict 2>/dev/null || true
  # Remove Anaconda channels that require ToS acceptance
  conda config --remove channels https://repo.anaconda.com/pkgs/main 2>/dev/null || true
  conda config --remove channels https://repo.anaconda.com/pkgs/r 2>/dev/null || true
  conda config --remove channels defaults 2>/dev/null || true
  conda config --add channels conda-forge 2>/dev/null || true
  conda create -y -p /opt/conda-envs/deepfacelab python=3.10 cudatoolkit=11.8 -c conda-forge --override-channels || \
  conda create -y -p /opt/conda-envs/deepfacelab python=3.10 -c conda-forge --override-channels
  log "conda env created"
fi
conda activate /opt/conda-envs/deepfacelab || true

# 5) Install TF once
python -c "import tensorflow" >/dev/null 2>&1 || { 
  log "Installing TensorFlow 2.13.0"; 
  python -m pip install --no-cache-dir tensorflow==2.13.0; 
}

# 6) Install DFL deps once
MARKER=/opt/.dfl_deps_installed
if [ ! -f "$MARKER" ]; then
  log "Installing DeepFaceLab dependencies"
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
    itsdangerous==2.1.2 && touch "$MARKER"
fi

# 7) VNC setup (idempotent)
mkdir -p /root/.vnc
# Ensure vncpasswd tool exists
if ! command -v vncpasswd >/dev/null 2>&1 && ! command -v tigervncpasswd >/dev/null 2>&1; then
  log "Installing tigervnc-tools for vncpasswd"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y --no-install-recommends tigervnc-tools && apt-get clean && rm -rf /var/lib/apt/lists/* || true
fi
if [ ! -f /root/.vnc/passwd ]; then
  VNCPASSWD_CMD="$(command -v vncpasswd || command -v tigervncpasswd || echo vncpasswd)"
  echo "${VNC_PASSWORD:-deepfacelab}" | $VNCPASSWD_CMD -f > /root/.vnc/passwd
  chmod 600 /root/.vnc/passwd
fi
pgrep -f "vncserver :1" >/dev/null 2>&1 || vncserver :1 -geometry 1920x1080 -depth 24 >/tmp/vnc-startup.log 2>&1 || true

# 8) Setup env helper (once)
[ -f /opt/setup-dfl-env.sh ] || cat >/opt/setup-dfl-env.sh <<'EOS'
#!/usr/bin/env bash
source /opt/miniconda3/etc/profile.d/conda.sh
conda activate /opt/conda-envs/deepfacelab
export DFL_PYTHON=python
export DFL_WORKSPACE=/opt/workspace/
export DFL_ROOT=/opt/DeepFaceLab/
export DFL_SRC=/opt/DeepFaceLab/DeepFaceLab
cd /opt/scripts
EOS
chmod +x /opt/setup-dfl-env.sh

# 9) Setup .bashrc for automatic conda activation and directory change on SSH login
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
  log "Added auto-setup to .bashrc"
fi

log "on-start provisioning complete"


