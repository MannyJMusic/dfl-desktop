# VAST-AI CLI Cheatsheet

## Search for GPU Offers

Search for GPU offers with specific criteria:

```bash
vastai search offers 'geolocation=US gpu_ram>=48' -o dph
```

## Build and Push Docker Image

First, build your Docker image:

```bash
cd DFL-IMAGE
docker build --platform linux/amd64 -t mannyj37/dfl-desktop:latest .
```

Push to Docker Hub:

```bash
docker push mannyj37/dfl-desktop:latest
```

## Create Vast.ai Template

Create a template with provisioning script. Replace the PROVISIONING_SCRIPT URL with your GitHub raw URL:

```bash
vastai create template \
  --name "DeepFaceLab Desktop" \
  --image "mannyj37/dfl-desktop:latest" \
  --env 'PROVISIONING_SCRIPT=https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/DFL-IMAGE/config/provisioning/vastai-provisioning.sh' \
  --env 'PORTAL_CONFIG=localhost:5901:5901:/:VNC Desktop|localhost:1111:11111:/:Instance Portal' \
  --disk 200
```

**Note:** Update `YOUR_USERNAME` and `YOUR_REPO` in the PROVISIONING_SCRIPT URL to match your GitHub repository.

## Create Instance from Template

After creating the template, create an instance from it:

```bash
vastai create instance <OFFER_ID> \
  --template "DeepFaceLab Desktop" \
  --ssh \
  --direct
```

To find available offers:

```bash
vastai search offers 'geolocation=US gpu_ram>=48' -o dph
```

## Create Instance Directly (Alternative)

You can also create an instance directly without a template:

```bash
vastai create instance <OFFER_ID> \
  --image "mannyj37/dfl-desktop:latest" \
  --env 'PROVISIONING_SCRIPT=https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/DFL-IMAGE/config/provisioning/vastai-provisioning.sh' \
  --env 'PORTAL_CONFIG=localhost:5901:5901:/:VNC Desktop|localhost:1111:11111:/:Instance Portal' \
  --disk 200 \
  --ssh \
  --direct
```

## Access VNC Desktop

Once the instance is running and the provisioning script has completed:

1. Access the instance via SSH
2. The VNC server runs on display :1 (port 5901)
3. Use the Instance Portal link provided by Vast.ai to access VNC through your browser
4. Default VNC password: `deepfacelab`

## Activate DeepFaceLab Environment

After SSH into the instance:

```bash
source /opt/setup-dfl-env.sh
cd /opt/DFL-MVE/DeepFaceLab
```

## Important Notes

- The provisioning script runs automatically on first boot
- All installations are in `/opt/` directory
- Workspace is at `/opt/DFL-MVE/DeepFaceLab/workspace`
- Conda environment: `/opt/conda-envs/deepfacelab`
- Machine Video Editor: `/opt/MachineVideoEditor`
