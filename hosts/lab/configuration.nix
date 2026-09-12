# lab — headless GPU compute box: x86_64, 4x NVIDIA RTX 6000 Ada (A6000 Ada).
#
# No display, no compositor, no audio, no fonts. SSH is the only way in; the
# server web UIs (ComfyUI :8188, Unsloth :8888) stay on loopback and are
# reached with `ssh -L` tunnels:
#   ssh -L 8188:localhost:8188 -L 8888:localhost:8888 bob@lab
#
# Everything terminal-shaped (locale, user, zsh, zram, nix settings, GC) comes
# from hosts/_common/base.nix — NOT ./default.nix, which would pull in the
# graphical layer (Sway, fonts, PipeWire, portals).
#
# =============================================================================
# MACHINE-SIDE PREREQUISITES (BIOS/board — NOT managed by this flake):
#   - Above-4G Decoding: REQUIRED with >2 NVIDIA GPUs (the 4 cards' BARs do
#     not fit under the 4 GB boundary otherwise; the cards may fail to POST).
#   - Resizable BAR: recommended (workstation boards expose it per-slot).
#   - PCIe topology: prefer x16 lanes per slot if the board allows it; x8/x4
#     riser slots throttle multi-GPU transfers (NCCL/P2P and model sharding).
#   - Power: 4x A6000 Ada = up to 1.2 kW of cards alone — size the PSUs.
# =============================================================================
# FIRST-BOOT TODO (before relying on SSH):
#   - Fill in users.users.bob.openssh.authorizedKeys.keys below (console login
#     is the fallback until then).
#   - Regenerate ./hardware-configuration.nix on the machine:
#       sudo nixos-generate-config --dir /tmp/config && review + copy
#     It is currently a PLACEHOLDER (label-based / and /boot guesses).

{ config, pkgs, ... }:

{
  imports = [
    ../_common/base.nix
    ./hardware-configuration.nix # PLACEHOLDER — regenerate on the machine
  ];

  networking.hostName = "lab";

  # --- Boot (UEFI assumed; switch to GRUB/lilo-less BIOS path if needed) ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = true;
  # Boot immediately — hold Space during boot to pick a previous generation.
  boot.loader.timeout = 0;

  # --- SSH: the only way in ---
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # TODO: add your public key(s) here before first headless boot. Console
  # (getty on tty1) still works for local rescue if this is left empty.
  users.users.bob.openssh.authorizedKeys.keys = [
    # "ssh-ed25519 AAAA... bob@laptop"
  ];

  # Lock the box down to SSH only. Every app server (ComfyUI, Unsloth, and
  # tabbyAPI when it lands) binds loopback and is reached via ssh -L tunnels —
  # nothing else needs an inbound port.
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  # --- GPU: 4x NVIDIA RTX 6000 Ada, display-less ---
  # Primary-GPU style (like the desk VM), minus everything display-related:
  # no PRIME offload, no WLR_DRM_DEVICES, no sway options, no ICD hiding.
  # CUDA/OptiX workloads talk to the driver directly via /run/opengl-driver.
  hardware.graphics.enable = true;

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    # modesetting stays at its default: it only matters for display outputs,
    # which this box has none of. Harmless either way.
    powerManagement.enable = true; # suspend/resume bookkeeping + NVreg_PreserveVideoMemoryAllocations
    # Persistence daemon: keeps all 4 GPUs initialized between jobs (headless
    # mode) so CUDA init latency and driver state churn don't tax every run.
    nvidiaPersistenced = true;
    nvidiaSettings = false; # GUI settings tool — nothing to point it at
    open = true; # Ada generation: open kernel module is NVIDIA's recommended path (flip to false if a workload misbehaves)
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Driver modules in the main system (not initrd — no early KMS needed
  # without a display; mirrors the laptop/desk approach).
  boot.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" ];

  # --- System packages (host-specific tools; home.packages carries the rest) ---
  environment.systemPackages = with pkgs; [
    nh # nix helper — `nh os switch` from the repo checkout
    jq
    pciutils # lspci — GPU topology / BAR / slot debugging on a 4-GPU box
  ];

  # This value determines the NixOS release from which the default settings for
  # stateful data were taken. Leave it at the version of the first install.
  system.stateVersion = "26.05";
}
