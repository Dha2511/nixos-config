# Work desktop NixOS guest: x86_64, KVM/QEMU (virt-manager) on an Ubuntu host,
# with an NVIDIA GPU passed through to the guest via vfio-pci.
#
# Unlike the laptop (NVIDIA + Intel hybrid, NVIDIA hidden for RTD3), here
# NVIDIA is the PRIMARY GPU of the guest — Sway renders on it, CUDA workloads
# (ComfyUI, Blender) target it directly, and nothing hides its ICDs. There is
# no PRIME offload because there's no second GPU to offload from.
#
# Only the VM/GPU specifics live here — locale, fonts, user, Sway baseline,
# portals, nix.settings, GC, etc. all come from hosts/_common/default.nix.
#
# =============================================================================
# HOST-SIDE PREREQUISITES (on the Ubuntu host — NOT managed by this flake).
# The guest config below is correct, but the GPU will NOT appear in the guest
# until these are done on the host:
#
#   1. Enable IOMMU in the host BIOS AND kernel:
#        - BIOS: Intel VT-d / AMD-Vi on
#        - kernel cmdline: intel_iommu=on iommu=pt (Intel) or amd_iommu=on iommu=pt (AMD)
#   2. Isolate the GPU (and its audio sibling) with vfio-pci. Get the PCI IDs
#      (`lspci -nn | grep -i nvidia`) and add to /etc/modprobe.d/vfio.conf:
#        options vfio-pci ids=10de:<gpu>,10de:<audio>
#      and to /etc/initramfs-tools/modules: vfio_pci, vfio, vfio_iommu_type1,
#      vfio_virqfd. Then `sudo update-initramfs -u && sudo reboot`.
#   3. In virt-manager, attach the GPU as PCI host devices (both the VGA and
#      Audio functions), use OVMF (UEFI), Q35 machine type, and the
#      `x-vga=on` flag on the GPU so it's the guest's primary display.
#   4. (Optional but recommended) extract and supply a clean GPU ROM via the
#      `<rom file='...'>` libvirt element if the card's built-in ROM objects
#      to running under a hypervisor (common with some GTX/RTX cards).
#
# After the GPU shows up inside the guest (`lspci | grep -i nvidia` and
# `nvidia-smi`), this config will pick it up automatically.
# =============================================================================

{ config, pkgs, ... }:

{
  imports = [
    ../_common/default.nix
    ./hardware-configuration.nix # template — regenerate with nixos-generate-config inside the VM
  ];

  networking.hostName = "desk";

  # --- Boot (UEFI via OVMF in QEMU) ---
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 0;

  # NVIDIA kernel modules in the main system (NOT initrd — same rationale as
  # the laptop: keep early boot simple in the VM). fbdev + modeset are needed
  # for a usable Wayland session on the passed-through GPU.
  boot.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" ];
  boot.kernelParams = [
    "nvidia-drm.fbdev=1"
    "nvidia-drm.modeset=1"
  ];

  # --- GPU: NVIDIA as the PRIMARY (sole) GPU of the guest ---
  # No PRIME hybrid, no RTD3 fine-grained PM (the GPU has no host power-management
  # path through vfio), no session ICD hiding. Sway renders on NVIDIA directly.
  hardware.graphics.enable = true;

  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true; # required for Wayland
    powerManagement.enable = true; # handles suspend/resume of the VM
    open = false; # proprietary kernel module
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };

  # Sway on the NVIDIA proprietary driver. No WLR_DRM_DEVICES pinning — if the
  # GPU is the only DRM device in the guest there's nothing to disambiguate; if
  # a virtio-gpu console is also present, set WLR_DRM_DEVICES to the NVIDIA node
  # here once you know its /dev/dri path inside the VM.
  programs.sway.extraOptions = [ "--unsupported-gpu" ]; # required for NVIDIA proprietary

  # 3Dconnexion SpaceMouse Wireless (256f:c63a) for RoboManipBaselines
  # teleop. pyspacemouse/easyhid opens the device via /dev/hidraw*, which is
  # root-only by default unless a udev rule grants access.
  services.udev.extraRules = ''
    KERNEL=="hidraw*", ATTRS{idVendor}=="256f", ATTRS{idProduct}=="c63a", MODE="0666"
  '';

  # QEMU guest agent: lets virt-manager request clean shutdown, read the guest
  # IP, and sync the clock. Harmless if the agent isn't installed on the host.
  services.qemuGuest.enable = true;

  # Same dev-tool baseline as the laptop, minus the HP printing stack (a work
  # desktop VM rarely needs a local printer backend). Add CUPS here later if
  # you want to print from the VM.
  environment.systemPackages = with pkgs; [
    git
    gh
    nh
    aria2
    curl
    wget
    podman
    gnutar
    unzip
    wl-clipboard
    jq
    libnotify
    gsettings-desktop-schemas
    nmap
  ];

  system.stateVersion = "26.05";
}
