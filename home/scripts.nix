{ pkgs, lib, isNvidia }:

let
  # Where libcuda.so.1 and the NVIDIA GL dispatch libs live on NixOS: the
  # opengl-driver symlink tree. Unused on non-NVIDIA hosts (M2 VM) — see
  # comfyui-portable below.
  nvidiaLibs = "/run/opengl-driver/lib";

  comfyui-host-libs = pkgs.buildEnv {
    name = "comfyui-host-libs";
    paths = [ pkgs.libx11 pkgs.libxext pkgs.libxcb pkgs.libxau pkgs.libxdmcp pkgs.libglvnd pkgs.glib.out pkgs.zlib ];
  };

  # NVIDIA-only ComfyUI launcher. Pins the dGPU via PRIME offload, preloads
  # the GL dispatch libs ComfyUI's bundled python expects, and ensures
  # cupy-cuda13x is present (required by GMFSS Fortuna VFI). Used on the two
  # NVIDIA hosts: the laptop (RTX 3050 hybrid) and the desk VM (passthrough).
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
        # Blender's lib/ MUST come first in LD_LIBRARY_PATH: libembree4.so.4
        # (NEEDED on libtbb.so.12) is resolved via the loader search path, not
        # via libembree4's own RUNPATH (DT_RUNPATH isn't transitive).
        # nvidiaLibs (/run/opengl-driver/lib) has no libtbb anyway, but putting
        # $out/libexec/blender/lib first guarantees the bundled, matching libtbb
        # wins for any future lib on that path.
        makeWrapper $out/libexec/blender/blender $out/bin/blender \
          --prefix LD_LIBRARY_PATH : $out/libexec/blender/lib:${nvidiaLibs}:${pkgs.lib.makeLibraryPath runtimeDeps}
        runHook postInstall
      '';
      meta.mainProgram = "blender";
    };

  # Unsloth Studio env. Sources from the launcher wrappers to give the
  # installer's bundled python the libs it needs. On NVIDIA hosts it also puts
  # the driver libs (/run/opengl-driver/lib) on the loader path so torch can
  # dlopen libcuda.so.1 — without this a CUDA torch still reports "no GPU".
  # (Sourced as `source <...>/bin/unsloth-env`, so it's a plain env script,
  # not meant to be run standalone.)
  unsloth-env = pkgs.writeShellScriptBin "unsloth-env" ''
    export SSL_CERT_FILE="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"
    export NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-$SSL_CERT_FILE}"
    export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.openssl.out}/lib:${pkgs.zlib}/lib${lib.optionalString isNvidia ":${nvidiaLibs}"}''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export NIX_LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.openssl.out}/lib:${pkgs.zlib}/lib${lib.optionalString isNvidia ":${nvidiaLibs}"}''${NIX_LD_LIBRARY_PATH:+:$NIX_LD_LIBRARY_PATH}"
  '';

  # One-time Unsloth Studio installer. Runs unsloth's own install.sh (into
  # ~/.unsloth/studio, symlinked as ~/.local/bin/unsloth). On NVIDIA hosts it
  # then swaps the CPU torch install.sh drops in for the CUDA build matching
  # the driver (cu130) — a CPU torch shows up as "CPU training backend (no
  # GPU)" even with a working NVIDIA driver — and ensures the bundled
  # llama.cpp is the CUDA build so GGUF inference also lands on the GPU.
  # Re-running updates all three steps. Web UI at http://127.0.0.1:8888 once
  # launched.
  unsloth-bootstrap = pkgs.writeShellScriptBin "unsloth-bootstrap" ''
    set -e
    source ${unsloth-env}/bin/unsloth-env
    if [ -x "$HOME/.local/bin/unsloth" ]; then
      echo "Unsloth Studio is already installed — re-running to update it." >&2
    fi
    curl -fsSL https://unsloth.ai/install.sh | UNSLOTH_SKIP_AUTOSTART=1 sh
    ${lib.optionalString isNvidia ''
    # Swap CPU torch (installed by install.sh) for the CUDA build matching the
    # NVIDIA driver. Only torch needs the swap — the cu130 index has no
    # torchvision/torchaudio for the 2.10 line, and their CPU builds pair fine
    # with it. Pin +cu130 so pip replaces +cpu rather than treating them as
    # the same version.
    ${pkgs.uv}/bin/uv pip install --python "$HOME/.unsloth/studio/unsloth_studio/bin/python" \
      --index-url https://download.pytorch.org/whl/cu130 \
      torch==2.10.0+cu130

    # Ensure the bundled llama.cpp is the CUDA build. The studio's installer
    # auto-routes by torch.cuda.is_available(), but only for a fresh install —
    # an existing CPU bundle (e.g. installed before the cu130 torch swap) is
    # kept as-is and would keep serving GGUF on the CPU. Reinstall via the
    # studio's own installer when the marker does not already show a CUDA
    # bundle. unsloth-env (sourced above) provides the SSL cert and
    # libstdc++/libssl LD_LIBRARY_PATH entries the installer's preflight needs
    # on NixOS.
    PY="$HOME/.unsloth/studio/unsloth_studio/bin/python"
    PROFILE="$($PY -c 'import json, os; p = os.path.expanduser("~/.unsloth/llama.cpp/UNSLOTH_PREBUILT_INFO.json"); print(json.load(open(p))["bundle_profile"])' 2>/dev/null || echo none)"
    case "$PROFILE" in
      cuda*) echo "llama.cpp CUDA bundle present ($PROFILE)." >&2 ;;
      *)
        INSTALLER="$($PY -c 'import studio.install_llama_prebuilt as m; print(m.__file__)' 2>/dev/null || true)"
        if [ -n "$INSTALLER" ]; then
          echo "Installing llama.cpp CUDA bundle (current: $PROFILE)..." >&2
          "$PY" "$INSTALLER" --install-dir "$HOME/.unsloth/llama.cpp" \
            --llama-tag latest --published-repo unslothai/llama.cpp || \
            echo "warning: llama.cpp CUDA install failed; Studio will retry on first model load." >&2
        else
          echo "warning: could not locate the llama.cpp installer; Studio will install on first model load." >&2
        fi
        ;;
    esac
    ''}
    echo "Done. Launch with: unsloth-studio  (web UI at http://127.0.0.1:8888)"
  '';

  # Unsloth Studio launcher. Loopback only — never exposes the server to the
  # LAN. Sources unsloth-env (NVIDIA libs on GPU hosts) and execs the
  # installer's CLI; the desktop entry dispatches here so launcher launches
  # get the GPU env too. Override flags can be appended after `--`.
  unsloth-studio = pkgs.writeShellScriptBin "unsloth-studio" ''
    if [ ! -x "$HOME/.local/bin/unsloth" ]; then
      echo "Unsloth Studio is not installed yet." >&2
      echo "Run unsloth-bootstrap first, then relaunch." >&2
      exit 1
    fi
    source ${unsloth-env}/bin/unsloth-env
    exec "$HOME/.local/bin/unsloth" studio -H 127.0.0.1 -p 8888 "$@"
  '';
in {
  inherit comfyui comfyui-portable comfyui-bootstrap stirling-pdf-wrapped blender-bin unsloth-env unsloth-bootstrap unsloth-studio;
}
