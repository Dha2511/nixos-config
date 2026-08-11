# Hardware template for the desk NixOS-in-KVM guest (x86_64-linux).
#
# This is a SENSIBLE DEFAULT for the standard virt-manager layout (UEFI/OVMF +
# virtio-blk disk at /dev/vda, 512 MB ESP + ext4 root). Once the VM is installed
# and booted, run `nixos-generate-config --dir /tmp/desk-config` inside the
# guest and replace this file with the generated `hardware-configuration.nix`
# to pick up the exact initrd modules and (if you've changed them) filesystem
# UUIDs. The file system UUIDs below are placeholder zeros — systemd-boot
# mounts by label/partlabel so it boots regardless, but `tune2fs -L` /
# `mkfs.ext4 -L` should match if you keep the labels.

{ lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # virtio drivers needed in the initrd to find the root disk and the virtio
  # input devices virt-manager attaches by default. virtio_gpu gives a fallback
  # Spice console; the passed-through NVIDIA GPU appears as a separate PCI/DRM
  # device once vfio binds it on the host (see configuration.nix).
  boot.initrd.availableKernelModules = [
    "virtio_blk" "virtio_pci" "virtio_net" "virtio_console" "virtio_rng"
    "virtio_gpu"
    "xhci_pci" "usbhid" "usb_storage"
  ];
  boot.initrd.kernelModules = [ "virtio_gpu" ]; # early KMS for a clean console
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  # UEFI systemd-boot needs vfat. Root is plain ext4.
  boot.supportedFilesystems = [ "ext4" "vfat" ];

  fileSystems."/" = {
    device = "/dev/disk/by-partlabel/root";
    fsType = "ext4";
    options = [ "relatime" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-partlabel/ESP";
    fsType = "vfat";
    options = [ "umask=0077" ]; # ESP is world-readable by default; lock it
  };

  hardware.graphics.enable = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
