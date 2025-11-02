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

## Test Docker Image Locally

Before deploying to Vast.ai, you can test the Docker image locally with GPU support:

### Basic GPU-enabled container

```bash
docker run --gpus all --rm -it \
  -p 5901:5901 \
  -p 1111:11111 \
  mannyj37/dfl-desktop:latest
```

### With persistent storage for workspace

```bash
docker run --gpus all --rm -it \
  -p 5901:5901 \
  -p 1111:11111 \
  -v /path/to/your/workspace:/opt/DFL-MVE/DeepFaceLab/workspace \
  mannyj37/dfl-desktop:latest
```

### With more resources allocated

```bash
docker run --gpus all --rm -it \
  -p 5901:5901 \
  -p 1111:11111 \
  --shm-size=16g \
  --memory=32g \
  mannyj37/dfl-desktop:latest
```

**Note:** The flags and ports are required:

- `--gpus all`: Enable GPU access for TensorFlow/CUDA
- `--rm`: Automatically remove container when it exits
- `-it`: Interactive terminal mode
- `-p 5901:5901`: Expose VNC Desktop port (internal 5901 → external 5901)
- `-p 1111:11111`: Expose Instance Portal port (maps external port 1111 to internal port 11111, matching PORTAL_CONFIG)

## Create Vast.ai Template

Create a template with provisioning script. Replace the PROVISIONING_SCRIPT URL with your GitHub raw URL:

```bash
vastai create template \
  --name "DeepFaceLab Desktop" \
  --image "mannyj37/dfl-desktop:latest" \
  --env "-p 5901:5901 -p 1111:11111 -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/MannyJMusic/dfl-desktop/refs/heads/main/config/provisioning/vastai-provisioning.sh -e PORTAL_CONFIG=localhost:5901:5901:/:VNC Desktop|localhost:1111:11111:/:Instance Portal" \
  --disk_space 200
```

**Note:** According to the [Vast.ai CLI documentation](https://docs.vast.ai/cli/commands), the `--env` flag accepts Docker options including port mappings with `-p` and environment variables with `-e`. Port mappings must match PORTAL_CONFIG:

- `-p 5901:5901`: VNC Desktop (external = internal, uses secure tunnel)
- `-p 1111:11111`: Instance Portal (external port 1111 proxies to internal port 11111 via Caddy reverse proxy)

When external port ≠ internal port (like `1111:11111`), Caddy reverse proxy makes the application available on the external port, as per the [Instance Portal documentation](https://docs.vast.ai/documentation/instances/connect/instance-portal).

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
vastai create instance 25105510 \
  --image "mannyj37/dfl-desktop:latest" \
  --env "-p 5901:5901 -p 1111:11111 -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/MannyJMusic/dfl-desktop/refs/heads/main/config/provisioning/vastai-provisioning.sh -e PORTAL_CONFIG=localhost:5901:5901:/:VNC Desktop|localhost:1111:11111:/:Instance Portal" \
  --disk 200 \
  --ssh \
  --direct
```

**Note:** According to the [Vast.ai CLI documentation](https://docs.vast.ai/cli/commands), the `--env` flag accepts Docker options including port mappings (`-p`) and environment variables (`-e`). PORTAL_CONFIG format is `Interface:ExternalPort:InternalPort:Path:Name`. When external ≠ internal (like `1111:11111`), Caddy reverse proxy makes the app available on the external port, as per the [Instance Portal documentation](https://docs.vast.ai/documentation/instances/connect/instance-portal).

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
