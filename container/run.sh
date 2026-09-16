#!/usr/bin/env bash
# Build, load and run the dev container with sane defaults.
#
#   ./container/run.sh                 # rebuild image, recreate container
#   GPU=0 ./container/run.sh           # no GPU (CPU-only run)
#   podman exec -it lab-dev zsh        # enter (over SSH to the host)
#
# Servers inside bind their container loopback; the -p mappings publish them
# on the HOST's loopback, so your usual `ssh -L 8188:127.0.0.1:8188 <host>`
# tunnels work unchanged.
set -euo pipefail
cd "$(dirname "$0")/.."

GPU="${GPU:-1}"
NAME="${NAME:-lab-dev}"
HOME_DIR="${HOME_DIR:-$PWD/lab-home}"          # /home/bob (dotfiles + bootstraps + models)
PROJECTS_DIR="${PROJECTS_DIR:-$PWD/projects}"  # your source checkouts

mkdir -p "$HOME_DIR" "$PROJECTS_DIR"

echo "== building image (nix) =="
nix build --extra-experimental-features "nix-command flakes" .#container-image -o result-container

echo "== loading into podman =="
# podman refuses to load archives without a signature policy; default to
# accept-all for this dev workflow (user-level, created only if missing).
POLICY="${XDG_CONFIG_HOME:-$HOME/.config}/containers/policy.json"
if [ ! -f "$POLICY" ]; then
  mkdir -p "$(dirname "$POLICY")"
  printf '{"default":[{"type":"insecureAcceptAnything"}]}\n' > "$POLICY"
fi
./result-container | podman load

# Recreate: the image is authoritative for the environment; the home volume
# keeps everything bootstrapped/stateful (uv venvs, comfy, unsloth, models).
podman rm -f "$NAME" >/dev/null 2>&1 || true

GPU_ARGS=()
if [ "$GPU" = "1" ]; then
  # Requires the CDI spec from container/bootstrap-host.sh.
  GPU_ARGS=(--device nvidia.com/gpu=all)
fi

echo "== running $NAME =="
podman run -d --name "$NAME" \
  "${GPU_ARGS[@]}" \
  -v "$HOME_DIR:/home/bob" \
  -v "$PROJECTS_DIR:/home/bob/projects" \
  -p 127.0.0.1:8188:8188 \
  -p 127.0.0.1:8888:8888 \
  -p 127.0.0.1:8000:8000 \
  localhost/lab-dev:latest

echo
echo "Up. Enter with:  podman exec -it $NAME zsh"
echo "Servers (host loopback): ComfyUI :8188, Unsloth :8888, vLLM :8000"
echo "GPU check inside:        nvidia-smi"
