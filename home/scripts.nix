{ pkgs, lib, isNixOS }:

let
  # The only path that differs between NixOS and Ubuntu: where libcuda.so.1
  # and the NVIDIA GL dispatch libs live. On NixOS it's the opengl-driver
  # symlink tree; on Ubuntu it's the standard multiarch directory.
  nvidiaLibs = if isNixOS then "/run/opengl-driver/lib" else "/usr/lib/x86_64-linux-gnu";

  comfyui-host-libs = pkgs.buildEnv {
    name = "comfyui-host-libs";
    paths = [ pkgs.libx11 pkgs.libxext pkgs.libxcb pkgs.libxau pkgs.libxdmcp pkgs.libglvnd pkgs.glib.out pkgs.zlib ];
  };

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

  comfyui-bootstrap = pkgs.writeShellScriptBin "comfyui-bootstrap" ''
    set -e
    mkdir -p ~/comfy/ComfyUI
    uv tool install comfy-cli
    cd ~/comfy/ComfyUI
    comfy install
    uv pip install --python "$HOME/comfy/ComfyUI/.venv/bin/python" cupy-cuda13x \
      || echo "cupy install deferred — the comfyui launcher will retry on next launch."
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

  # Ubuntu-only: simplified PRIME offload (no VK_ICD override needed).
  # On NixOS the full wrapper lives in hosts/nixos/configuration.nix (it needs
  # config.hardware.nvidia.package which is only available in the NixOS eval).
  nvidia-offload-ubuntu = pkgs.writeShellScriptBin "nvidia-offload" ''
    export __NV_PRIME_RENDER_OFFLOAD=1
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    exec "$@"
  '';
in {
  inherit comfyui comfyui-bootstrap stirling-pdf-wrapped blender-bin nvidia-offload-ubuntu;
}
