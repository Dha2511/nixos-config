# Baseline for display-carrying hosts (nixos / m2 / desk): base + graphical.
#
# Headless hosts (lab) import ./base.nix DIRECTLY instead of this file, so the
# compositor / audio / fonts / portal stack is never in their closure.

{ lib, pkgs, ... }:

{
  imports = [
    ./base.nix
    ./graphical.nix
  ];
}
