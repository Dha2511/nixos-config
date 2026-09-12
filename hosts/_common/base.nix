# Terminal-only baseline shared by every NixOS host (nixos / m2 / desk / lab).
#
# Everything that is identical across machines AND usable without a display
# lives here. Graphical-only bits (Sway, XKB layouts, fonts, PipeWire, portals,
# dconf) live in ./graphical.nix — a headless host (lab) imports ONLY this
# file; graphical hosts import ./default.nix which pulls in both.
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

  # nix-ld: lets prebuilt binaries downloaded by uv/pip/etc. run.
  programs.nix-ld.enable = true;

  # System-wide tooling. Hosts layer their own dev-tool baselines on top.
  environment.systemPackages = with pkgs; [
    usbutils # lsusb — list USB devices / decode bus+device info
  ];

  # zram (zstd) — cheap RAM-backed swap, useful on every host (especially the
  # RAM-constrained VMs).
  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  # Common Nix settings. The noctalia substituter public key MUST match the one
  # published by the noctalia cachix
  # (https://app.cachix.org/api/v1/cache/noctalia) — a single wrong character
  # silently invalidates every noctalia path signature.
  #
  # NOTE: the cache currently serves no binaries (every pushed path 404s), and
  # noctalia's pinned nixpkgs ships a 0-byte wireplumber-0.5.pc. noctalia
  # therefore compiles from source on every machine; flake.nix's
  # `wireplumberFix` swaps in our nixpkgs' wireplumber so that build succeeds.
  # A from-source build is expected, not a sign of a key typo.
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
