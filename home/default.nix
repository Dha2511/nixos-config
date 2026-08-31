{ config, pkgs, lib, inputs, noctalia-pkg, username, homeDirectory, isNvidia, hostName, hasTabby, ... }:

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
  # x86_64 Blender vs stock pkgs.blender). All hosts are NixOS now, so the
  # NVIDIA lib path in scripts.nix is unconditionally /run/opengl-driver/lib.
  scripts = import ./scripts.nix { inherit pkgs lib isNvidia; };

  # Per-host variant selection. NVIDIA hosts get the CUDA-pinned launchers;
  # everyone else (M2 VM, future AMD/Intel-only machines) gets the portable
  # versions. Both variants install a binary named `comfyui`, so desktop
  # entries / muscle memory don't differ across hosts.
  comfyuiScript = if isNvidia then scripts.comfyui else scripts.comfyui-portable;
  blenderPackage = if isNvidia then scripts.blender-bin else pkgs.blender;
  isx86_64 = pkgs.stdenv.hostPlatform.isx86_64;

  # stirling-pdf-desktop (Tauri + Java) has had recurring upstream build
  # breakage ("Cannot wrap .../bin/stirling-pdf because it does not exist" =
  # the underlying Tauri build failed, not our wrapper). It's also x86_64-only
  # material (heavy, no aarch64 value on the M2). Flip this to true on x86_64
  # hosts once you've confirmed `nix build nixpkgs#stirling-pdf-desktop` works
  # on the current nixpkgs revision; leaving it false keeps a broken upstream
  # package from blocking every host's rebuild.
  stirlingEnabled = false;

  # Noctalia wallpaper, declaratively shipped from the repo (home/assets/cube.png)
  # to a stable managed path. The merged config.toml block below points Noctalia
  # at this exact file, so the wallpaper is reproducible across hosts/rebuilds
  # with no manual copy. `${wallpaperPath}` is interpolated into that block.
  wallpaper = ./assets/cube.png;
  wallpaperDir = "${homeDirectory}/.local/share/wallpapers";
  wallpaperPath = "${wallpaperDir}/cube.png";
in {
  imports = [ ./sway.nix ];

  home.username = username;
  home.homeDirectory = homeDirectory;
  home.stateVersion = "26.05";

  # Put uv-installed CLI tools (e.g. comfy-cli from comfyui-bootstrap) on PATH.
  home.sessionPath = [ "${config.home.homeDirectory}/.local/bin" ];

  # Cursor: phinger (dark baseline). `enable = true` is REQUIRED by current
  # home-manager — merely defining name/package/size no longer implicitly
  # enables cursor generation (it prints a deprecation warning otherwise).
  # gtk.enable sets gtk.cursorTheme from these values; the live compositor
  # cursor is swapped by the `cursor-sync-theme` hook + the `seat *
  # xcursor_theme` line in the Sway config (home/sway.nix).
  home.pointerCursor = {
    enable = true;
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

  # opencode global config on hosts running the local tabbyAPI server. The
  # file's source of truth is the llm-agent repo (opencode.json, exposed as
  # packages.opencode-config); editing it there + `nh os switch` updates this.
  # Registers the TabbyAPI provider so tabby/Qwen3.8-27B-exl3 is selectable
  # from every repo; small_model is left to opencode's primary-model fallback.
  xdg.configFile."opencode/opencode.json" = lib.mkIf hasTabby {
    source = inputs.llm-agent.packages.${pkgs.system}.opencode-config + "/opencode.json";
  };

  # Noctalia config — FULLY DECLARATIVE. This block is the single source of
  # truth: it deep-merges with Noctalia's built-in defaults, and the former
  # GUI-managed override layer (~/.local/state/noctalia/settings.toml) is now
  # pinned to an empty read-only file (see home.file below) so the Settings UI
  # can no longer shadow anything here. Verify with `noctalia config validate`.
  # The keys below the `--- migrated ---` marker were lifted verbatim from that
  # settings.toml; the three wallpaper `path` keys were rewritten to point at
  # the repo-managed wallpaper (see `wallpaperPath` in the let-block).
  xdg.configFile."noctalia/config.toml".text = ''
    [hooks]
    started = [ "cursor-sync-theme", "color-scheme-sync", "foot-sync-theme" ]
    theme_mode_changed = [ "cursor-sync-theme", "color-scheme-sync", "foot-sync-theme" ]

    # Keep Noctalia's builtin foot template OFF so it doesn't rewrite
    # ~/.config/foot/foot.ini (it injected `include=.../themes/noctalia` and
    # recreated foot.ini as a regular file, clobbering home-manager's symlink
    # and aborting every `nh os switch`). home-manager owns foot.ini; live
    # light/dark switching still works via the foot-sync-theme SIGUSR1/2 hook.
    # Only `helix` stays Noctalia-managed (helix can't hot-reload themes).
    [theme.templates]
    builtin_ids = [ "helix" ]

    # ---- migrated from ~/.local/state/noctalia/settings.toml ---------------

    [bar.default]
    center = [ "clock", "spacer_2", "date", "spacer_2", "weather" ]
    end = [
        "media",
        "notifications",
        "clipboard",
        "network",
        "bluetooth",
        "volume",
        "brightness",
        "spacer_2",
        "session",
        "battery"
    ]
    margin_edge = 0
    margin_ends = 0
    position = "bottom"
    radius = 0
    shadow = false
    start = [ "workspaces", "screenshot" ]

    [battery]
    warning_threshold = 20

    [calendar]
    enabled = true

        [calendar.account.personal_google]
        name = "Personal"
        type = "google"

    [dock]
    auto_hide = true
    icon_size = 24
    shadow = false
    show_dots = true

    [idle]
    behavior_order = [ "lock", "screen-off", "lock-and-suspend" ]

        [idle.behavior.lock]
        action = "lock"
        enabled = false
        timeout = 600.0

        [idle.behavior.lock-and-suspend]
        action = "lock_and_suspend"
        enabled = false
        timeout = 900.0

        [idle.behavior.screen-off]
        action = "screen_off"
        enabled = true
        timeout = 600.0

    [location]
    auto_locate = true

    [lockscreen_widgets]
    enabled = false
    schema_version = 2
    widget_order = [ "lockscreen-login-box@eDP-1" ]

        [lockscreen_widgets.grid]
        cell_size = 16
        major_interval = 4
        visible = true

        [lockscreen_widgets.widget."lockscreen-login-box@eDP-1"]
        box_height = 70.0
        box_width = 400.0
        cx = 960.0
        cy = 961.0
        output = "eDP-1"
        rotation = 0.0
        type = "login_box"

            [lockscreen_widgets.widget."lockscreen-login-box@eDP-1".settings]
            background_color = "surface_variant"
            background_opacity = 0.88
            background_radius = 12.0
            input_opacity = 1.0
            input_radius = 6.0
            show_caps_lock = true
            show_keyboard_layout = true
            show_login_button = true
            show_password_hint = true

    [nightlight]
    enabled = true
    temperature_night = 4700

    [shell]
    corner_radius_scale = 0.0
    font_family = "CommitMono Nerd Font Mono"
    ui_scale = 1.1000000089406967

        [shell.animation]
        enabled = false

        [shell.panel]
        control_center_position = "center"
        shadow = false

        [[shell.session.actions]]
        action = "shutdown"
        countdown_seconds = 0.0
        enabled = true
        shortcut = "1"
        variant = "destructive"

        [[shell.session.actions]]
        action = "lock"
        countdown_seconds = 0.0
        enabled = true
        shortcut = "2"
        variant = "primary"

        [[shell.session.actions]]
        action = "logout"
        countdown_seconds = 0.0
        enabled = true
        shortcut = "3"
        variant = "secondary"

        [[shell.session.actions]]
        action = "lock_and_suspend"
        countdown_seconds = 0.0
        enabled = true
        shortcut = "4"
        variant = "default"

        [[shell.session.actions]]
        action = "reboot"
        countdown_seconds = 0.0
        enabled = true
        shortcut = "5"
        variant = "outline"

        [shell.shadow]
        alpha = 0.0

    [theme]
    builtin = "Kanagawa"
    community_palette = "Oxocarbon"
    mode = "dark"
    source = "builtin"
    wallpaper_scheme = "m3-content"

    [wallpaper]
    directory = "${wallpaperDir}"
    transition = [ "zoom" ]

        [wallpaper.default]
        path = "${wallpaperPath}"

        [wallpaper.last]
        path = "${wallpaperPath}"

        [wallpaper.monitors.eDP-1]
        path = "${wallpaperPath}"

    [weather]
    refresh_minutes = 60

    [widget.date]
    format = "{:%d %a}"

    [widget.media]
    hide_when_no_media = true

    [widget.screenshot]
    capsule = true

    [widget.session]
    capsule = true

    [widget.spacer_2]
    length = 35
    type = "spacer"

    [widget.tray]
    enabled = true

    [widget.weather]
    show_condition = false
  '';

  # Ship the declarative wallpaper to the stable path config.toml references
  # above. Managed as a read-only symlink into the nix store.
  home.file.".local/share/wallpapers/cube.png".source = wallpaper;

  # LOCK: neutralise the GUI-managed override layer. Noctalia layers
  # ~/.local/state/noctalia/settings.toml ABOVE config.toml, so any value the
  # Settings UI writes there would silently win. We pin it to an empty nix-store
  # file (read-only symlink): empty = no overrides = config.toml is the sole
  # source of truth, and the GUI's writes to this path now fail (toggles no-op).
  # Acceptance: after `nh os switch .`, run `noctalia config validate` and toggle
  # something in Settings to confirm it degrades gracefully (no shell crash). If
  # Noctalia ever rename-replaces the symlink, it regains control until the next
  # rebuild — re-run `nh os switch .` to restore the lock. First switch requires
  # `rm ~/.local/state/noctalia/settings.toml` (home-manager won't clobber it).
  home.file.".local/state/noctalia/settings.toml".text = "";

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

  # Unsloth Studio launcher. Runs in a foot window so server logs are visible.
  # Dispatches to the `unsloth-studio` wrapper (sources unsloth-env, so NVIDIA
  # hosts get the driver libs torch needs) rather than the raw installer
  # binary — launching the installer's own entry bypasses that env and shows
  # "CPU training backend" on a GPU host.
  xdg.desktopEntries.unsloth-studio = {
    name = "Unsloth Studio";
    genericName = "LLM Training Studio";
    comment = "No-code local LLM fine-tuning GUI";
    exec = "foot -- unsloth-studio";
    terminal = false;
    type = "Application";
    categories = [ "Development" "Education" ];
  };

  # Default applications (writes ~/.config/mimeapps.list). GIMP registers
  # itself as the handler for a huge swath of image types on install, which
  # made xdg-open launch GIMP for photos. Route the viewable formats to Loupe
  # (the GNOME image viewer); GIMP stays the default for its own formats
  # (.xcf, .psd, ...) that Loupe can't render. Vivaldi's html/http handlers
  # are re-declared here so home-manager taking over the file doesn't drop
  # them. `force` is needed because Vivaldi already wrote this file itself at
  # runtime as a regular file — home-manager would refuse to clobber it.
  xdg.configFile."mimeapps.list".force = true;

  xdg.mimeApps = {
    enable = true;
    defaultApplications = {
      "text/html" = "vivaldi-stable.desktop";
      "x-scheme-handler/http" = "vivaldi-stable.desktop";
      "x-scheme-handler/https" = "vivaldi-stable.desktop";
      "x-scheme-handler/about" = "vivaldi-stable.desktop";
      "x-scheme-handler/unknown" = "vivaldi-stable.desktop";
      "image/avif" = "org.gnome.Loupe.desktop";
      "image/bmp" = "org.gnome.Loupe.desktop";
      "image/gif" = "org.gnome.Loupe.desktop";
      "image/heic" = "org.gnome.Loupe.desktop";
      "image/jpeg" = "org.gnome.Loupe.desktop";
      "image/jxl" = "org.gnome.Loupe.desktop";
      "image/png" = "org.gnome.Loupe.desktop";
      "image/svg+xml" = "org.gnome.Loupe.desktop";
      "image/tiff" = "org.gnome.Loupe.desktop";
      "image/webp" = "org.gnome.Loupe.desktop";
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
    pkgs.inkscape
    pkgs.gimp

    # Multimedia / apps
    pkgs.obs-studio
    pkgs.loupe
    pkgs.zotero
    pkgs.anki
    pkgs.celluloid
    # Zen Browser (Firefox fork) from its own flake input; substitutes the
    # nixpkgs staging package because it tracks upstream releases faster.
    inputs.zen-browser.packages.${pkgs.system}.default

    # CLI / Dev
    pkgs.micro
    pkgs.foot
    pkgs.cargo
    pkgs.uv
    pkgs.python3
    pkgs.git
    pkgs.gh
    pkgs.podman
    pkgs.opencode
    pkgs.starship

    # Flutter (Linux desktop targets). Hybrid split: the flutter SDK plus the
    # native Linux build chain (clang/cmake/ninja for the engine glue code,
    # pkg-config + gtk3 for the GTK host window) live here on every host —
    # including the aarch64 M2, where `flutter build linux` works fine. The
    # heavy multi-GB Android SDK + JDK live ONLY in the flake's
    # `flutter-android` devShell (see devshells/flutter-android.nix) so they
    # don't bloat all three host closures. `android-tools` ships adb/fastboot
    # everywhere for physical-device testing without entering the shell.
    pkgs.flutter
    pkgs.clang
    pkgs.cmake
    pkgs.ninja
    pkgs.pkg-config
    pkgs.gtk3
    pkgs.android-tools

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
    pkgs.nvtopPackages.full
    pkgs.htop

    # Fonts (also installed system-wide via hosts/_common/default.nix; mirrored
    # here so user-session apps pick them up before login completes)
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

    # Unsloth Studio — local LLM fine-tuning + GGUF inference. The bootstrap
    # script runs unsloth's installer and (on NVIDIA hosts) swaps its CPU
    # torch for the cu130 build and re-asserts the CUDA llama.cpp bundle so
    # both training and inference use the GPU; unsloth-studio launches it.
    scripts.unsloth-bootstrap
    scripts.unsloth-studio
  ] ++ lib.optionals (isx86_64 && stirlingEnabled) [
    # stirling-pdf-desktop (Tauri + Java). Gated by `stirlingEnabled` in the
    # let-block above because upstream builds have been intermittently broken;
    # also x86_64-only (no point on the aarch64 M2). The wrapper lives in
    # scripts.nix#stirling-pdf-wrapped.
    scripts.stirling-pdf-wrapped
  ] ++ lib.optionals isx86_64 [
    # x86_64-only. Upstream doesn't ship aarch64 binaries for these.
    # bazecor (Dygma keyboard configurator), davinci-resolve (Blackmagic),
    # vivaldi (proprietary Chromium fork). The M2 VM skips all three.
    pkgs.bazecor
    pkgs.davinci-resolve
    # Vivaldi ships a free-codecs-only libffmpeg.so by default (no AAC/H.264),
    # which breaks audio on most web video. proprietaryCodecs = true swaps in
    # vivaldi-ffmpeg-codecs so sites like YouTube/Twitch play correctly.
    (pkgs.vivaldi.override {
      proprietaryCodecs = true;
      enableWidevine = true;
    })
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
