# Baseline shared by every NixOS host (nixos / m2 / desk).
#
# Everything that is identical across machines lives here so the per-host
# configuration.nix files only describe what actually differs: bootloader,
# kernel/GPU, hostname, and host-specific services (HP printing on the laptop,
# virtio/NVIDIA-passthrough on desk, etc.).
#
# NixOS merges list-valued options across modules, so a host can both import
# this and append its own entries (e.g. extra fonts, extra user groups) without
# clobbering the shared defaults.

{ lib, pkgs, ... }:

{
  networking.networkmanager.enable = true;

  time.timeZone = "Asia/Tokyo";

  # English UI, Danish regional formats (dates / numbers / currency) — keeps
  # every machine feeling identical regardless of arch.
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

  console.keyMap = "us";

  # Custom Graphite keyboard layout (group 1; US+altgr-intl stays group 0).
  # ../../xkb/graphite resolves to <repo-root>/xkb/graphite from here, same as
  # it did from each host dir (hosts/<host>/ is the same depth as hosts/_common/).
  services.xserver.xkb = {
    layout = "us,graphite";
    variant = "altgr-intl,";
    extraLayouts.graphite = {
      description = "Graphite (intl., with AltGr dead keys)";
      languages = [ "eng" ];
      symbolsFile = ../../xkb/graphite;
    };
  };

  # User account — same username everywhere so the home-manager module lands at
  # /home/bob and ~/.config matches across machines. Hosts that need extra
  # groups (laptop: lp/lpadmin/scanner) just append to extraGroups.
  users.users.bob = {
    isNormalUser = true;
    description = "Bob";
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.zsh;
  };

  nixpkgs.config.allowUnfree = true;

  # zsh as a login shell. Prompt / plugins / keybinds come from home-manager.
  programs.zsh.enable = true;

  # Sway baseline. Hosts add their own extraOptions / extraSessionCommands
  # (laptop: --unsupported-gpu + Intel-only WLR_DRM_DEVICES; m2:
  # WLR_NO_HARDWARE_CURSORS; desk: --unsupported-gpu for NVIDIA passthrough).
  programs.sway.enable = true;
  programs.sway.wrapperFeatures.gtk = true;

  # Make Electron / Chromium apps use Wayland.
  environment.variables.NIXOS_OZONE_WL = "1";

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

  # Audio (PipeWire). Noctalia's volume hooks expect WirePlumber running.
  # Hosts with Bluetooth (laptop) layer their own wireplumber codec config on top.
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # dconf (D-Bus settings store) — Noctalia's color-scheme-sync hook writes the
  # freedesktop color-scheme here so Chromium-based apps follow light/dark mode.
  programs.dconf.enable = true;

  # XDG desktop portal. gtk = FileChooser/AppChooser; wlr = the wlroots backend
  # that lets the portal detect the Sway session at all + ScreenCast/Screenshot.
  # Without wlr the gtk FileChooser never fires on Sway (file pickers do nothing).
  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = false; # keep Vivaldi's own link handling
    extraPortals = [ pkgs.xdg-desktop-portal-gtk pkgs.xdg-desktop-portal-wlr ];
    config.common.default = [ "gtk" "wlr" ];
  };

  # nix-ld: lets prebuilt binaries downloaded by uv/pip/etc. run.
  programs.nix-ld.enable = true;

  # zram (zstd) — cheap RAM-backed swap, useful on every host (especially the
  # RAM-constrained VMs).
  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  # Common Nix settings. The noctalia substituter MUST use the public key
  # published by the noctalia cachix (https://app.cachix.org/api/v1/cache/noctalia)
  # — a single wrong character here silently invalidates every noctalia path
  # signature and forces a from-source rebuild (the "noctalia won't use the
  # cache" failure mode).
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true; # hardlink-dedup on every build
    extra-substituters = [ "https://noctalia.cachix.org" ];
    extra-trusted-public-keys = [
      "noctalia.cachix.org-1:pCOR47nnMEo5thcxNDtzWpOxNFQsBRglJzxWPp3dkU4="
    ];

    # Authenticate GitHub REST calls so `nix flake update` doesn't hit the
    # 60 req/hr anonymous rate limit. Reads a token you drop at
    # /etc/nix/github-token (NOT in the repo — gitignored by being outside it):
    #   gh auth token | sudo tee /etc/nix/github-token && sudo chmod 600 $_
    # The `if` is lazy in its branches, so builtins.readFile only fires when the
    # file actually exists — hosts without the token still evaluate cleanly.
    access-tokens =
      if builtins.pathExists /etc/nix/github-token
      then [ "github.com=${lib.fileContents /etc/nix/github-token}" ]
      else [ ];
  };

  # Weekly GC: drop generations older than 14 days. Persistent lets missed runs
  # (suspended/asleep) catch up.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Periodic full optimise pass (complements auto-optimise-store).
  nix.optimise.automatic = true;
}
