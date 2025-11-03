DeepFaceLab Desktop (VNC) – Vast.ai Template README

## Overview
This image provides a ready-to-use DeepFaceLab desktop environment accessible via VNC in your browser. It includes GPU-enabled DeepFaceLab, an Instance Portal, and optional Machine Video Editor tooling. On first boot, a provisioning script configures ports and finalizes setup automatically.

## What’s Included
- DeepFaceLab with CUDA support
- Instance Portal (web UI) for quick access and VNC
- VNC desktop on display :1 (port 5901 inside container)
- Optional Machine Video Editor binaries
- Conda environment and helper scripts

## Access & Ports
- Instance Portal is exposed via Vast.ai’s assigned external port, and the “Open” button in the console should work after provisioning.
- VNC service runs internally on port 5901; a reverse proxy makes it accessible via the portal.

## Credentials
- VNC password: set via `VNC_PASSWORD` (default: `deepfacelab` unless overridden).

## Provisioning Flow
On first boot, the image runs a provisioning script which:
1) Reads Vast-assigned external ports from env (e.g., `VAST_TCP_PORT_5901`, `VAST_TCP_PORT_11111`).
2) Exports `PORTAL_CONFIG` and `OPEN_BUTTON_PORT` to align the web portal and the VNC service with Vast’s external ports.
3) Finalizes DeepFaceLab setup and desktop environment.

This step is idempotent and typically completes in a few minutes.

## Persistent Storage
When creating the instance/template, allocate adequate disk (e.g., 200 GB+) for datasets, models, and outputs.

## Useful Paths
- Workspace: `/opt/DFL-MVE/DeepFaceLab/workspace`
- DeepFaceLab root: `/opt/DFL-MVE/DeepFaceLab`
- Conda env: `/opt/conda-envs/deepfacelab`
- Machine Video Editor: `/opt/MachineVideoEditor`

## Quick Start (inside container)
```bash
source /opt/setup-dfl-env.sh
cd /opt/DFL-MVE/DeepFaceLab
```

## Notes
- If the portal “Open” button doesn’t appear immediately, wait for provisioning to complete and check logs.
- You can view recent logs with the Vast.ai CLI and/or `docker logs` via SSH.


