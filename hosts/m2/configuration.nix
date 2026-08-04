# NixOS configuration for the M2 (Apple Silicon) UTM guest.
#
# Target: aarch64-linux running inside UTM (QEMU backend, virtio devices).
# No NVIDIA, no CUDA, no Intel iGPU — just virtio-gpu + Mesa. ComfyUI /
# Blender here run CPU-only via the portable launcher / stock nixpkgs build
# selected in home/default.nix when isNvidia = false.

{ config, pkgs, ... }:

{
  imports =
    [ ./hardware-configuration.nix
    ];

  # Bootloader. UTM ships EDK2 UEFI firmware on aarch64, so systemd-boot
  # works the same as on bare-metal x86. timeout=0 → boot instantly, hold
  # Space during boot to open the systemd-boot menu (e.g. to roll back to
  # a previous generation if a switch fails to come up).
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 0;

  networking.hostName = "m2";
  networking.networkmanager.enable = true;

  # SSH into the VM from the Mac host (port-forward localhost:2222 → 22 in
  # UTM's settings, or use the VM's virbr0 address) for headless debugging
  # and `rsync`ing the flake in. Disabled by default — uncomment if wanted.
  # services.openssh.enable = true;
  # services.openssh.settings.PermitRootLogin = "no";

  time.timeZone = "Asia/Tokyo";

  # Match the desktop's locale scheme (English UI, Danish regional formats
  # for dates/numbers/currency — keeps the two machines feeling identical).
  i18n.defaultLocale = "en_DK.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS       = "da_DK.UTF-8";
    LC_IDENTIFICATION = "da_DK.UTF-8";
    LC_MEASUREMENT   = "da_DK.UTF-8";
    LC_MONETARY      = "da_DK.UTF-8";
    LC_NAME          = "da_DK.UTF-8";
    LC_NUMERIC       = "da_DK.UTF-8";
    LC_PAPER         = "da_DK.UTF-8";
    LC_TELEPHONE     = "da_DK.UTF-8";
    LC_TIME          = "da_DK.UTF-8";
  };

  # Custom Graphite keyboard layout (group 1; US+altgr-intl stays group 0).
  # Same import path as the desktop config: ../../xkb/graphite from here
  # resolves to <repo-root>/xkb/graphite.
  services.xserver.xkb = {
    layout = "us,graphite";
    variant = "altgr-intl,";
    extraLayouts.graphite = {
      description = "Graphite (intl., with AltGr dead keys)";
      languages = [ "eng" ];
      symbolsFile = ../../xkb/graphite;
    };
  };
  console.keyMap = "us";

  # User account — same username as the desktop so the home-manager module
  # lands at /home/bob and ~/.config matches across machines.
  users.users.bob = {
    isNormalUser = true;
    description = "Bob";
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.zsh;
  };

  nixpkgs.config.allowUnfree = true;

  programs.zsh.enable = true;

  # Sway. NO --unsupported-gpu (that flag is NVIDIA-proprietary-only — useless
  # on virtio-gpu, and would just print a warning). virtio-gpu's hardware
  # cursor is flaky under wlroots, so disable it and let Sway render a
  # software cursor instead.
  programs.sway.enable = true;
  programs.sway.wrapperFeatures.gtk = true;
  programs.sway.extraSessionCommands = ''
    export WLR_NO_HARDWARE_CURSORS=1
  '';

  # Sway config + Noctalia keybinds come from home-manager (home/sway.nix).

  # Electron/Chromium Wayland.
  environment.variables.NIXOS_OZONE_WL = "1";

  # Audio (PipeWire). Useful if you ever pass audio through virtio-snd; also
  # keeps the desktop experience identical (Noctalia's volume hooks expect
  # WirePlumber to be running).
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Bluetooth NOT enabled — UTM has no BT-passthrough by default. Add
  # `hardware.bluetooth.enable = true` only if you wire up an SPDK / HCI
  # passthrough to the Mac's adapter (rarely worth it; just use the Mac's BT).

  # Compressed RAM swap. The M2 VM is RAM-constrained (you set the allocation
  # in UTM's settings) — zram helps a lot when you oversubscribe it.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  # Essential system tools. The desktop's HP printing / scanning stack,
  # fwupd firmware updates, and NVIDIA-offload wrapper are all deliberately
  # omitted here — they don't apply to a VM.
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

  # Same font set as the desktop (home-manager also installs these into the
  # user profile; mirroring here means GTK/Qt pick them up before any user
  # logs in, e.g. at the login screen).
  fonts.packages = with pkgs; [
    nerd-fonts.commit-mono
    nerd-fonts.departure-mono
    lexend
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    atkinson-hyperlegible-mono
    atkinson-hyperlegible-next
    hubot-sans
    mona-sans
    alegreya
    alegreya-sans
    fraunces
    recursive
  ];

  # Run prebuilt binaries downloaded by uv/pip/etc.
  programs.nix-ld.enable = true;

  # dconf + XDG portal — same rationale as the desktop (Noctalia's
  # color-scheme-sync hook writes here, Chromium reads it). wlr is the
  # wlroots backend that lets the portal detect the Sway session and drive
  # FileChooser (file pickers) + ScreenCast; without it the gtk portal
  # alone never fully activates on Sway.
  programs.dconf.enable = true;
  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = false;
    extraPortals = [ pkgs.xdg-desktop-portal-gtk pkgs.xdg-desktop-portal-wlr ];
    config.common.default = [ "gtk" "wlr" ];
  };

  # Nix settings — match the desktop.
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  nix.optimise.automatic = true;

  # tty1-only autologin (commented out — uncomment for kiosk-style boot
  # straight into Sway without typing the password; the zsh profileExtra in
  # home/default.nix then `exec sway`s on tty1 automatically).
  # systemd.services."getty@tty1".serviceConfig.ExecStart = [
  #   ""
  #   "@${pkgs.util-linux}/sbin/agetty --autologin bob --noclear %I $TERM"
  # ];

  system.stateVersion = "26.05";
}
