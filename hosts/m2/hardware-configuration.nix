# Hardware template for the M2 NixOS-in-UTM (aarch64-linux) guest.
#
# This is a SENSIBLE DEFAULT for the standard UTM layout (UEFI + virtio-blk
# disk at /dev/vda, 512 MB ESP + ext4 root). Once the VM is installed and
# booted, run `nixos-generate-config --dir /tmp/m2-config` inside the guest
# and replace this file with the generated `hardware-configuration.nix` to
# pick up the exact initrd modules and (if you've changed them) filesystem
# UUIDs. The file system UUIDs below are placeholder zeros — systemd-boot
# mounts by label/partlabel so it boots regardless, but `tune2fs -L` /
# `mkfs.ext4 -L` should match if you keep the labels.

{ lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # virtio drivers needed in the initrd to find the root disk and the
  # virtio-gpu framebuffer. xhci_pci + usbhid cover UTM's USB-translated
  # keyboard/tablet input so you have a working console early.
  boot.initrd.availableKernelModules = [
    "virtio_blk" "virtio_pci" "virtio_net" "virtio_console" "virtio_rng"
    "virtio_gpu"
    "xhci_pci" "usbhid" "usb_storage"
  ];
  boot.initrd.kernelModules = [ "virtio_gpu" ];   # early KMS for clean fbcon
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # UEFI systemd-boot needs vfat. Root is plain ext4 (no LUKS/TPM in the VM
  # — disk encryption, if ever wanted, should use Apple's host-level FileVault
  # on the UTM .utm bundle, not guest-side LUKS).
  boot.supportedFilesystems = [ "ext4" "vfat" ];

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/root";
    fsType = "ext4";
    options = [ "relatime" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/ESP";
    fsType = "vfat";
    options = [ "umask=0077" ];   # ESP is world-readable by default; lock it
  };

  # UTM exposes a single virtio-gpu DRM device at /dev/dri/card0. No ICD
  # pinning needed (no NVIDIA / Intel split to disambiguate) — Mesa is the
  # only loader.
  hardware.graphics.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
