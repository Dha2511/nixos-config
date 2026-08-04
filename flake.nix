{
  description = "Portable NixOS / home-manager config";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    noctalia = {
      url = "github:noctalia-dev/noctalia";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, noctalia, ... }@inputs:
    let
      # Per-host capability flag. isNvidia controls whether the CUDA/PRIME
      # payload (ComfyUI with cupy-cuda13x, prebuilt x86_64 Blender,
      # nvidia-offload) is shipped; non-NVIDIA hosts get portable equivalents
      # (CPU/Vulkan ComfyUI, stock pkgs.blender) instead.
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
                isNixOS = true;
              };
              home-manager.users.${username} = import ./home;
            }
          ];
        };

      # Standalone home-manager output for non-NixOS Linux distros (Ubuntu).
      # homeDirectory defaults to /home/<username> — pass an override only for
      # unusual layouts (e.g. /var/home for silverblue).
      mkHome =
        { system ? "x86_64-linux"
        , username
        , homeDirectory ? "/home/${username}"
        , isNvidia
        }:
        home-manager.lib.homeManagerConfiguration {
          pkgs = nixpkgs.legacyPackages.${system};
          extraSpecialArgs = {
            inherit inputs username homeDirectory isNvidia;
            noctalia-pkg = noctalia.packages.${system}.default;
            isNixOS = false;
          };
          modules = [
            { nixpkgs.config.allowUnfree = true; }
            ./home
          ];
        };
    in
    {
      nixosConfigurations = {
        # Main desktop: MSI laptop, RTX 3050 Mobile + Intel iGPU hybrid.
        nixos = mkNixos {
          system = "x86_64-linux";
          hostName = "nixos";
          username = "bob";
          isNvidia = true;
        };

        # Apple Silicon M2 NixOS guest running in UTM (aarch64-linux,
        # virtio-gpu, no NVIDIA). Build cross from the desktop via
        # boot.binfmt.emulatedSystems, or natively from inside the VM after
        # `nixos-install` — see README for both paths.
        m2 = mkNixos {
          system = "aarch64-linux";
          hostName = "m2";
          username = "bob";
          isNvidia = false;
        };
      };

      homeConfigurations = {
        # Company Ubuntu laptop (user 'owner', RTX 4090). Standalone
        # home-manager — same shell/editor/dev-tool set as the NixOS desktop.
        owner = mkHome {
          username = "owner";
          isNvidia = true;
        };

        # Generic 'bob' standalone output. The NixOS desktop itself uses
        # nixosConfigurations.nixos (home-manager applied via the NixOS module),
        # so this entry is for any other machine where the user is 'bob' and
        # NixOS-as-the-host isn't desired. Kept for backwards compatibility
        # with the previous `.#bob` invocation documented in the README.
        bob = mkHome {
          username = "bob";
          isNvidia = true;
        };
      };
    };
}
