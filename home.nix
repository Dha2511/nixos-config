{ config, pkgs, inputs, ... }:
let
  # Noctalia runs this on launch (`started`) and on every light/dark switch
  # (`theme_mode_changed`). It reads the resolved mode and points Sway's seat
  # at the matching phinger variant, so the cursor is always the *opposite*
  # tone of the UI — visible on both light and dark backgrounds.
  cursor-sync-theme = pkgs.writeShellScriptBin "cursor-sync-theme" ''
    mode=$(noctalia msg theme-mode-get 2>/dev/null | tr -d '[:space:]')
    cur=phinger-cursors-dark
    [ "$mode" = "dark" ] && cur=phinger-cursors-light
    swaymsg "seat * xcursor_theme $cur 24" 2>/dev/null || true
  '';

  # Noctalia publishes its resolved mode via IPC but does not write the
  # freedesktop color-scheme that Chromium-based apps (Vivaldi) read to set
  # prefers-color-scheme (and, with "Use System Theme", their own chrome).
  # This hook mirrors the mode into dconf on startup and on every switch.
  color-scheme-sync = pkgs.writeShellScriptBin "color-scheme-sync" ''
    mode=$(noctalia msg theme-mode-get 2>/dev/null | tr -d '[:space:]')
    case "$mode" in
      dark)  dconf write /org/gnome/desktop/interface/color-scheme "'prefer-dark'"  2>/dev/null || true ;;
      light) dconf write /org/gnome/desktop/interface/color-scheme "'prefer-light'" 2>/dev/null || true ;;
    esac
  '';

  # Switches foot's native dark/light theme in-process by signaling the foot
  # server (SIGUSR1=dark, SIGUSR2=light). The server applies it to all clients
  # and sets the default for future clients — instant, no restart.
  foot-sync-theme = pkgs.writeShellScriptBin "foot-sync-theme" ''
    mode=$(noctalia msg theme-mode-get 2>/dev/null | tr -d '[:space:]')
    case "$mode" in
      dark)  ${pkgs.procps}/bin/pkill -USR1 -x foot 2>/dev/null || true ;;
      light) ${pkgs.procps}/bin/pkill -USR2 -x foot 2>/dev/null || true ;;
    esac
  '';

  # Union of host X11 shared libs that ComfyUI's bundled ANGLE (libGLESv2, used
  # by comfy_extras/nodes_glsl.py) dlopen-depends on but that NixOS keeps off
  # the default loader path. Collected into one /lib to keep the wrapper tidy.
  comfyui-host-libs = pkgs.buildEnv {
    name = "comfyui-host-libs";
    paths = [ pkgs.libx11 pkgs.libxext pkgs.libxcb pkgs.libxau pkgs.libxdmcp pkgs.libglvnd pkgs.glib.out pkgs.zlib ];
  };

  # ComfyUI launcher for the hybrid Intel + RTX 3050 (RTD3) setup.
  # Scopes NVIDIA PRIME offload to *this process only*: CUDA targets the dGPU
  # while the rest of the session stays on Mesa (the global Intel-only
  # Vulkan/EGL restriction in configuration.nix is left untouched). Launching
  # wakes the dGPU (RTD3 exits); quitting drops the runtime-PM ref so the GPU
  # re-suspends. The pip-installed PyTorch CUDA wheel bundles its own CUDA
  # runtime but still needs several host libs that NixOS keeps off the default
  # loader path, so we surface them all to both the nix-ld and regular linker
  # search paths:
  #   - libcuda.so.1 (driver, in /run/opengl-driver/lib)
  #   - libstdc++.so.6 + libgcc_s.so.1 (gcc lib output)
  #   - X11 libs libX11/libXext/libxcb/... (comfyui-host-libs) for the GLSL/ANGLE nodes
  # TRITON_LIBCUDA_PATH makes the Triton JIT skip its hardcoded /sbin/ldconfig
  # lookup (absent on NixOS) and go straight to libcuda. CC points the Triton
  # JIT at a working C compiler (it compiles a small driver shim at runtime):
  # NixOS has no `cc`/`gcc` on PATH, so we use the gcc-wrapper from stdenv,
  # which carries its own glibc headers + binutils (also put on PATH for `as`/`ld`).
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
    export LD_LIBRARY_PATH="/run/opengl-driver/lib:${pkgs.stdenv.cc.cc.lib}/lib:${comfyui-host-libs}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export NIX_LD_LIBRARY_PATH="/run/opengl-driver/lib:${pkgs.stdenv.cc.cc.lib}/lib:${comfyui-host-libs}/lib''${NIX_LD_LIBRARY_PATH:+:$NIX_LD_LIBRARY_PATH}"
    export TRITON_LIBCUDA_PATH="/run/opengl-driver/lib"
    # Depthflow (via shaderflow) forces an EGL backend by default (WINDOW_EGL=1),
    # but Mesa EGL can't initialize headless here: it chases the NVIDIA DRM device
    # through DRI2 and fails ("DRI2: failed to load driver" → eglInitialize 0x3001),
    # since Mesa has no DRI driver for NVIDIA. Disabling the flag makes shaderflow
    # pass backend=None, so moderngl falls back to its default GLX path on DISPLAY
    # (works fine — GL 3.3 via NVIDIA GLX, which is what the nodes request).
    export WINDOW_EGL=0
    # Pin the system libglvnd GL/EGL dispatch lib as the canonical
    # libGLdispatch.so.0 so bundled copies shipped inside some wheels (e.g.
    # imgui_bundle.libs, pulled in by shaderflow) can't shadow it. Defensive
    # hygiene for the GLX dispatch path moderngl now uses; harmless to cv2 and
    # comfy_angle.
    export LD_PRELOAD="${comfyui-host-libs}/lib/libGLdispatch.so.0''${LD_PRELOAD:+:$LD_PRELOAD}"
    export CC="${pkgs.stdenv.cc}/bin/cc"
    export PATH="${pkgs.stdenv.cc}/bin:$PATH"
    exec comfy launch "$@"
  '';

  # One-time provisioning of the comfy-cli-managed ComfyUI install (~/comfy/ComfyUI —
  # comfy-cli's default workspace path; it picks this itself, so we cd there).
  # Installs comfy-cli as a uv tool, then clones ComfyUI and builds a
  # CUDA-capable Python venv (pick NVIDIA when prompted). Re-runnable. The
  # install + models live outside the Nix store by design — ComfyUI releases
  # weekly and models are tens of GB; only the launcher and .desktop are tracked.
  comfyui-bootstrap = pkgs.writeShellScriptBin "comfyui-bootstrap" ''
    set -e
    mkdir -p ~/comfy/ComfyUI
    uv tool install comfy-cli
    cd ~/comfy/ComfyUI
    comfy install
    echo "Done. Launch with: comfyui  (models go in ~/comfy/ComfyUI/models; web UI at http://localhost:8188)"
  '';
in {
  home.username = "bob";
  home.homeDirectory = "/home/bob";

  # Put uv-installed CLI tools (e.g. comfy-cli from comfyui-bootstrap) on PATH.
  home.sessionPath = [ "${config.home.homeDirectory}/.local/bin" ];

  # Cursor: phinger (dark baseline). GTK/env/legacy-xcursor are wired here; the
  # live compositor cursor is swapped by the `cursor-sync-theme` hook above and
  # the `seat * xcursor_theme` line in the Sway config (configuration.nix).
  home.pointerCursor = {
    package = pkgs.phinger-cursors;
    name = "phinger-cursors-dark";
    size = 24;
    gtk.enable = true;
  };

  # Foot terminal (server mode). Both palettes are defined natively so foot
  # holds [colors-dark] and [colors-light] at once and can switch in-process via
  # SIGUSR1/SIGUSR2 — driven by the `foot-sync-theme` Noctalia hook — with no
  # restart and no reliance on foot's config file watcher.
  # Palettes are Kanagawa: Wave (dark) / Lotus (light), captured from Noctalia.
  xdg.configFile."foot/foot.ini".text = ''
    [main]
    font = CommitMono Nerd Font Mono:size=14

    initial-color-theme=dark

    [colors-dark]
    foreground=dcd7ba
    background=1f1f28
    regular0=090618
    regular1=c34043
    regular2=76946a
    regular3=c0a36e
    regular4=7e9cd8
    regular5=957fb8
    regular6=6a9589
    regular7=c8c093
    bright0=727169
    bright1=e82424
    bright2=98bb6c
    bright3=e6c384
    bright4=7fb4ca
    bright5=938aa9
    bright6=7aa89f
    bright7=dcd7ba
    selection-foreground=c8c093
    selection-background=2d4f67
    cursor=1f1f28 c8c093

    [colors-light]
    foreground=545464
    background=f2ecbc
    regular0=1f1f28
    regular1=c84053
    regular2=6f894e
    regular3=77713f
    regular4=4d699b
    regular5=b35b79
    regular6=597b75
    regular7=545464
    bright0=8a8980
    bright1=d7474b
    bright2=6e915f
    bright3=836f4a
    bright4=6693bf
    bright5=624c83
    bright6=5e857a
    bright7=43436c
    selection-foreground=f2ecbc
    selection-background=c9cbd1
    cursor=f2ecbc 43436c
  '';

  # Helix: use the noctalia theme file noctalia generates at
  # ~/.config/helix/themes/noctalia.toml. Helix doesn't live-reload themes —
  # run :config-reload (or restart) after a mode switch.
  xdg.configFile."helix/config.toml".text = ''
    theme = "noctalia"
  '';

  # Noctalia: swap the phinger cursor variant to match the active light/dark
  # mode. A partial user config deep-merges with Noctalia's built-in defaults
  # (verify with `noctalia config validate`).
  xdg.configFile."noctalia/config.toml".text = ''
    [hooks]
    started = [ "cursor-sync-theme", "color-scheme-sync", "foot-sync-theme" ]
    theme_mode_changed = [ "cursor-sync-theme", "color-scheme-sync", "foot-sync-theme" ]

    # Keep Noctalia's builtin foot template OFF so it doesn't rewrite
    # ~/.config/foot/foot.ini (it injected `include=.../themes/noctalia` and
    # recreated foot.ini as a regular file, clobbering home-manager's symlink and
    # aborting every `nh os switch`). home-manager owns foot.ini; live light/dark
    # switching still works via the foot-sync-theme SIGUSR1/2 hook. Only `helix`
    # stays Noctalia-managed (helix can't hot-reload themes).
    # CAVEAT: Noctalia layers ~/.local/state/noctalia/settings.toml (GUI-managed)
    # ABOVE this file, so if the Settings UI ever re-enables foot it wins — keep
    # the foot template off there too (or `rm settings.toml` to clear overrides).
    [theme.templates]
    builtin_ids = [ "helix" ]
  '';

  # Launcher entry so ComfyUI appears in wmenu / the Noctalia launcher.
  # Runs in a foot window so server logs are visible; closing the window stops
  # the server and lets the dGPU re-suspend (RTD3). The web UI is at
  # http://localhost:8188 once it's up.
  xdg.desktopEntries.comfyui = {
    name = "ComfyUI";
    genericName = "Diffusion Model Studio";
    comment = "Node-based diffusion GUI (runs on the NVIDIA dGPU)";
    exec = "foot -- comfyui";
    terminal = false;
    type = "Application";
    categories = [ "Graphics" "AudioVideo" ];
  };

  home.packages = [
    # GUI
    pkgs.zed-editor
    pkgs.helix
    pkgs.vim
    pkgs.blender
    pkgs.typst
    pkgs.bazecor
    pkgs.prusa-slicer

    # Multimedia / apps
    pkgs.davinci-resolve
    pkgs.obs-studio
    pkgs.loupe
    pkgs.stirling-pdf-desktop
    pkgs.zotero
    pkgs.anki
    pkgs.celluloid

    # CLI / Dev
    pkgs.micro
    pkgs.foot
    pkgs.cargo
    pkgs.uv
    pkgs.python3
    pkgs.git
    pkgs.gh
    pkgs.gitbutler
    pkgs.podman
    pkgs.opencode
    pkgs.starship

    # Online search
    pkgs.surfraw
    pkgs.ddgr
    pkgs.w3m
    pkgs.vivaldi

    # Utilities
    pkgs.aria2
    pkgs.curl
    pkgs.wget
    pkgs.timg
    pkgs.gnutar
    pkgs.unzip
    pkgs.tmux
    pkgs.ripgrep
    pkgs.ripgrep-all
    pkgs.fzf
    pkgs.fd
    pkgs.yt-dlp
    pkgs.ffmpeg

    # Drives the phinger light/dark cursor swap, the freedesktop color-scheme
    # (for Vivaldi/Chromium), and the in-process foot theme switch on toggle.
    cursor-sync-theme
    color-scheme-sync
    foot-sync-theme

    # ComfyUI launcher + one-time bootstrap (comfy-cli-managed install).
    comfyui
    comfyui-bootstrap
  ];

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autocd = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    # Login shell (.zprofile): auto-start Sway on tty1 when no compositor
    # is already running (works for both auto and manual tty1 login).
    profileExtra = ''
      if [ -z "$WAYLAND_DISPLAY" ] && [ "$XDG_VTNR" = 1 ]; then
        exec sway
      fi
    '';

    history = {
      size = 50000;
      save = 50000;
      ignoreDups = true;
      ignoreSpace = true;
      share = true;
      extended = true;
    };

    historySubstringSearch = {
      enable = true;
      searchUpKey = [ "^[[A" ];
      searchDownKey = [ "^[[B" ];
    };

    # Suffix-free substitution anywhere on the line.
    #   CLIP    stdout only             CLIPER   stdout + stderr
    #   CLIPT   stdout, last 50 lines   CLIPERT  stdout + stderr, last 50 lines
    # e.g. `ls CLIP` → `ls | wl-copy`
    #      `nh os switch . CLIPERT` → `nh os switch . 2>&1 | tail -n 50 | wl-copy`
    shellGlobalAliases = {
      CLIP = "| wl-copy";
      CLIPT = "| tail -n 50 | wl-copy";
      CLIPER = "2>&1 | wl-copy";
      CLIPERT = "2>&1 | tail -n 50 | wl-copy";
    };

    # zsh-vi-mode: vim normal/insert mode (Esc to toggle).
    # fzf-tab: fuzzy Tab completion (files, git refs, kills, options).
    plugins = [
      {
        name = "zsh-vi-mode";
        src = pkgs.zsh-vi-mode;
        file = "share/zsh-vi-mode/zsh-vi-mode.plugin.zsh";
      }
      {
        name = "fzf-tab";
        src = pkgs.zsh-fzf-tab;
        file = "share/fzf-tab/fzf-tab.plugin.zsh";
      }
    ];

    initContent = ''
      # Ctrl+Left / Ctrl+Right  — jump one word
      bindkey '^[[1;5D' backward-word
      bindkey '^[[1;5C' forward-word
      # Ctrl+Backspace / Ctrl+Delete — delete one word
      bindkey '^H'      backward-kill-word
      bindkey '^[[3;5~' kill-word

      # Home / End
      bindkey '^[[H' beginning-of-line
      bindkey '^[[F' end-of-line

      # Cursor shape: block in vi-normal mode, beam in insert mode.
      # Visual cue for which mode you're in (zsh-vi-mode is sourced earlier).
      zvm_config() {
        ZVM_CURSOR_STYLE_ENABLED=true
        ZVM_NORMAL_MODE_CURSOR=$ZVM_CURSOR_BLOCK
        ZVM_INSERT_MODE_CURSOR=$ZVM_CURSOR_BEAM
      }
    '';
  };

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      add_newline = false;
      format = ''
        [](fg:#8b8f96)$directory[](fg:#8b8f96 bg:#2a2d31)$git_branch$git_status[](fg:#2a2d31)$line_break$character'';

      directory = {
        fish_style_pwd_dir_length = 1;
        truncation_length = 3;
        truncation_symbol = "";
        style = "fg:#161616 bg:#8b8f96 bold";
        format = "[ $path ]($style)";
        repo_root_style = "fg:#161616 bg:#8b8f96 bold";
        repo_root_format = "[ $path ]($style)[$read_only]($read_only_style)";
      };

      git_branch = {
        symbol = "";
        style = "fg:#e5e7eb bg:#2a2d31";
        format = "[ $symbol$branch ]($style)";
      };

      git_status = {
        style = "fg:#e5e7eb bg:#2a2d31";
        format = "[$all_status$ahead_behind ]($style)";
      };

      character = {
        success_symbol = "[❯](bold green)";
        error_symbol = "[❯](bold red)";
      };
    };
  };

  home.stateVersion = "26.05";
}
