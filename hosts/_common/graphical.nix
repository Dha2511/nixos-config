# Graphical layer shared by every display-carrying host (nixos / m2 / desk).
#
# Keyboard/compositor/desktop-stack baseline on top of ./base.nix. Headless
# hosts (lab) import ONLY ./base.nix and skip everything here.

{ lib, pkgs, ... }:

{
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
}
