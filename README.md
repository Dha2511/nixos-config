# nixos-config

One flake, three targets — same shell, editor, keybinds, theme, and CLI
environment across all of them:

| Target | OS / arch | User | GPU | Flake output |
|---|---|---|---|---|
| MSI desktop | NixOS / x86_64 | `bob` | NVIDIA RTX 3050 + Intel iGPU | `.#nixosConfigurations.nixos` |
| M2 Mac (UTM guest) | NixOS / aarch64 | `bob` | virtio-gpu (no CUDA) | `.#nixosConfigurations.m2` |
| Work Ubuntu laptop | Ubuntu / x86_64 | `owner` | NVIDIA RTX 4090 | `.#homeConfigurations.owner` |

The home-manager module under `home/` is shared verbatim across all three;
host differences (username, home dir, NVIDIA-ness, arch) are injected as
`extraSpecialArgs` from `flake.nix`.

## Structure

```
nixos-config/
├── flake.nix                  # mkNixos / mkHome helpers; threads username,
│                              # homeDirectory, isNvidia, hostName through
│                              # extraSpecialArgs. Three outputs: nixos, m2,
│                              # owner (+ a generic `bob` standalone).
├── hosts/
│   ├── nixos/                 # MSI desktop (x86_64, NVIDIA hybrid)
│   │   ├── configuration.nix          # boot, NVIDIA, networking, services
│   │   └── hardware-configuration.nix # disk UUIDs + kernel modules
│   └── m2/                    # Apple Silicon UTM guest (aarch64, virtio)
│       ├── configuration.nix          # UEFI, virtio modules, sway, no NVIDIA
│       └── hardware-configuration.nix # template; replace after nixos-generate-config
├── home/                      # shared home-manager module (all three hosts)
│   ├── default.nix            # packages, zsh, starship, cursor, fonts,
│   │                          # direnv, llama.cpp service, desktop entries
│   ├── sway.nix               # Sway config + Noctalia keybinds
│   └── scripts.nix            # ComfyUI (NVIDIA + portable), Blender prebuilt,
│                              # nvidia-offload, llama-serve launcher
└── xkb/graphite               # custom Graphite keyboard layout
```

## Per-host flags (in `flake.nix`)

`mkNixos` and `mkHome` thread these into the home module via
`extraSpecialArgs`:

- `username` / `homeDirectory` — what they sound like.
- `isNvidia` — gates the CUDA payload (ComfyUI launcher with `cupy-cuda13x`,
  prebuilt x86_64 Blender with NVIDIA libs, `nvidia-offload`). Non-NVIDIA
  hosts get portable equivalents. **Do not** infer this from `isx86_64` —
  x86_64 ≠ NVIDIA (Intel/AMD-only boxes and the aarch64 M2 all have
  `isNvidia = false`).
- `hostName` — selects `hosts/${hostName}/` for NixOS outputs.
- `isNixOS` — true for `nixosConfigurations.*`, false for
  `homeConfigurations.*`. Selects NixOS-only behavior in the Sway config
  (Graphite layout toggle) and the NVIDIA-offload wrapper.

A handful of packages are gated separately by `pkgs.stdenv.hostPlatform.isx86_64`
(bazecor, davinci-resolve, vivaldi) because upstream doesn't ship aarch64
builds — those are unrelated to NVIDIA.

## Target: NixOS desktop

```sh
nh os switch .
```

## Target: Work Ubuntu (or any non-NixOS Linux)

One-time setup:

```sh
# 1. Install Nix (Determinate Systems installer)
curl -fsSL https://install.determinate.systems/nix | sh -s -- install

# 2. Install sway + deps that must come from the system package manager
sudo apt install sway wmenu foot wl-clipboard grim jq libnotify dconf-cli

# 3. (NVIDIA only) Driver + a Sway session entry that passes --unsupported-gpu.
#    ubuntu-drivers autoinstall also drops libnvidia-gl-* (libEGL_nvidia.so.0
#    in /usr/lib/x86_64-linux-gnu), which the nix GUI bridge in
#    home/default.nix depends on — without it nix-built apps (noctalia, obs,
#    zed, etc.) fail with "eglGetDisplay failed".
sudo ubuntu-drivers autoinstall && sudo reboot
# After reboot — register a NVIDIA Sway entry in the GDM gear menu. A separate
# .desktop (rather than editing stock sway.desktop) survives apt upgrades of
# the sway package, and keeps the plain-Sway option for non-NVIDIA boxes.
sudo tee /usr/share/wayland-sessions/sway-nvidia.desktop >/dev/null <<'EOF'
[Desktop Entry]
Name=Sway (NVIDIA)
Comment=Sway with --unsupported-gpu for NVIDIA proprietary
Exec=sway --unsupported-gpu
Type=Application
DesktopNames=Sway
EOF

# 4. Clone and apply (NOTE: output name matches your username — `owner` here)
git clone https://github.com/Dha2511/nixos-config.git ~/nixos-config
cd ~/nixos-config
nix run home-manager -- switch --flake .#owner

# 5. Git auth (one-time)
gh auth login

# 6. Set zsh as login shell (foot already uses it via foot.ini, but this
#    also covers SSH sessions and other terminals)
chsh -s $(which zsh)
```

Log out, pick **Sway (NVIDIA)** at the login screen gear icon (or plain
**Sway** on non-NVIDIA boxes).

> **Note:** Nix packages are additive — they sit alongside system packages in
> PATH. `apt`, `snap`, `pip`, etc. all continue to work normally. No isolation.
>
> **Podman:** The nix-installed podman may need `subuid`/`subgid` setup on
> Ubuntu. For full container support, `sudo apt install podman` instead.
>
> **Graphite keyboard layout:** Only available on NixOS (installed via the XKB
> module). On Ubuntu, the layout falls back to US + altgr-intl (Danish via
> AltGr). To install manually, copy `xkb/graphite` to
> `/usr/share/X11/xkb/symbols/` and register it in `/usr/share/X11/xkb/rules/evdev.xml`.

Update later:

```sh
cd ~/nixos-config && git pull && nix run home-manager -- switch --flake .#owner
```

## Target: M2 NixOS guest in UTM

There are two ways to build the aarch64 closure: cross-build from the desktop
via `boot.binfmt.emulatedSystems` (already configured in
`hosts/nixos/configuration.nix`), or natively inside the VM.

### Option A — Cross-build from the desktop (faster iteration)

One-time activation on the desktop:

```sh
cd ~/nixos-config
nh os switch .                # registers qemu-aarch64 via binfmt_misc
sudo systemctl restart systemd-binfmt   # ...or just reboot
```

Then iterate from the desktop without ever entering the VM:

```sh
nix build .#nixosConfigurations.m2.config.system.build.toplevel
```

Substitutes pull from `cache.nixos.org`'s aarch64-linux channel for the bulk
of the closure; only your custom derivations (`blender-bin`, the wrapper
scripts, `noctalia` if uncached) build locally under QEMU emulation.

### Option B — Build natively inside the VM (faster per-build once running)

1. Download the minimal **aarch64** NixOS ISO from https://nixos.org/download/
2. UTM → New VM → Virtualize → ARM64 → 4 GB+ RAM, 30 GB+ disk, share the
   `nixos-config` repo via the UTM sparse directory share.
3. Boot the ISO, partition `/dev/vda`:
   ```sh
   parted /dev/vda -- mklabel gpt
   parted /dev/vda -- mkpart ESP fat32 1MB 512MB
   parted /dev/vda -- set 1 esp on
   parted /dev/vda -- mkpart primary 512MB 100%
   mkfs.fat -n ESP   /dev/vda1
   mkfs.ext4 -L root /dev/vda2
   mount /dev/disk/by-partlabel/root /mnt
   mkdir -p /mnt/boot && mount /dev/disk/by-partlabel/ESP /mnt/boot
   ```
4. Install from the flake:
   ```sh
   nixos-install --flake .#m2 --root /mnt
   ```
   The placeholder filesystem in `hosts/m2/hardware-configuration.nix`
   uses `by-partlabel` matching the labels above, so it boots first try.
   Once running, you can replace it with `nixos-generate-config` output for
   exact kernel-module matching.

### Notes specific to the M2 guest

- Sway runs against virtio-gpu + Mesa. No `--unsupported-gpu`, no
  `VK_ICD_FILENAMES` pinning, but `WLR_NO_HARDWARE_CURSORS=1` (set in
  `hosts/m2/configuration.nix`) — virtio-gpu's HW cursor is flaky.
- **ComfyUI** runs CPU-only via `scripts.nix#comfyui-portable` (no PRIME,
  no cupy, no CUDA env). Workable for small models; not for production.
- **Blender** is stock `pkgs.blender` from nixpkgs (the prebuilt x86_64
  tarball is NVIDIA + x86_64 only).
- **No `bazecor`, `davinci-resolve`, `vivaldi** — upstream ships no aarch64
  binaries. Use Vivaldi on the Mac host instead.

## Local LLM inference (llama.cpp)

Every host ships `pkgs.llama-cpp` and a user-level systemd service
(`llama.service`) that auto-starts at login. It's **loopback-only** — never
exposes inference to the LAN (matters on corp / VPN / conference networks).

Models aren't in the flake (per-arch quants, multi-GB, can't be rebuilt from
source). Convention:

```sh
mkdir -p ~/.local/share/models
# Drop any GGUF you want as the default at:
#   ~/.local/share/models/default.gguf
# Then enable the service:
systemctl --user enable --now llama
```

If no model is present, the service exits cleanly (no restart loop). Probe
the API once it's up:

```sh
curl http://127.0.0.1:8080/v1/chat/completions -d '{
  "model": "default",
  "messages": [{"role":"user","content":"hello"}]
}'
```

Override the model or port per-host with a drop-in:

```sh
systemctl --user edit llama
# [Service]
# Environment="LLAMA_MODEL=/data/models/qwen2.5-coder-7b.Q4_K_M.gguf"
# Environment="LLAMA_PORT=8081"
```

The CPU build is what ships by default — fine on every host including the M2.
NVIDIA hosts that want CUDA inference can override `pkgs.llama-cpp` via an
overlay later.

## What's included

- **Shell**: zsh (vi-mode, fzf-tab, syntax highlighting, CLIP aliases), starship prompt
- **Compositor**: Sway with Noctalia (panel, launcher, notifications, theme switching)
- **Terminal**: foot (server mode, Kanagawa dark/light palettes, live theme switch)
- **Editors**: zed, helix, vim, micro
- **Dev**: cargo, uv, python3, gh, git, gitbutler, podman, direnv, opencode
- **Media**: blender (prebuilt CUDA on NVIDIA, stock nixpkgs elsewhere), davinci-resolve (x86_64 only), obs-studio
- **Diffusion**: ComfyUI via comfy-cli (CUDA launcher on NVIDIA, portable CPU launcher on M2)
- **Local LLM**: llama.cpp (loopback-only, auto-starts when a model is dropped in)
- **Tools**: ripgrep, fd, fzf, tmux, yt-dlp, ffmpeg, aria2, timg, and more
