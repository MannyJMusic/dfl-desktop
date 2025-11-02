#!/bin/bash
# Install system dependencies for DeepFaceLab
set -e

# Update package lists and install essential packages
apt-get update && \
    apt-get install -y --no-install-recommends \
    python3 \
    python3-venv \
    python3-pip \
    python3-dev \
    build-essential \
    git \
    wget \
    unzip \
    libgl1-mesa-glx \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
    libgomp1 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Upgrade pip
python3 -m pip install --upgrade pip setuptools wheel

echo "System dependencies installed successfully"

