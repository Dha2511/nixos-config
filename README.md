# nixos-config

Portable NixOS + home-manager configuration. One flake, two outputs:
identical dev environment (shell, Sway, Noctalia, editors, tools) on both
NixOS and any Linux distro (Ubuntu, Fedora, Arch, etc.) via standalone
home-manager.

## Structure

```
nixos-config/
├── flake.nix                  # two outputs: nixos + homeConfigurations.bob
├── hosts/nixos/               # NixOS-only system config
│   ├── configuration.nix      # boot, NVIDIA, networking, services, etc.
│   └── hardware-configuration.nix  # disk UUIDs + kernel modules (machine-specific)
├── home/                      # shared, distro-agnostic home-manager module
│   ├── default.nix            # packages, zsh, starship, cursor, fonts, direnv
│   ├── sway.nix               # Sway config + Noctalia keybinds (xdg.configFile)
│   └── scripts.nix            # ComfyUI, Blender, nvidia-offload (isNixOS guards)
└── xkb/graphite               # custom Graphite keyboard layout
```

## NixOS (full system)

```sh
nh os switch .
```

## Ubuntu / any Linux (home-manager standalone)

One-time setup:

```sh
# 1. Install Nix (Determinate Systems installer)
curl -fsSL https://install.determinate.systems/nix | sh -s -- install

# 2. Install sway + deps that must come from the system package manager
sudo apt install sway wmenu foot wl-clipboard grim jq libnotify dconf-cli

# 3. (Optional) NVIDIA driver for CUDA / ComfyUI
sudo ubuntu-drivers autoinstall && sudo reboot

# 4. Clone and apply
git clone https://github.com/Dha2511/nixos-config.git ~/nixos-config
cd ~/nixos-config
nix run home-manager -- switch --flake .#bob

# 5. Git auth (one-time)
gh auth login

# 6. Set zsh as login shell (foot already uses it via foot.ini, but this
#    also covers SSH sessions and other terminals)
chsh -s $(which zsh)
```

Log out, pick **Sway** at the login screen gear icon.

> **Note:** Nix packages are additive — they sit alongside system packages in
> PATH. `apt`, `snap`, `pip`, etc. all continue to work normally. No isolation.

Update later:

```sh
cd ~/nixos-config && git pull && nix run home-manager -- switch --flake .#bob
```

## What's included

- **Shell**: zsh (vi-mode, fzf-tab, syntax highlighting, CLIP aliases), starship prompt
- **Compositor**: Sway with Noctalia (panel, launcher, notifications, theme switching)
- **Terminal**: foot (server mode, Kanagawa dark/light palettes, live theme switch)
- **Editors**: zed, helix, vim, micro
- **Dev**: cargo, uv, python3, gh, git, gitbutler, podman, direnv, opencode
- **Media**: blender (prebuilt, CUDA-capable), davinci-resolve, obs-studio
- **Tools**: ripgrep, fd, fzf, tmux, yt-dlp, ffmpeg, aria2, timg, and more
