#!/usr/bin/env bash
# Server only, run once: lets Docker containers use the NVIDIA GPU.
# Installs the NVIDIA container toolkit with apt. Uses sudo.

# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
load_config

[ "$ROLE" = server ] || die "bin/prereqs.sh is only for the server" "nothing to do on a client"
[ "$USE_GPU" = 1 ] || die "USE_GPU is not 1" "nothing to do without a GPU"

need nvidia-smi "install the NVIDIA driver first: sudo ubuntu-drivers install, then reboot"
nvidia-smi >/dev/null || die "nvidia-smi fails on the host" "fix the NVIDIA driver before continuing"
need curl "sudo apt-get install curl"

if ! command -v nvidia-ctk >/dev/null 2>&1; then
  info "Installing nvidia-container-toolkit (needs sudo)"
  keyring=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey |
    sudo gpg --dearmor --yes -o "$keyring"
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
    sed "s#deb https://#deb [signed-by=$keyring] https://#g" |
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y nvidia-container-toolkit
fi

if is_rootless; then
  info "Configuring rootless Docker for the NVIDIA runtime (needs sudo)"
  nvidia-ctk runtime configure --runtime=docker --config="$HOME/.config/docker/daemon.json"
  sudo nvidia-ctk config --set nvidia-container-cli.no-cgroups --in-place
  systemctl --user restart docker
else
  info "Configuring Docker for the NVIDIA runtime (needs sudo)"
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
fi

info "Checking the GPU from inside a container"
docker run --rm --gpus all --entrypoint nvidia-smi "ollama/ollama:$OLLAMA_IMAGE_TAG" ||
  die "the GPU is not visible inside a container" \
    "see https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/troubleshooting.html"

echo
info "GPU ready. Next: bin/up.sh"
