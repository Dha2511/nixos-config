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
    #
    # NOTE: two problems currently force a from-source build anyway:
    #   1. noctalia.cachix.org serves no narinfo for any of the branch's revs
    #      (the CI workflow claims it pushed them, but they 404).
    #   2. noctalia's pinned nixpkgs (f13ff45) ships a 0-byte
    #      wireplumber-0.5.pc, so the meson check "Dependency wireplumber-0.5
    #      not found" fails at configure time. `wireplumberFix` below swaps in
    #      our nixpkgs' wireplumber (which has a valid .pc), fixing the build.
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
                noctalia-pkg = wireplumberFix system;
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
