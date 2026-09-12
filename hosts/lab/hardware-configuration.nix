# PLACEHOLDER hardware configuration for lab.
#
# This file is a GUESS so the flake evaluates before the machine exists. It
# MUST be regenerated on the real hardware:
#
#   sudo nixos-generate-config --dir /tmp/config
#   # review, then copy over this file and rebuild
#
# Replace the label-based filesystem guesses below with the real
# /dev/disk/by-uuid entries the generator emits. Consider adding NVMe swap
# (zram from hosts/_common/base.nix alone will not cover 4x48GB inference
# spills) — e.g.:
#   swapDevices = [ { device = "/dev/disk/by-uuid/<swap-uuid>"; } ];

{ config, lib, modulesPath, ... }:

{
  imports = [
    "${modulesPath}/installer/scan/not-detected.nix"
  ];

  # TODO: fill from nixos-generate-config output (storage/HID controllers).
  boot.initrd.availableKernelModules = [ ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # PLACEHOLDER filesystems — label-based guesses, replace with real UUIDs.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/BOOT";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  # TODO: decide on NVMe swap for large-model headroom (see header comment).
  swapDevices = [ ];

  # Enables DHCP on each NIC, and wait-online is disabled by default.
  networking.useDHCP = lib.mkDefault true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.enableRedistributableFirmware = lib.mkDefault true;
}
