#!/usr/bin/env bash
# One-time setup for the CONTAINER HOST (e.g. Ubuntu — any distro with apt is
# fine as long as podman/nix install; adjust the package manager otherwise).
#
# Installs:
#   1. podman                     — container runtime (rootless)
#   2. nix (multi-user, systemd)  — builds .#container-image
#   3. NVIDIA container toolkit   — CDI spec so `--device nvidia.com/gpu=all`
#                                   injects driver libs + device nodes
#
# Assumes the NVIDIA DRIVER is already installed and `nvidia-smi` works.
# Run with sudo for the apt/toolkit parts; nix is installed multi-user.
set -euo pipefail

[[ $(id -u) -eq 0 ]] || { echo "Run with sudo: sudo ./bootstrap-host.sh" >&2; exit 1; }

echo "== podman =="
if ! command -v podman >/dev/null; then
  apt-get update
  apt-get install -y podman
else
  echo "already installed"
fi

echo "== nix (multi-user) =="
if ! command -v nix >/dev/null; then
  curl -fsSL https://nixos.org/nix/install -o /tmp/nix-install.sh
  sh /tmp/nix-install.sh --daemon --yes
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
else
  echo "already installed"
fi

echo "== NVIDIA container toolkit (CDI) =="
if ! command -v nvidia-ctk >/dev/null; then
  . /etc/os-release
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update
  apt-get install -y nvidia-container-toolkit
else
  echo "already installed"
fi
# CDI spec: maps host driver libs + /dev/nvidia* for `--device nvidia.com/gpu=all`.
mkdir -p /etc/cdi
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml

echo
echo "Done. Regenerate the CDI spec after driver upgrades:"
echo "  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
echo "Next: nix build .#container-image && ./container/run.sh"
