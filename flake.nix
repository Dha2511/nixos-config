{
  description = "Portable NixOS config (laptop + 2 VMs)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Noctalia pinned to its `cachix` branch with `inputs.nixpkgs.follows`
    # removed. Not following our nixpkgs lets noctalia evaluate against the
    # nixpkgs it was built against, so cache signatures *would* match and
    # binaries *could* download from noctalia.cachix.org (URL + key wired in
    # hosts/_common/default.nix). That's the intent — see the NOTE below for
    # why it currently still builds from source.
    #
    # NOTE: two problems currently force a from-source build anyway:
    #   1. noctalia.cachix.org serves no narinfo for any of the branch's revs
    #      (the CI workflow claims it pushed them, but they 404).
    #   2. noctalia's pinned nixpkgs (f13ff45) ships a 0-byte
    #      wireplumber-0.5.pc, so the meson check "Dependency wireplumber-0.5
    #      not found" fails at configure time. `wireplumberFix` below swaps in
    #      our nixpkgs' wireplumber (which has a valid .pc), fixing the build.
    noctalia.url = "github:noctalia-dev/noctalia/cachix";
    # Zen Browser (Firefox fork) — packaged via a community flake that tracks
    # upstream releases closely. Builds for x86_64-linux and aarch64-linux.
    zen-browser = {
      url = "github:youwen5/zen-browser-flake";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Local inference stack (tabbyAPI + Qwen3.8-27B). Source of truth for the
    # opencode provider config deployed via home/default.nix.
    llm-agent = {
      # git+https (not github:) so flake updates don't hit the GitHub API.
      url = "git+https://github.com/Dha2511/llm-agent";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, noctalia, ... }@inputs:
    let
      # Per-host capability flag. isNvidia controls whether the CUDA payload
      # (ComfyUI with cupy-cuda13x, prebuilt x86_64 Blender) is shipped;
      # non-NVIDIA hosts get portable equivalents (CPU/Vulkan ComfyUI, stock
      # pkgs.blender) instead.
      #
      # NOTE: isNvidia is a real per-host flag — do NOT derive it from
      # stdenv.hostPlatform.isx86_64. x86_64 ≠ NVIDIA (Intel/AMD-only x86
      # boxes and the aarch64 M2 VM all have isNvidia = false).
      # Workaround for noctalia's pinned nixpkgs shipping a 0-byte
      # wireplumber-0.5.pc (see input comment above). Overriding the package's
      # `wireplumber` callPackage arg with our nixpkgs' copy yields a valid
      # wireplumber-0.5.pc (our nixpkgs lock, 279b4a8, has a 449-byte one).
      wireplumberFix = system:
        noctalia.packages.${system}.default.override {
          wireplumber = nixpkgs.legacyPackages.${system}.wireplumber;
        };
      mkNixos =
        { system
        , hostName
        , username ? "bob"
        , homeDirectory ? "/home/${username}"
        , isNvidia
        # Host runs the llm-agent tabbyAPI server and gets its opencode provider
        # config deployed globally (see home/default.nix).
        , hasTabby ? false
        , extraModules ? [ ]
        }:
        nixpkgs.lib.nixosSystem {
          inherit system;
          specialArgs = { inherit inputs; };
          modules = extraModules ++ [
            ./hosts/${hostName}/configuration.nix
            home-manager.nixosModules.home-manager
            {
              home-manager.useGlobalPkgs = true;
              home-manager.useUserPackages = true;
              # Move conflicting non-managed files aside (e.g. a stale regular
              # ~/.config/sway/config) instead of failing activation.
              home-manager.backupFileExtension = ".hmbk";
              home-manager.extraSpecialArgs = {
                inherit inputs username homeDirectory isNvidia hostName hasTabby;
                noctalia-pkg = wireplumberFix system;
                gitbutler = gitbutlerPkg system;
              };
              home-manager.users.${username} = import ./home;
            }
          ];
        };

      # Package set for non-NixOS outputs (devShells). Imported separately
      # because flake outputs don't inherit NixOS-module config: the Android
      # SDK needs allowUnfree (android-sdk-cmdline-tools) and its license
      # accepted to even evaluate. Mirrors what hosts/_common sets via
      # nixpkgs.config, minus the host-only bits.
      pkgsFor = system: import nixpkgs {
        inherit system;
        config = {
          allowUnfree = true;
          android_sdk.accept_license = true;
        };
      };

      # GitButler CLI as a prebuilt binary (no source build). Exposed as a
      # flake `packages` output (for `nix build .#gitbutler`) and wired into the
      # home config via extraSpecialArgs below.
      #
      # FSL-1.1-MIT is marked unfree in nixpkgs, and this pkgs instance comes
      # from the flake input — the system-level `nixpkgs.config.allowUnfree =
      # true` (hosts/_common) applies to a different instance and never
      # reaches here. Import nixpkgs with the config set, like pkgsFor above.
      gitbutlerPkg = system:
        (import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        }).callPackage ./pkgs/gitbutler { };
    in
    {
      # GitButler CLI prebuilt — buildable standalone (nix build .#gitbutler)
      # without triggering a full host rebuild.
      packages.x86_64-linux.gitbutler = gitbutlerPkg "x86_64-linux";
      packages.aarch64-linux.gitbutler = gitbutlerPkg "aarch64-linux";

      # Flutter Android devShell — x86_64-only: Google ships Android SDK
      # linux binaries for x86_64 exclusively, so there is no aarch64 (M2)
      # variant to offer. Linux-desktop Flutter work needs no shell at all
      # (the toolchain lives in home.packages). See devshells/flutter-android.nix.
      devShells.x86_64-linux.flutter-android =
        import ./devshells/flutter-android.nix { pkgs = pkgsFor "x86_64-linux"; };

      nixosConfigurations = {
        # Main laptop: MSI, RTX 3050 Mobile + Intel iGPU hybrid.
        nixos = mkNixos {
          system = "x86_64-linux";
          hostName = "nixos";
          username = "bob";
          isNvidia = true;
        };

        # Work MacBook (Apple Silicon M2) NixOS guest in UTM (aarch64-linux,
        # virtio-gpu, no NVIDIA). Build cross from the laptop via
        # boot.binfmt.emulatedSystems, or natively inside the VM after
        # `nixos-install` — see README for both paths.
        m2 = mkNixos {
          system = "aarch64-linux";
          hostName = "m2";
          username = "bob";
          isNvidia = false;
        };

        # Work desktop NixOS guest in KVM/QEMU (x86_64-linux) on an Ubuntu host,
        # with an NVIDIA GPU passed through via vfio-pci. NVIDIA is the *primary*
        # GPU in the guest (not a PRIME hybrid like the laptop), so the config
        # exposes it directly rather than hiding it for RTD3. Host-side vfio
        # setup (IOMMU, GPU bind, ROM) is required and documented in the README.
        desk = mkNixos {
          system = "x86_64-linux";
          hostName = "desk";
          username = "bob";
          isNvidia = true;
          hasTabby = true;
        };
      };
    };
}
