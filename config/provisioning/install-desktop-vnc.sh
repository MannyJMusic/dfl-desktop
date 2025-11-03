#!/bin/bash
# Install XFCE Desktop and TigerVNC server
set -e

# Install desktop environment and VNC server
apt-get update && \
    apt-get install -y --no-install-recommends \
    xfce4 \
    xfce4-goodies \
    tigervnc-standalone-server \
    tigervnc-xorg-extension \
    dbus-x11 \
    x11-xserver-utils \
    xfce4-notifyd \
    network-manager \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

echo "Desktop environment and VNC server installed successfully"

