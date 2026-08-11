# Work MacBook (Apple Silicon M2) NixOS guest in UTM.
#
# Target: aarch64-linux inside UTM (QEMU backend, virtio devices). No NVIDIA,
# no CUDA — just virtio-gpu + Mesa. ComfyUI / Blender here run CPU-only via the
# portable launcher / stock nixpkgs build selected in home/default.nix when
# isNvidia = false.
#
# Only the VM-specific bits live here — locale, fonts, user, Sway baseline,
# portals, nix.settings, GC, etc. all come from hosts/_common/default.nix.

{ config, pkgs, ... }:

{
  imports = [
    ../_common/default.nix
    ./hardware-configuration.nix
  ];

  networking.hostName = "m2";

  # Bootloader. UTM ships EDK2 UEFI firmware on aarch64, so systemd-boot works
  # the same as on bare-metal x86. timeout=0 → boot instantly, hold Space
  # during boot to open the systemd-boot menu (e.g. to roll back to a previous
  # generation if a switch fails to come up).
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 0;

  # SSH into the VM from the Mac host (port-forward localhost:2222 → 22 in UTM,
  # or use the VM's virbr0 address) for headless debugging and rsyncing the
  # flake in. Disabled by default — uncomment if wanted.
  # services.openssh.enable = true;
  # services.openssh.settings.PermitRootLogin = "no";

  # Sway against virtio-gpu. NO --unsupported-gpu (that flag is NVIDIA-only —
  # useless on virtio-gpu). virtio-gpu's hardware cursor is flaky under wlroots,
  # so disable it and let Sway render a software cursor instead.
  programs.sway.extraSessionCommands = ''
    export WLR_NO_HARDWARE_CURSORS=1
  '';

  # Essential VM tools. HP printing / fwupd / NVIDIA / Bluetooth are all omitted
  # (don't apply to a VM); the laptop ships those in its own configuration.nix.
  environment.systemPackages = with pkgs; [
    git
    gh
    nh
    curl
    wget
    vim
    wl-clipboard
    jq
    libnotify
    gsettings-desktop-schemas
  ];

  # tty1-only autologin (commented out — uncomment for kiosk-style boot
  # straight into Sway without typing the password; the zsh profileExtra in
  # home/default.nix then `exec sway`s on tty1 automatically).
  # systemd.services."getty@tty1".serviceConfig.ExecStart = [
  #   ""
  #   "@${pkgs.util-linux}/sbin/agetty --autologin bob --noclear %I $TERM"
  # ];

  system.stateVersion = "26.05";
}
