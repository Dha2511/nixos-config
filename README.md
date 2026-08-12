# nixos-config

One flake, three NixOS targets — same shell, editor, keybinds, theme, and CLI
environment across all of them:

| Target | Hardware / arch | User | GPU | Flake output |
|---|---|---|---|---|
| MSI laptop | bare metal / x86_64 | `bob` | NVIDIA RTX 3050 + Intel iGPU (hybrid) | `.#nixosConfigurations.nixos` |
| Work MacBook | UTM guest / aarch64 | `bob` | virtio-gpu (no CUDA) | `.#nixosConfigurations.m2` |
| Work desktop | KVM/QEMU guest / x86_64 | `bob` | NVIDIA (vfio passthrough) | `.#nixosConfigurations.desk` |

The home-manager module under `home/` is shared verbatim across all three;
host differences (username, home dir, NVIDIA-ness, arch, hostname) are injected
as `extraSpecialArgs` from `flake.nix`. Everything identical between hosts
(locale, fonts, user, Sway baseline, portals, nix.settings, GC) is factored into
`hosts/_common/default.nix` so each `hosts/<name>/configuration.nix` only
describes what actually differs (bootloader, kernel, GPU, host-specific
services).

## Structure

```
nixos-config/
├── flake.nix                  # mkNixos helper; threads username, homeDirectory,
│                              # isNvidia, hostName through extraSpecialArgs.
│                              # Three outputs: nixos, m2, desk.
├── hosts/
│   ├── _common/default.nix    # shared baseline (locale, fonts, user, Sway,
│   │                          # portals, nix.settings + noctalia cache +
│   │                          # GitHub access-tokens, GC). Imported by every host.
│   ├── nixos/                 # MSI laptop (x86_64, NVIDIA hybrid, HP printing)
│   │   ├── configuration.nix
│   │   └── hardware-configuration.nix
│   ├── m2/                    # Apple Silicon UTM guest (aarch64, virtio)
│   │   ├── configuration.nix
│   │   └── hardware-configuration.nix
│   └── desk/                  # Work-desktop KVM guest (x86_64, NVIDIA passthrough)
│       ├── configuration.nix
│       └── hardware-configuration.nix
├── home/                      # shared home-manager module (all three hosts)
│   ├── default.nix            # packages, zsh, starship, cursor, fonts,
│   │                          # direnv, llama.cpp service, desktop entries
│   ├── sway.nix               # Sway config + Noctalia keybinds
│   └── scripts.nix            # ComfyUI (NVIDIA + portable), Blender prebuilt,
│                              # llama-serve launcher
└── xkb/graphite               # custom Graphite keyboard layout
```

## Hardware configs

Each `hosts/<name>/configuration.nix` imports its sibling
`hardware-configuration.nix`, and `flake.nix`'s `mkNixos` loads
`hosts/${hostName}/configuration.nix`. So the full chain is:
**flake → `configuration.nix` → sibling `hardware-configuration.nix`**.
That sibling is the only hardware-specific file per host — regenerating it with
`nixos-generate-config` and overwriting the committed copy is the complete
wiring (no other edits needed).

Current state of the committed configs:

- `nixos/` and `desk/` — **real** generated `hardware-configuration.nix`
  (UUIDs + detected initrd modules from those machines).
- `m2/` — a **template** using `by-partlabel` that matches the partition layout
  in the M2 install steps, so a fresh UTM install boots first-try. Regenerate
  and replace it after a real M2 install (exact kernel-module matching).

## Per-host flags (in `flake.nix`)

`mkNixos` threads these into the home module via `extraSpecialArgs`:

- `username` / `homeDirectory` — what they sound like.
- `isNvidia` — gates the CUDA payload (ComfyUI launcher with `cupy-cuda13x`,
  prebuilt x86_64 Blender with NVIDIA libs). Non-NVIDIA hosts (the M2 VM) get
  portable equivalents. **Do not** infer this from `isx86_64` — x86_64 ≠ NVIDIA
  (the desk VM is x86_64 + NVIDIA; the M2 is aarch64 + no NVIDIA).
- `hostName` — selects `hosts/${hostName}/`.

A handful of packages are gated separately by `pkgs.stdenv.hostPlatform.isx86_64`
(bazecor, davinci-resolve, vivaldi) because upstream doesn't ship aarch64
builds — the M2 skips those.

## Starting from an empty NixOS install

After `nixos-install` the fresh system boots into a minimal config with **no
flakes, no git, no `nh`**. To bootstrap the flake from that empty state:

```sh
# 1. Get git + nh into a temporary shell (they're not installed yet):
nix-shell -p git nh

# 2. Enable flakes for THIS shell session only, so you don't have to type
#    --option experimental-features over and over. After the first successful
#    `switch`, hosts/_common/default.nix sets experimental-features permanently
#    in /etc/nix/nix.conf and this line is no longer needed.
export NIX_CONFIG='extra-experimental-features = nix-command flakes'

# 3. Clone and switch (replace #nixos with #m2 or #desk on the other hosts):
git clone https://github.com/Dha2511/nixos-config.git ~/nixos-config
cd ~/nixos-config
sudo nh os switch .           # or: sudo nixos-rebuild switch --flake .#nixos
```

> The `NIX_CONFIG=...` env var feeds nix settings to a single process tree, so
> every `nix` / `nixos-rebuild` / `nh` invocation in that shell picks flakes up
> without extra flags. Run it once per fresh boot.

## Applying the config (any host)

Once bootstrapped, rebuild with whichever you prefer. `nh` is just a nicer
wrapper around `nixos-rebuild` (adds a build summary + diff, handles the sudo):

```sh
cd ~/nixos-config && git pull

# switch  — build + activate + add a boot generation (the normal one):
sudo nh os switch .                  # or: sudo nixos-rebuild switch --flake .#nixos

# test    — build + activate for THIS boot only, no new boot menu entry
#           (great for trying a risky change; reverts on reboot):
sudo nh os test .                    # or: sudo nixos-rebuild test --flake .#nixos

# build   — build only, no activation (what CI / verification uses):
nh os build .                        # or: nixos-rebuild build --flake .#nixos
```

For the other hosts, swap the output name: `.#m2` (MacBook VM, aarch64) or
`.#desk` (work-desktop VM, x86_64 + NVIDIA). Roll back by holding **Space**
during boot to enter the systemd-boot menu and picking a previous generation.

## One-time setup (every host)

```sh
# Authenticate GitHub REST calls so `nix flake update` / input fetches don't
# hit the 60 req/hr anonymous rate limit. hosts/_common/default.nix reads this
# file lazily (it's outside the repo, so it never gets committed):
gh auth token | sudo tee /etc/nix/github-token && sudo chmod 600 /etc/nix/github-token
```

(If the file is absent the config still evaluates cleanly — there's just no
rate-limit protection until you add it.)

## Target: M2 (work MacBook, UTM)

Two ways to build the aarch64 closure: cross-build from the laptop via
`boot.binfmt.emulatedSystems` (already configured in
`hosts/nixos/configuration.nix`), or natively inside the VM.

### Option A — Cross-build from the laptop (faster iteration)

One-time activation on the laptop:

```sh
cd ~/nixos-config
nh os switch .                # registers qemu-aarch64 via binfmt_misc
sudo systemctl restart systemd-binfmt   # ...or just reboot
```

Then iterate from the laptop without entering the VM:

```sh
nix build .#nixosConfigurations.m2.config.system.build.toplevel
```

Substitutes pull from `cache.nixos.org`'s aarch64-linux channel for the bulk of
the closure; only custom derivations build locally under QEMU emulation.

### Option B — Build natively inside the VM

1. Download the minimal **aarch64** NixOS ISO from https://nixos.org/download/
2. UTM → New VM → Virtualize → ARM64 → 4 GB+ RAM, 30 GB+ disk.
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
   The placeholder filesystem in `hosts/m2/hardware-configuration.nix` uses
   `by-partlabel` matching the labels above, so it boots first try. Once
   running, replace it with `nixos-generate-config` output for exact
   kernel-module matching.

### Notes specific to the M2 guest

- Sway runs against virtio-gpu + Mesa. No `--unsupported-gpu`, no ICD pinning,
  but `WLR_NO_HARDWARE_CURSORS=1` (set in `hosts/m2/configuration.nix`) —
  virtio-gpu's HW cursor is flaky.
- **ComfyUI** runs CPU-only via `scripts.nix#comfyui-portable`.
- **Blender** is stock `pkgs.blender` (the prebuilt x86_64 tarball is NVIDIA +
  x86_64 only).
- **No bazecor / davinci-resolve / vivaldi** — upstream ships no aarch64
  binaries. Use Vivaldi on the Mac host instead.

## Target: desk (work desktop, KVM/QEMU + NVIDIA passthrough)

This host runs NixOS inside a virt-manager VM on the Ubuntu work desktop, with
the host's NVIDIA GPU passed through to the guest via `vfio-pci`. NVIDIA is the
**primary** GPU in the guest (unlike the laptop's PRIME hybrid), so Sway renders
on it and CUDA workloads target it directly.

### Host-side prerequisites (on the Ubuntu host — NOT in this flake)

The guest config is correct, but the GPU won't appear inside the VM until these
are done on the host:

1. **IOMMU.** Enable Intel VT-d / AMD-Vi in BIOS, then on the host kernel
   cmdline: `intel_iommu=on iommu=pt` (Intel) or `amd_iommu=on iommu=pt` (AMD).
2. **Isolate the GPU.** Get the PCI IDs (`lspci -nn | grep -i nvidia` — note the
   GPU and its audio sibling), then:
   ```sh
   # /etc/modprobe.d/vfio.conf
   options vfio-pci ids=10de:<gpu>,10de:<audio>
   # /etc/initramfs-tools/modules
   vfio_pci
   vfio
   vfio_iommu_type1
   vfio_virqfd
   sudo update-initramfs -u && sudo reboot
   ```
3. **Attach in virt-manager.** OVMF (UEFI), Q35 machine type, add the GPU's PCI
   host devices (VGA + Audio functions), `x-vga=on` so it's the guest's primary
   display.
4. **(Optional) GPU ROM.** Some cards reject running under a hypervisor; supply
   a cleaned ROM via libvirt's `<rom file='...'>` if so.

### Install (same partition layout as the M2)

```sh
# Boot the minimal x86_64 NixOS ISO in the VM, then:
parted /dev/vda -- mklabel gpt
parted /dev/vda -- mkpart ESP fat32 1MB 512MB
parted /dev/vda -- set 1 esp on
parted /dev/vda -- mkpart primary 512MB 100%
mkfs.fat -n ESP   /dev/vda1
mkfs.ext4 -L root /dev/vda2
mount /dev/disk/by-partlabel/root /mnt
mkdir -p /mnt/boot && mount /dev/disk/by-partlabel/ESP /mnt/boot
nixos-install --flake .#desk --root /mnt
```

`hosts/desk/hardware-configuration.nix` is already the real generated file
(UUIDs + detected modules). If you reinstall the VM, regenerate it after first
boot for exact kernel-module matching:

```sh
nixos-generate-config --dir /tmp/desk-config   # copy its hardware-configuration.nix over the committed one
```

### Verify the GPU inside the guest

```sh
lspci | grep -i nvidia      # GPU visible?
nvidia-smi                  # driver loaded + CUDA ready?
```

If `nvidia-smi` is empty, the host-side vfio bind almost certainly didn't take
(check `dmesg | grep -i vfio` on the host). The NixOS side needs no change.

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

If no model is present the service exits cleanly (no restart loop). Probe the
API once it's up:

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

The CPU build ships by default — fine on every host including the M2. NVIDIA
hosts that want CUDA inference can override `pkgs.llama-cpp` via an overlay.

## Noctalia (desktop shell)

Noctalia is pinned to its **`cachix`** branch with `inputs.nixpkgs.follows`
**removed**. Not following our nixpkgs lets noctalia evaluate against the
nixpkgs it was built against, so cache signatures *would* match and binaries
*could* download from `noctalia.cachix.org` instead of compiling from source.
That's the intent; the cache URL + public key are wired in
`hosts/_common/default.nix`:

```
extra-substituters        = https://noctalia.cachix.org
extra-trusted-public-keys = noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4=
```

**Status (2026-08): the cache is currently empty.** No narinfo is served for
any of the branch's revs — the upstream CI workflow claims it pushes them, but
they all 404. On top of that, noctalia's pinned nixpkgs ships a **0-byte**
`wireplumber-0.5.pc`, which breaks the meson configure step
(`Dependency "wireplumber-0.5" not found, tried pkgconfig`). Until upstream
fixes both, noctalia always compiles from source; `flake.nix`'s `wireplumberFix`
overrides the package's `wireplumber` callPackage arg with our nixpkgs' copy
(which has a valid `.pc`) so the build succeeds. A from-source build is
therefore **expected**, not a sign of a misconfigured key.

If noctalia ever *silently* fails to substitute again, double-check that key
character-by-character against
https://app.cachix.org/api/v1/cache/noctalia — a single wrong character
silently invalidates every noctalia path.

## What's included

- **Shell**: zsh (vi-mode, fzf-tab, syntax highlighting, CLIP aliases), starship prompt
- **Compositor**: Sway with Noctalia (panel, launcher, notifications, theme switching)
- **Terminal**: foot (server mode, Kanagawa dark/light palettes, live theme switch)
- **Editors**: zed, helix, vim, micro
- **Dev**: cargo, uv, python3, gh, git, podman, direnv, opencode
- **Media**: blender (prebuilt CUDA on NVIDIA, stock nixpkgs elsewhere), davinci-resolve (x86_64 only), obs-studio
- **Diffusion**: ComfyUI via comfy-cli (CUDA launcher on NVIDIA, portable CPU launcher on M2)
- **Local LLM**: llama.cpp (loopback-only, auto-starts when a model is dropped in)
- **Tools**: ripgrep, fd, fzf, tmux, yt-dlp, ffmpeg, aria2, timg, and more
