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
  --env "-p 5901:5901 -p 1111:11111 -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/MannyJMusic/dfl-desktop/refs/heads/main/config/provisioning/vastai-provisioning.sh -e PORTAL_CONFIG='localhost:5901:5901:/:VNC Desktop|localhost:1111:11111:/:Instance Portal' -e OPEN_BUTTON_PORT=1111 -e OPEN_BUTTON_TOKEN=1 -e VNC_PASSWORD=deepfacelab" \
  --disk_space 200
```

**Note:** According to the [Vast.ai Advanced Setup documentation](https://docs.vast.ai/documentation/templates/advanced-setup):

- The `--env` flag accepts Docker options including port mappings with `-p` and environment variables with `-e`
- `PROVISIONING_SCRIPT` is an environment variable that the Vast.ai base image automatically downloads and executes on first boot
- The base image handles downloading and running the script from the URL automatically
- Port mappings must match PORTAL_CONFIG:
  - `-p 5901:5901`: VNC Desktop (external = internal, uses secure tunnel)
  - `-p 1111:11111`: Instance Portal (external port 1111 proxies to internal port 11111 via Caddy reverse proxy)
- PORTAL_CONFIG must be single-quoted to properly handle the pipe character `|` separator
- OPEN_BUTTON_PORT and OPEN_BUTTON_TOKEN configure the Instance Portal open button behavior
- VNC_PASSWORD sets the VNC password (default: `deepfacelab` if not specified)
- When external port ≠ internal port (like `1111:11111`), Caddy reverse proxy makes the application available on the external port, as per the [Instance Portal documentation](https://docs.vast.ai/documentation/instances/connect/instance-portal).

## List Your Templates

Before creating an instance from a template, verify it exists and get its hash:

```bash
vastai search templates
```

This will show all your templates with their names, IDs, and hashes. Look for "DeepFaceLab Desktop" and note the template hash or ID.

To search specifically for your template:

```bash
vastai search templates --raw | grep -i "DeepFaceLab"
```

## Create Instance from Template

After creating the template and verifying it exists, create an instance from it using either the template name or the template hash:

**Using template name:**

```bash
vastai create instance <OFFER_ID> \
  --template "DeepFaceLab Desktop" \
  --ssh \
  --direct
```

**Using template hash (more reliable):**

```bash
vastai create instance <OFFER_ID> \
  --template_hash <TEMPLATE_HASH> \
  --ssh \
  --direct
```

To find available offers:

```bash
vastai search offers 'geolocation=US gpu_ram>=48' -o dph
```

**Note:** If you get an error "invalid template hash or id or template not accessible by user", the template may not exist yet. Make sure to create it first using `vastai create template`, then verify it exists with `vastai search templates`.

## Create Instance Directly (Alternative)

You can also create an instance directly without a template:

```bash
vastai create instance 25105510 \
  --image "mannyj37/dfl-desktop:latest" \
  --env "-p 5901:5901 -p 1111:11111 -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/MannyJMusic/dfl-desktop/refs/heads/main/config/provisioning/vastai-provisioning.sh -e PORTAL_CONFIG='localhost:5901:5901:/:VNC Desktop|localhost:1111:11111:/:Instance Portal' -e OPEN_BUTTON_PORT=1111 -e OPEN_BUTTON_TOKEN=1 -e VNC_PASSWORD=deepfacelab" \
  --disk 200 \
  --ssh \
  --direct
```

**Note:** According to the [Vast.ai Advanced Setup documentation](https://docs.vast.ai/documentation/templates/advanced-setup):

- The `--env` flag accepts Docker options including port mappings (`-p`) and environment variables (`-e`)
- `PROVISIONING_SCRIPT` environment variable is automatically downloaded and executed by the Vast.ai base image on first boot - no `--onstart-cmd` needed
- PORTAL_CONFIG format is `Interface:ExternalPort:InternalPort:Path:Name` - must be single-quoted to handle the pipe character
- OPEN_BUTTON_PORT=1111 and OPEN_BUTTON_TOKEN=1 configure the Instance Portal open button
- VNC_PASSWORD sets the VNC password (default: `deepfacelab` if not specified)
- When external ≠ internal (like `1111:11111`), Caddy reverse proxy makes the app available on the external port, as per the [Instance Portal documentation](https://docs.vast.ai/documentation/instances/connect/instance-portal)

**Important:** The Vast.ai base image automatically downloads and executes the script from the `PROVISIONING_SCRIPT` environment variable URL on first boot, as documented in the [Advanced Setup guide](https://docs.vast.ai/documentation/templates/advanced-setup).

## Connect to Instance via SSH

To SSH into your Vast.ai instance:

1. **Get the SSH connection command:**

   ```bash
   vastai ssh-url <INSTANCE_ID>
   ```

   Example output:

   ```bash
   ssh -p 12345 root@123.456.789.012
   ```

2. **Connect to the instance:**

   **Option A:** Copy and paste the command from step 1

   **Option B:** Run it directly in one command:

   ```bash
   $(vastai ssh-url <INSTANCE_ID>)
   ```

   **Option C:** Use the web console's "Connect" button which provides the same SSH command

### Alternative: Using SSH Key

If you need to attach your SSH key to the instance first:

```bash
# Attach your SSH key to the instance
vastai attach ssh <INSTANCE_ID> "$(cat ~/.ssh/id_rsa.pub)"
```

Then use `vastai ssh-url <INSTANCE_ID>` to get the connection command.

## View Container Logs

### View Recent Logs via Vast.ai CLI

To view recent container logs (last 1000 lines by default):

```bash
vastai logs <INSTANCE_ID>
```

View last N lines:

```bash
vastai logs <INSTANCE_ID> --tail <NUMBER>
```

Example (last 500 lines):

```bash
vastai logs 12345 --tail 500
```

### View Real-Time Logs (Streaming)

For real-time streaming logs, you need to SSH into the instance and use Docker logs:

1. **Get SSH connection command:**

   ```bash
   vastai ssh-url <INSTANCE_ID>
   ```

   This will output an SSH command like:

   ```bash
   ssh -p <port> root@<instance_ip>
   ```

2. **SSH into the instance:**

   Copy and run the command from step 1, or use it directly:

   ```bash
   $(vastai ssh-url <INSTANCE_ID>)
   ```

3. **Find the container ID:**

   ```bash
   docker ps
   ```

4. **Stream logs in real-time:**

   ```bash
   docker logs -f <CONTAINER_ID>
   ```

   Or if you know the container name:

   ```bash
   docker logs -f <container_name>
   ```

5. **With timestamps:**

   ```bash
   docker logs -f -t <CONTAINER_ID>
   ```

### View Provisioning Script Logs

The provisioning script output may also be available in log files. After SSH:

```bash
# Check for provisioning logs in common locations
tail -f /tmp/vastai-provisioning.log 2>/dev/null || \
tail -f /var/log/provisioning.log 2>/dev/null || \
journalctl -u provisioning -f 2>/dev/null
```

## Troubleshooting Connect Button Issues

If the "Connect" or "Open" button in the Vast.ai console isn't working:

1. **Check Instance Portal Service:**

   ```bash
   # Get SSH command
   vastai ssh-url <INSTANCE_ID>
   # SSH into the instance (use the command from above)
   ssh -p <port> root@<instance_ip>
   # Check if Instance Portal is running
   ps aux | grep -i portal
   netstat -tlnp | grep 11111
   ```

2. **Verify PORTAL_CONFIG:**

   ```bash
   # Inside the container
   cat /etc/environment | grep PORTAL_CONFIG
   echo $PORTAL_CONFIG
   ```

3. **Check OPEN_BUTTON_PORT and OPEN_BUTTON_TOKEN:**

   ```bash
   cat /etc/environment | grep OPEN_BUTTON
   ```

4. **Restart Instance Portal (if needed):**

   ```bash
   # Inside the container
   supervisorctl restart instance_portal
   # Or restart the entire container
   ```

5. **Verify Port Mapping:**
   - External port 1111 should map to internal port 11111
   - Check with: `docker ps` to see port mappings

## Access VNC Desktop

Once the instance is running and the provisioning script has completed:

1. Access the instance via SSH
2. The VNC server runs on display :1 (port 5901)
3. Use the Instance Portal link provided by Vast.ai to access VNC through your browser
4. Default VNC password: `deepfacelab` (can be changed via `VNC_PASSWORD` environment variable)

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
