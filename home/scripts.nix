{ pkgs, lib, isNixOS }:

let
  # Where libcuda.so.1 and the NVIDIA GL dispatch libs live. On NixOS it's
  # the opengl-driver symlink tree; on Ubuntu it's the multiarch directory
  # where the `nvidia-driver` package drops libGL / libcuda / libnvidia-*
  # symlinks. Pointing LD_LIBRARY_PATH at the wrong one here is what
  # produces the "symbol lookup error" / "cannot open shared object" noise
  # from prebuilt binaries like Blender — keep this conditional.
  # Unused on non-NVIDIA hosts (M2 VM) — see comfyui-portable below.
  nvidiaLibs = if isNixOS then "/run/opengl-driver/lib" else "/usr/lib/x86_64-linux-gnu";

  comfyui-host-libs = pkgs.buildEnv {
    name = "comfyui-host-libs";
    paths = [ pkgs.libx11 pkgs.libxext pkgs.libxcb pkgs.libxau pkgs.libxdmcp pkgs.libglvnd pkgs.glib.out pkgs.zlib ];
  };

  # NVIDIA-only ComfyUI launcher. Pins the dGPU via PRIME offload, preloads
  # the GL dispatch libs ComfyUI's bundled python expects, and ensures
  # cupy-cuda13x is present (required by GMFSS Fortuna VFI). Use this on the
  # desktop (RTX 3050) and the work Ubuntu (RTX 4090).
  comfyui = pkgs.writeShellScriptBin "comfyui" ''
    cd ~/comfy/ComfyUI 2>/dev/null || {
      echo "ComfyUI workspace not found at ~/comfy/ComfyUI." >&2
      echo "Run comfyui-bootstrap first." >&2
      exit 1
    }
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export __VK_LAYER_NV_optimus=NVIDIA_only
    export LD_LIBRARY_PATH="${nvidiaLibs}:${pkgs.stdenv.cc.cc.lib}/lib:${comfyui-host-libs}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export NIX_LD_LIBRARY_PATH="${nvidiaLibs}:${pkgs.stdenv.cc.cc.lib}/lib:${comfyui-host-libs}/lib''${NIX_LD_LIBRARY_PATH:+:$NIX_LD_LIBRARY_PATH}"
    export TRITON_LIBCUDA_PATH="${nvidiaLibs}"
    export PYTORCH_CUDA_ALLOC_CONF="expandable_segments:True"
    export WINDOW_EGL=0
    export LD_PRELOAD="${comfyui-host-libs}/lib/libGLdispatch.so.0''${LD_PRELOAD:+:$LD_PRELOAD}"
    export CC="${pkgs.stdenv.cc}/bin/cc"
    export PATH="${pkgs.stdenv.cc}/bin:$PATH"
    if ! .venv/bin/python -c "import importlib.util, sys; sys.exit(0 if importlib.util.find_spec('cupy') else 1)" 2>/dev/null; then
      echo "Installing cupy-cuda13x for GMFSS Fortuna VFI..." >&2
      uv pip install --python "$HOME/comfy/ComfyUI/.venv/bin/python" cupy-cuda13x || true
    fi
    exec comfy launch "$@"
  '';

  # Portable ComfyUI launcher. No NVIDIA env, no cupy, no PRIME — PyTorch
  # detects what's available (CPU on the M2 aarch64 VM; CUDA on NVIDIA hosts
  # if PyTorch was installed with CUDA support). Slower than the NVIDIA path
  # but works everywhere comfy-cli runs.
  comfyui-portable = pkgs.writeShellScriptBin "comfyui" ''
    cd ~/comfy/ComfyUI 2>/dev/null || {
      echo "ComfyUI workspace not found at ~/comfy/ComfyUI." >&2
      echo "Run comfyui-bootstrap first." >&2
      exit 1
    }
    # Keep Mesa's libGL dispatch on the loader path so bundled python wheels
    # don't try to dlopen system nvidia libs that don't exist on this host.
    export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib:${comfyui-host-libs}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export NIX_LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib:${comfyui-host-libs}/lib''${NIX_LD_LIBRARY_PATH:+:$NIX_LD_LIBRARY_PATH}"
    export CC="${pkgs.stdenv.cc}/bin/cc"
    export PATH="${pkgs.stdenv.cc}/bin:$PATH"
    exec comfy launch "$@"
  '';

  comfyui-bootstrap = pkgs.writeShellScriptBin "comfyui-bootstrap" ''
    set -e
    mkdir -p ~/comfy/ComfyUI
    uv tool install comfy-cli
    cd ~/comfy/ComfyUI
    comfy install
    echo "Done. Launch with: comfyui  (models go in ~/comfy/ComfyUI/models; web UI at http://localhost:8188)"
  '';

  stirling-pdf-wrapped = pkgs.symlinkJoin {
    name = "stirling-pdf-wrapped";
    paths = [ pkgs.stirling-pdf-desktop ];
    nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
    postBuild = ''
      wrapProgram $out/bin/stirling-pdf \
        --set WEBKIT_DISABLE_DMABUF_RENDERER 1 \
        --prefix GST_PLUGIN_SYSTEM_PATH_1_0 : "${pkgs.gst_all_1.gst-plugins-base}/lib/gstreamer-1.0"
    '';
  };

  # Prebuilt x86_64 Blender with NVIDIA libs wired in for CUDA/OptiX Cycles.
  # NVIDIA + x86_64 only — the M2 (aarch64, no NVIDIA) uses stock
  # pkgs.blender from nixpkgs instead, which has an aarch64 build.
  blender-bin =
    let
      version = "5.2.0";
      runtimeDeps = with pkgs; [
        wayland libdecor libxkbcommon libGLU libglvnd numactl SDL2 libdrm
        ocl-icd stdenv.cc.cc.lib openal alsa-lib pulseaudio vulkan-loader zlib
        libx11 libxi libxxf86vm libxfixes libxrender libsm libice
      ];
    in
    pkgs.stdenv.mkDerivation {
      pname = "blender-bin";
      inherit version;
      src = pkgs.fetchurl {
        url = "https://download.blender.org/release/Blender5.2/blender-${version}-linux-x64.tar.xz";
        sha256 = "96f6c181a30f4950607839dc84d42a354b250d8a0231b098b59b7bc69c351c48";
      };
      nativeBuildInputs = [ pkgs.makeWrapper pkgs.patchelf ];
      dontUnpack = true;
      installPhase = ''
        runHook preInstall
        mkdir -p $out/libexec
        tar -xf $src -C $out/libexec
        cd $out/libexec && mv blender-* blender
        mkdir -p $out/bin $out/share/applications $out/share/icons/hicolor/scalable/apps
        mv blender/blender.desktop $out/share/applications/
        mv blender/blender.svg     $out/share/icons/hicolor/scalable/apps/ 2>/dev/null || true
        patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" blender/blender
        patchelf --set-interpreter "$(cat $NIX_CC/nix-support/dynamic-linker)" blender/*/python/bin/python3* 2>/dev/null || true
        makeWrapper $out/libexec/blender/blender $out/bin/blender \
          --prefix LD_LIBRARY_PATH : ${nvidiaLibs}:${pkgs.lib.makeLibraryPath runtimeDeps}
        runHook postInstall
      '';
      meta.mainProgram = "blender";
    };

  # Ubuntu + NVIDIA only: simplified PRIME offload (no VK_ICD override
  # needed — Ubuntu doesn't pin the loader the way the NixOS desktop does).
  # On NixOS the full wrapper lives in hosts/nixos/configuration.nix (it
  # needs config.hardware.nvidia.package which is only available in the
  # NixOS eval). On the M2 (no NVIDIA) there's nothing to offload to.
  nvidia-offload-ubuntu = pkgs.writeShellScriptBin "nvidia-offload" ''
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    exec "$@"
  '';

  # llama.cpp launcher (used by the systemd user service below). Loopback
  # only — never exposes inference to the LAN (work machines on untrusted
  # networks). If no model is present, exits 0 so systemd doesn't spin on
  # Restart=on-failure. Override the model with $LLAMA_MODEL, port with
  # $LLAMA_PORT, and pass extra llama-server flags after `--`.
  #
  # GGUFs don't belong in the flake (per-arch quants, 0.5–8 GB each, can't
  # be rebuilt from source). Drop one at the default path or set LLAMA_MODEL.
  llama-serve = pkgs.writeShellScriptBin "llama-serve" ''
    model="''${LLAMA_MODEL:-$HOME/.local/share/models/default.gguf}"
    if [ ! -f "$model" ]; then
      echo "llama-serve: no model at $model — staying down." >&2
      echo "Drop a GGUF there, or set LLAMA_MODEL, then: systemctl --user restart llama" >&2
      exit 0
    fi
    exec ${pkgs.llama-cpp}/bin/llama-server \
      --host 127.0.0.1 \
      --port "''${LLAMA_PORT:-8080}" \
      --model "$model" \
      "$@"
  '';
in {
  inherit comfyui comfyui-portable comfyui-bootstrap stirling-pdf-wrapped blender-bin nvidia-offload-ubuntu llama-serve;
}
