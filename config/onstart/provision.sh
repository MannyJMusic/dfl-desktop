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

# Persist to /etc/environment (safe rewrite)
TMP_ENV_FILE=$(mktemp)
[ -f /etc/environment ] && grep -v '^PORTAL_CONFIG=' /etc/environment > "$TMP_ENV_FILE" || : > "$TMP_ENV_FILE"
printf 'PORTAL_CONFIG="%s"\n' "$PORTAL_CONFIG_VALUE" >> "$TMP_ENV_FILE"
grep -v '^OPEN_BUTTON_PORT=' "$TMP_ENV_FILE" > "${TMP_ENV_FILE}.2" || true
mv "${TMP_ENV_FILE}.2" "$TMP_ENV_FILE"
printf 'OPEN_BUTTON_PORT=%s\n' "$EXTERNAL_PORTAL_PORT" >> "$TMP_ENV_FILE"
mv "$TMP_ENV_FILE" /etc/environment
log "PORTAL_CONFIG set to: $PORTAL_CONFIG_VALUE"

# 3) Conda install if missing
if ! command -v conda >/dev/null 2>&1; then
  log "Installing Miniforge..."
  curl -fsSL https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh -o /tmp/mf.sh
  bash /tmp/mf.sh -b -p /opt/miniconda3
  /opt/miniconda3/bin/conda init bash
fi
source /opt/miniconda3/etc/profile.d/conda.sh

# 4) Create env only once
if [ ! -d /opt/conda-envs/deepfacelab ]; then
  mkdir -p /opt/conda-envs
  conda create -y -p /opt/conda-envs/deepfacelab python=3.10 cudatoolkit=11.8 -c conda-forge || \
  conda create -y -p /opt/conda-envs/deepfacelab python=3.10 -c conda-forge
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
export DFL_WORKSPACE=/opt/DFL-MVE/DeepFaceLab/workspace/
export DFL_ROOT=/opt/DFL-MVE/DeepFaceLab/
export DFL_SRC=/opt/DFL-MVE/DeepFaceLab/DeepFaceLab
cd /opt/DFL-MVE/DeepFaceLab
EOS
chmod +x /opt/setup-dfl-env.sh

log "on-start provisioning complete"


