#!/bin/bash
# Install KDE Plasma Desktop and TigerVNC server
set -e

# Install desktop environment and VNC server
apt-get update && \
    apt-get install -y --no-install-recommends \
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

echo "Desktop environment and VNC server installed successfully"

