#!/bin/bash
# Install Python dependencies for DeepFaceLab with TensorFlow 2.13
set -e

# Upgrade pip to latest version
python3 -m pip install --no-cache-dir --upgrade pip setuptools wheel

# Install TensorFlow 2.13 with GPU support
python3 -m pip install --no-cache-dir tensorflow==2.13.0

# Install updated DeepFaceLab dependencies (compatible with Python 3.10 and TF 2.13)
python3 -m pip install --no-cache-dir \
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

echo "Python dependencies installed successfully"

