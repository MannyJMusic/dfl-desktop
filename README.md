# DeepFaceLab-MVE Docker Image

This Docker image provides a complete DeepFaceLab environment with Machine Video Editor, running on Python 3.10, TensorFlow 2.13, with CUDA 11.8 support and a KDE Plasma desktop accessible via VNC.

## Components

- **DeepFaceLab-MVE**: Latest version from [MannyJMusic/DFL-MVE](https://github.com/MannyJMusic/DFL-MVE)
- **Machine Video Editor**: Included for video processing and editing
- **Python 3.10**: Modern Python version
- **TensorFlow 2.13**: GPU-enabled deep learning framework
- **CUDA 11.8 + cuDNN 8.6**: NVIDIA GPU acceleration
- **KDE Plasma Desktop**: Full desktop environment
- **TigerVNC Server**: Remote desktop access on port 5901

## Build the Image

```bash
cd DFL-IMAGE
docker build --platform linux/amd64 --network=host -t deepfacelab-mve:latest .
```

**Note**: 
- Use `--platform linux/amd64` to build for x86_64 architecture (required for NVIDIA CUDA support)
- Build with `--network=host` to avoid network issues when downloading packages

## Run the Container

### Basic GPU-enabled container:

```bash
docker run --gpus all --rm -it \
  -p 5901:5901 \
  deepfacelab-mve:latest
```

### With persistent storage for workspace:

```bash
docker run --gpus all --rm -it \
  -p 5901:5901 \
  -v /path/to/your/workspace:/root/workspace \
  -v /path/to/your/models:/opt/DFL-MVE/DeepFaceLab/workspace/model \
  deepfacelab-mve:latest
```

### With more resources allocated:

```bash
docker run --gpus all --rm -it \
  -p 5901:5901 \
  --shm-size=16g \
  --memory=32g \
  deepfacelab-mve:latest
```

## Connect via VNC

Once the container is running:

1. Install a VNC client (e.g., TigerVNC, RealVNC, or TightVNC)
2. Connect to `localhost:5901`
3. Use password: `deepfacelab`
4. You'll see the KDE Plasma desktop

**Security Note**: Change the VNC password in `scripts/setup-vnc.sh` before building for production use.

## Access DeepFaceLab

Once connected via VNC, DeepFaceLab is located at:
- `/opt/DFL-MVE/DeepFaceLab/` (main installation)
- `~/DeepFaceLab` (symlink)
- `~/workspace` (workspace directory - symlink)

## Access Machine Video Editor

Machine Video Editor is available as:
- `/opt/MachineVideoEditor/` (installation directory)
- `machine-video-editor` (command line executable)

## Requirements

- **Host System**: Linux with NVIDIA GPU (Windows/Mac via WSL2/VirtualBox may work but GPU acceleration will be limited)
- **Docker**: Version 20.10+
- **NVIDIA Drivers**: Compatible with CUDA 11.8
- **NVIDIA Container Toolkit**: For GPU access in containers

### Install NVIDIA Container Toolkit

```bash
# Ubuntu/Debian
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list

sudo apt-get update && sudo apt-get install -y nvidia-container-toolkit
sudo systemctl restart docker
```

## Optimization Features

This image has been optimized for size:
- Combined RUN commands to reduce layers
- Aggressive cleanup of caches and temporary files
- Removed development tools after installation
- Used `--no-install-recommends` for apt packages
- Cleared pip and conda caches
- Removed git after cloning repositories

## Troubleshooting

### VNC not accessible
- Ensure port 5901 is not in use: `netstat -tuln | grep 5901`
- Check firewall rules
- Verify container is running: `docker ps`

### GPU not detected
- Verify NVIDIA drivers: `nvidia-smi`
- Check container has GPU access: `docker run --gpus all --rm nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi`
- Ensure `--gpus all` flag is used when running

### Out of memory errors
- Increase container memory: `--memory=32g`
- Increase shared memory: `--shm-size=16g`
- Consider training with smaller batch sizes

### Python/TensorFlow import errors
- Check CUDA version matches TensorFlow requirements
- Verify all dependencies installed: `docker exec -it <container> pip list`

## License

This Docker image follows the GPL-3.0 license as per the original DeepFaceLab project.

