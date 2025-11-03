#!/usr/bin/env bash
set -eo pipefail

# Minimal provisioning script to fetch DFL Desktop files into persistent storage.
# Safe to run multiple times. Does NOT modify portal/supervisor; keeps Instance Portal stable.

WORKDIR="/workspace"
APP_DIR="${WORKDIR}/DFL-Desktop"
TMP_DIR="${WORKDIR}/DFL-Desktop.tmp"

echo "[provision] starting fetch-dfl-desktop.sh"

# Ensure persistent workspace exists
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Clean any previous temp directory
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"

# Option A: clone repo (default)
if command -v git >/dev/null 2>&1; then
  echo "[provision] cloning DFL-MVE repo into ${TMP_DIR}/DFL-MVE"
  git clone --depth 1 https://github.com/MannyJMusic/DFL-MVE.git "${TMP_DIR}/DFL-MVE"
else
  echo "[provision] git not found; installing minimal git"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y --no-install-recommends git && apt-get clean && rm -rf /var/lib/apt/lists/*
  git clone --depth 1 https://github.com/MannyJMusic/DFL-MVE.git "${TMP_DIR}/DFL-MVE"
fi

# Swap atomically
rm -rf "${APP_DIR}"
mv "${TMP_DIR}" "${APP_DIR}"

# Convenience symlink
ln -sf "${APP_DIR}" /opt/DFL-Desktop 2>/dev/null || true

echo "[provision] fetched DFL Desktop into ${APP_DIR}"
echo "[provision] done"


