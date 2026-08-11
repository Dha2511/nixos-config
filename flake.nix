{
  description = "Portable NixOS config (laptop + 2 VMs)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Noctalia pinned to its `cachix` branch and NOT following our nixpkgs.
    # The cachix branch only ever points at commits already built & pushed to
    # the noctalia binary cache (https://noctalia.cachix.org), and the absence
    # of `follows` means noctalia evaluates against the nixpkgs it was built
    # against — so the cache keys match and binaries download instead of
    # compiling from source (the wireplumber-0.5 build failure). The cache +
    # public key themselves are wired in hosts/_common/default.nix.
    noctalia.url = "github:noctalia-dev/noctalia/cachix";
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
      mkNixos =
        { system
        , hostName
        , username ? "bob"
        , homeDirectory ? "/home/${username}"
        , isNvidia
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
              home-manager.extraSpecialArgs = {
                inherit inputs username homeDirectory isNvidia hostName;
                noctalia-pkg = noctalia.packages.${system}.default;
              };
              home-manager.users.${username} = import ./home;
            }
          ];
        };
    in
    {
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
        };
      };
    };
}
