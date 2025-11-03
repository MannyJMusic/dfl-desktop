# DeepFaceLab Dockerfile for Vast.ai
# Uses Vast.ai base image with provisioning script for runtime setup
# Copyright (C) 2024
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

FROM vastai/base-image:cuda-12.6.3-cudnn-devel-ubuntu22.04-py313

LABEL maintainer="DeepFaceLab Docker Maintainers"
LABEL description="DeepFaceLab GPU Container for Vast.ai - uses provisioning script for setup"

# Environment variables - all paths point to /opt/
ENV DFL_MVE_PATH=/opt/DFL-MVE
ENV DEEPFACELAB_PATH=/opt/DFL-MVE/DeepFaceLab
ENV MVE_PATH=/opt/MachineVideoEditor

# VNC password - can be overridden at runtime via -e VNC_PASSWORD=yourpassword
ENV VNC_PASSWORD=deepfacelab

# Install tigervnc-tools at build time so vncpasswd is available immediately
# This prevents errors when Vast.ai base image tries to start VNC before provisioning script runs
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -y --no-install-recommends tigervnc-tools && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Copy provisioning scripts into the image so they can be invoked via --onstart-cmd
COPY config/provisioning/ /opt/provisioning/
RUN chmod -R +x /opt/provisioning/*.sh || true

# Vast.ai base image handles the rest via provisioning script
# The provisioning script (PROVISIONING_SCRIPT env var) will:
# - Install and configure SSH server (openssh-server)
# - Install conda and create deepfacelab environment
# - Install system dependencies (git, VNC, desktop environment)
# - Clone DFL-MVE repository
# - Install Python dependencies
# - Set up Machine Video Editor
# - Configure VNC server
# - Set up workspace directories
