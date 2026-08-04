{ config, pkgs, lib, inputs, noctalia-pkg, isNixOS, username, homeDirectory, isNvidia, hostName, ... }:

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

  # Scripts with host-aware variants (NVIDIA vs portable ComfyUI; prebuilt
  # x86_64 Blender vs stock pkgs.blender; Ubuntu-only PRIME offload wrapper).
  # isNixOS is needed inside scripts.nix to pick the right NVIDIA lib path:
  # /run/opengl-driver/lib on NixOS vs /usr/lib/x86_64-linux-gnu on Ubuntu.
  # Getting this wrong produces "symbol lookup error" from prebuilt binaries.
  scripts = import ./scripts.nix { inherit pkgs lib isNixOS; };

  # Per-host variant selection. NVIDIA hosts get the CUDA-pinned launchers;
  # everyone else (M2 VM, future AMD/Intel-only machines) gets the portable
  # versions. Both variants install a binary named `comfyui`, so desktop
  # entries / muscle memory don't differ across hosts.
  comfyuiScript = if isNvidia then scripts.comfyui else scripts.comfyui-portable;
  blenderPackage = if isNvidia then scripts.blender-bin else pkgs.blender;
  isx86_64 = pkgs.stdenv.hostPlatform.isx86_64;
in {
  imports = [ ./sway.nix ];

  # On Ubuntu, GDM doesn't source shell profiles (~/.profile, /etc/profile.d/)
  # when launching Wayland sessions, so ~/.nix-profile/bin isn't on PATH.
  # systemd reads ~/.config/environment.d/*.conf for all user sessions — this
  # makes noctalia, hooks, and all nix-installed binaries visible to Sway.
  # Harmless on NixOS (paths are already on PATH there).
  xdg.configFile."environment.d/nix.conf".text = ''
    PATH=${config.home.homeDirectory}/.nix-profile/bin:/nix/var/nix/profiles/default/bin:''${PATH}
    XDG_DATA_DIRS=${config.home.homeDirectory}/.nix-profile/share:''${XDG_DATA_DIRS}
    XCURSOR_PATH=${config.home.homeDirectory}/.local/share/icons:''${XCURSOR_PATH}
    XCURSOR_THEME=phinger-cursors-dark
    XCURSOR_SIZE=24
  '';

  home.username = username;
  home.homeDirectory = homeDirectory;
  home.stateVersion = "26.05";

  # Put uv-installed CLI tools (e.g. comfy-cli from comfyui-bootstrap) on PATH.
  home.sessionPath = [ "${config.home.homeDirectory}/.local/bin" ];

  # Cursor: phinger (dark baseline). GTK/env/legacy-xcursor are wired here; the
  # live compositor cursor is swapped by the `cursor-sync-theme` hook above and
  # the `seat * xcursor_theme` line in the Sway config (home/sway.nix).
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
    shell=zsh
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
  # the server (and on NVIDIA laptops, lets the dGPU re-suspend via RTD3).
  # The `comfyui` binary dispatched here is the CUDA-pinned launcher on NVIDIA
  # hosts and the portable CPU launcher on the M2 — same name, same entry.
  # The web UI is at http://localhost:8188 once it's up.
  xdg.desktopEntries.comfyui = {
    name = "ComfyUI";
    genericName = "Diffusion Model Studio";
    comment = "Node-based diffusion GUI";
    exec = "foot -- comfyui";
    terminal = false;
    type = "Application";
    categories = [ "Graphics" "AudioVideo" ];
  };

  # Two ways to launch the SAME Blender binary on NVIDIA laptops: plain
  # (Intel iGPU + CPU Cycles, battery-friendly) and via `nvidia-offload`
  # (viewport + Cycles CUDA/OptiX on the RTX dGPU; RTD3 re-suspends it on
  # quit). The plain entry shadows the packaged blender.desktop and claims
  # the .blend mimetype as the default. On the M2 VM (no NVIDIA, no Intel
  # hybrid), only the plain entry exists — `blender-nvidia` is gated below.
  xdg.desktopEntries.blender = {
    name = "Blender";
    genericName = "3D Modeling Suite";
    comment = if isNvidia then
      "Viewport on Intel iGPU, Cycles on CPU (battery-friendly)"
    else
      "CPU viewport + Cycles";
    exec = "blender %F";
    icon = "blender";
    terminal = false;
    type = "Application";
    categories = [ "Graphics" "3DGraphics" ];
    mimeType = [ "application/x-blender" ];
  };

  # NVIDIA-only entry: PRIME-offloaded Blender (viewport + CUDA/OptiX on the
  # dGPU). Gated by mkIf so the option is entirely absent on non-NVIDIA hosts
  # (e.g. the M2 VM) — no broken .desktop symlink in ~/.local/share/applications.
  xdg.desktopEntries.blender-nvidia = lib.mkIf isNvidia {
    name = "Blender (NVIDIA GPU)";
    genericName = "3D Modeling Suite";
    comment = "Viewport + Cycles CUDA/OptiX on the RTX 3050 dGPU";
    exec = "nvidia-offload blender %F";
    icon = "blender";
    terminal = false;
    type = "Application";
    categories = [ "Graphics" "3DGraphics" ];
  };

  # Local llama.cpp inference server (loopback only). Auto-starts at login;
  # exits cleanly (no spin) if no model is present at the default path, so
  # it's safe to ship enabled everywhere. Override per-host with environment
  # directives (e.g. `systemctl --user edit llama` to set LLAMA_MODEL/PORT).
  # Strongly bound to 127.0.0.1 — never exposes inference to the LAN, which
  # matters on work machines connected to untrusted networks (corp Wi-Fi,
  # VPN, eduroam, conference nets).
  systemd.user.services.llama = {
    Unit = {
      Description = "Local llama.cpp inference server (loopback only)";
      Documentation = "https://github.com/ggerganov/llama.cpp/tree/master/tools/server";
    };
    Service = {
      ExecStart = "${scripts.llama-serve}/bin/llama-serve";
      Restart = "on-failure";
      RestartSec = 10;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };

  home.packages = [
    # GUI
    pkgs.zed-editor
    pkgs.helix
    pkgs.vim
    blenderPackage
    pkgs.typst
    pkgs.prusa-slicer

    # Multimedia / apps
    pkgs.obs-studio
    pkgs.loupe
    scripts.stirling-pdf-wrapped
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
    pkgs.libnotify

    # Fonts (also installed system-wide on NixOS via configuration.nix;
    # duplicated here so Ubuntu gets them via the home profile)
    pkgs.nerd-fonts.commit-mono
    pkgs.nerd-fonts.departure-mono
    pkgs.lexend
    pkgs.noto-fonts
    pkgs.noto-fonts-cjk-sans
    pkgs.noto-fonts-color-emoji
    pkgs.atkinson-hyperlegible-mono
    pkgs.atkinson-hyperlegible-next
    pkgs.hubot-sans
    pkgs.mona-sans
    pkgs.alegreya
    pkgs.alegreya-sans
    pkgs.fraunces
    pkgs.recursive

    # Noctalia (shell + panel + notification daemon)
    noctalia-pkg

    # Drives the phinger light/dark cursor swap, the freedesktop color-scheme
    # (for Vivaldi/Chromium), and the in-process foot theme switch on toggle.
    cursor-sync-theme
    color-scheme-sync
    foot-sync-theme

    # ComfyUI launcher + one-time bootstrap (comfy-cli-managed install).
    # NVIDIA hosts pull the CUDA variant automatically via comfyuiScript.
    comfyuiScript
    scripts.comfyui-bootstrap

    # Local LLM inference (llama.cpp). Provides `llama-cli`, `llama-server`,
    # etc. directly; the auto-starting user service is wired above. CPU
    # build — works on every host including the M2 VM. NVIDIA hosts that
    # want CUDA inference can override via an overlay later.
    pkgs.llama-cpp
  ] ++ lib.optionals (isNvidia && !isNixOS) [
    # Ubuntu + NVIDIA: simplified PRIME offload (NixOS has the full version
    # in system packages). On the M2 VM (no NVIDIA) there's nothing to offload.
    scripts.nvidia-offload-ubuntu
  ] ++ lib.optionals isx86_64 [
    # x86_64-only. Upstream doesn't ship aarch64 binaries for these.
    # bazecor (Dygma keyboard configurator), davinci-resolve (Blackmagic),
    # vivaldi (proprietary Chromium fork). The M2 VM skips all three.
    pkgs.bazecor
    pkgs.davinci-resolve
    pkgs.vivaldi
  ];

  # Enable fontconfig so home-profile fonts are visible to GUI apps.
  fonts.fontconfig.enable = true;

  # direnv — auto-loads devShells on `cd` into a flake repo.
  # nix-direnv caches `nix develop` results so entry is instant after the first.
  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };

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
}
