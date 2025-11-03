# VAST-AI CLI Cheatsheet

## Frequently Used Commands

### Quick Start: Create Instance with Base Image

Most frequently used command to create an instance with the Vast.ai base image and provisioning script:

```bash
vastai create instance 25076231 --image vastai/base-image:@vastai-automatic-tag --env '-p 1111:1111 -p 6006:6006 -p 8080:8080 -p 8384:8384 -p 72299:72299 -e OPEN_BUTTON_PORT=1111 -e OPEN_BUTTON_TOKEN=1 -e JUPYTER_DIR=/ -e DATA_DIRECTORY=/workspace/ -e PORTAL_CONFIG="localhost:1111:11111:/:Instance Portal|localhost:8080:18080:/:Jupyter|localhost:8080:8080:/terminals/1:Jupyter Terminal|localhost:8384:18384:/:Syncthing|localhost:6006:16006:/:Tensorboard" -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/MannyJMusic/dfl-desktop/refs/heads/main/config/provisioning/vastai-provisioning.sh' --onstart-cmd 'entrypoint.sh --sync-environment' --disk 32 --create-volume 25076233 --volume-size 30 --mount-path '/data/workspace' --jupyter --ssh --direct
```

**Note:** Replace `25105506` with your offer ID and `25105512` with your volume ask ID.

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

Create a template that uses the base image PROVISIONING_SCRIPT (downloaded and executed automatically on first boot):

```bash
vastai create template \
  --name "DeepFaceLab Desktop" \
  --image "mannyj37/dfl-desktop:latest" \
  --env "-p 5901 -p 11111 -e VNC_PASSWORD=deepfacelab -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/MannyJMusic/dfl-desktop/refs/heads/main/config/provisioning/vastai-provisioning.sh" \
  --disk_space 50
```

**Note:** Don't include volume mounts (`-v`) in templates - volumes are machine-specific and must be attached when creating instances.

**Note:** According to the [Vast.ai Advanced Setup documentation](https://docs.vast.ai/documentation/templates/advanced-setup):

- The `--env` flag accepts Docker options including port mappings with `-p` and environment variables with `-e`
- `PROVISIONING_SCRIPT` is automatically downloaded and executed by the base image on first boot
- Port mappings can be assigned automatically; the provisioning script reads actual external ports from `VAST_TCP_PORT_5901` and `VAST_TCP_PORT_11111` and sets `PORTAL_CONFIG` and `OPEN_BUTTON_PORT` accordingly
- VNC password is set via `VNC_PASSWORD` (default `deepfacelab`)
- See [Instance Portal docs](https://docs.vast.ai/documentation/instances/connect/instance-portal)

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

## Create Volume (200GB for Workspace)

### Method 1: Create Volume When Creating an Instance

You can create a volume during instance creation:

```bash
# First, search for volume offers
vastai search volumes

# Then create instance with volume creation
vastai create instance <OFFER_ID> \
  --image <IMAGE> \
  --create-volume <VOLUME_ASK_ID> \
  --volume-size 200 \
  --volume-label dfl_ws \
  --mount-path /workspace \
  --ssh \
  --direct
```

### Method 2: Create Volume Separately (If Supported)

Some machines allow standalone volume creation, but typically volumes are created when creating instances.

**Important:**

- Use `--create-volume <VOLUME_ASK_ID>` to create a new volume (get ID from `vastai search volumes`)
- Use `--link-volume <VOLUME_ID>` to link an existing volume (get ID from `vastai show volumes`)
- `--mount-path` specifies where the volume appears inside the container - use simple paths like `/workspace` or `/mnt` (Vast.ai doesn't allow deep nested paths)
- `--volume-size` is in GB (default 15GB if not specified)
- `--volume-label` is an optional name for the volume

## Complete Workflow: Create Template + Volume + Instance

Here's the complete workflow to create a template with 50GB container storage and 200GB volume:

### Step 1: Create Template (No Volume)

```bash
vastai create template \
  --name "DFL Desktop 50/200" \
  --image "mannyj37/dfl-desktop:latest" \
  --env "-p 5901 -p 11111 -e VNC_PASSWORD=deepfacelab -e PROVISIONING_SCRIPT=https://raw.githubusercontent.com/MannyJMusic/dfl-desktop/refs/heads/main/config/provisioning/vastai-provisioning.sh" \
  --disk_space 50
```

### Step 2: Find Suitable Offer

```bash
# Search for offers with enough disk space (50GB container + 200GB volume = 250GB minimum)
vastai search offers 'geolocation=US gpu_ram>=48 disk_space>=260' -o dph
```

### Step 3: Get Existing Volume ID (or Create New Volume)

#### Option A: Link an Existing Volume

First, get your volume ID from `vastai show volumes`:

```bash
# List all your volumes to find the volume ID
vastai show volumes
```

You'll see output like:

```text
ID      NAME    SIZE    MACHINE_ID    STATUS
27535359 dfl_ws  200GB   12345        ready
```

#### Option B: Create a New Volume

If you need to create a new volume:

```bash
# Search for volume offers on the machine
vastai search volumes

# Create a volume (using VOLUME_ASK_ID from search results)
vastai create instance <OFFER_ID> \
  --image <IMAGE> \
  --create-volume <VOLUME_ASK_ID> \
  --volume-size 200 \
  --volume-label dfl_ws \
  --mount-path /workspace
```

### Step 4: Create Instance from Template with Existing Volume

**Using template name with existing volume:**

```bash
vastai create instance <OFFER_ID> \
  --template "DFL Desktop 50/200" \
  --link-volume 27535359 \
  --mount-path /workspace \
  --ssh \
  --direct
```

**Using template hash with existing volume:**

```bash
# First get template hash
vastai search templates --raw | grep -i "DFL Desktop"

# Then create instance with linked volume
vastai create instance <OFFER_ID> \
  --template_hash <TEMPLATE_HASH> \
  --link-volume 27535359 \
  --mount-path /workspace \
  --ssh \
  --direct
```

**Important Notes:**

- `--link-volume <VOLUME_ID>` links an existing volume to the instance (get ID from `vastai show volumes`)
- `--mount-path /workspace` mounts the volume at `/workspace` inside the container (Vast.ai requires simple paths)
- The provisioning script will automatically use `/workspace` for persistent storage
- The volume must exist and be accessible before creating the instance
- Use `--create-volume` instead of `--link-volume` if you want to create a new volume during instance creation

## Check Volume Status

To list your volumes:

```bash
# List all your volumes (shows volume IDs, names, sizes, machine IDs, and status)
vastai show volumes
```

**Example output:**

```text
ID      NAME    SIZE    MACHINE_ID    STATUS
27535359 dfl_ws  200GB   12345        ready
```

**Important:**

- Get the volume ID from this list to use with `--link-volume`
- Volumes are attached at instance creation time using `--link-volume <VOLUME_ID>` and `--mount-path <PATH>`
- You cannot attach volumes to existing instances - you must recreate the instance with the volume flags

## Verify Volume is Attached

To check if a volume is attached to your instance:

```bash
# SSH into the instance
$(vastai ssh-url <INSTANCE_ID>)

# Check if volume is mounted
df -h | grep workspace
ls -la /opt/DFL-MVE/DeepFaceLab/workspace
```

## Create Instance from Template (without Volume)

If you don't need a volume or want to attach it later:

```bash
vastai create instance <OFFER_ID> \
  --template "DeepFaceLab Desktop" \
  --ssh \
  --direct
```

**Note:** If you get an error "invalid template hash or id or template not accessible by user", the template may not exist yet. Make sure to create it first using `vastai create template`, then verify it exists with `vastai search templates`.

## Create Instance Directly (Alternative)

You can also create an instance directly without a template:

**With existing volume (linking volume ID 27535359 as example):**

```bash
vastai create instance <OFFER_ID> \
  --image "mannyj37/dfl-desktop:latest" \
  --env "-p 5901 -p 11111 -e VNC_PASSWORD=deepfacelab" \
  --link-volume 27535359 \
  --mount-path /workspace \
  --disk 50 \
  --ssh \
  --direct
```

**With new volume creation:**

```bash
# First: vastai search volumes to get VOLUME_ASK_ID
vastai create instance <OFFER_ID> \
  --image "mannyj37/dfl-desktop:latest" \
  --env "-p 5901 -p 11111 -e VNC_PASSWORD=deepfacelab" \
  --create-volume <VOLUME_ASK_ID> \
  --volume-size 200 \
  --volume-label dfl_ws \
  --mount-path /workspace \
  --disk 50 \
  --ssh \
  --direct
```

**Without volume:**

```bash
vastai create instance <OFFER_ID> \
  --image "mannyj37/dfl-desktop:latest" \
  --env "-p 5901 -p 11111 -e VNC_PASSWORD=deepfacelab" \
  --disk 50 \
  --ssh \
  --direct
```

**Note:** According to the [Vast.ai Advanced Setup documentation](https://docs.vast.ai/documentation/templates/advanced-setup):

- Use `--env` for Docker options including port mappings (`-p`) and environment variables (`-e`).
- `PROVISIONING_SCRIPT` is automatically downloaded and executed by the base image on first boot.
- `PORTAL_CONFIG` format is `Interface:ExternalPort:InternalPort:Path:Name` (the provisioning script generates this dynamically using Vast's assigned external ports).
- `OPEN_BUTTON_PORT` (and `OPEN_BUTTON_TOKEN`) control the Instance Portal "Open" button; the provisioning script sets `OPEN_BUTTON_PORT` to the external portal port.
- `VNC_PASSWORD` sets the VNC password (default: `deepfacelab` if not specified).
- When external ≠ internal (e.g., external `40031` → internal `11111`), the reverse proxy exposes the app on the external port; see [Instance Portal](https://docs.vast.ai/documentation/instances/connect/instance-portal).

**Important:** The provisioning script is idempotent and configures `PORTAL_CONFIG` and `OPEN_BUTTON_PORT` based on the actual external ports provided by Vast (`VAST_TCP_PORT_5901` and `VAST_TCP_PORT_11111`), so the "Open" button works reliably. See [SSH Connection](https://docs.vast.ai/documentation/instances/connect/ssh) and [Instance Portal](https://docs.vast.ai/documentation/instances/connect/instance-portal).

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
