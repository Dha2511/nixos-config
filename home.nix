{ pkgs, inputs, ... }:
let
  # Noctalia runs this on launch (`started`) and on every light/dark switch
  # (`theme_mode_changed`). It reads the resolved mode and points Sway's seat
  # at the matching phinger variant, so the cursor is always the *opposite*
  # tone of the UI — visible on both light and dark backgrounds.
  cursor-sync-theme = pkgs.writeShellScriptBin "cursor-sync-theme" ''
    mode=$(noctalia msg theme-mode-get 2>/dev/null | tr -d '[:space:]')
    cur=phinger-cursors-light
    [ "$mode" = "dark" ] && cur=phinger-cursors-dark
    swaymsg "seat * xcursor_theme $cur 24" 2>/dev/null || true
  '';
in {
  home.username = "bob";
  home.homeDirectory = "/home/bob";

  # Cursor: phinger (dark baseline). GTK/env/legacy-xcursor are wired here; the
  # live compositor cursor is swapped by the `cursor-sync-theme` hook above and
  # the `seat * xcursor_theme` line in the Sway config (configuration.nix).
  home.pointerCursor = {
    package = pkgs.phinger-cursors;
    name = "phinger-cursors-dark";
    size = 24;
    gtk.enable = true;
  };

  # Foot terminal. Noctalia owns the generated theme file at
  # ~/.config/foot/themes/noctalia (regenerated on light/dark switch); we point
  # foot at it (top-level `include`, NOT inside [main]) and set the font.
  xdg.configFile."foot/foot.ini".text = ''
    include=~/.config/foot/themes/noctalia

    [main]
    font = CommitMono Nerd Font Mono:size=14
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
    started = [ "cursor-sync-theme" ]
    theme_mode_changed = [ "cursor-sync-theme" ]
  '';

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
    pkgs.stirling-pdf
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

    # Drives the phinger light/dark cursor swap (see cursor-sync-theme above).
    cursor-sync-theme
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
    # `ls CLIP`  →  `ls | wl-copy`  (copies the command's stdout to clipboard)
    shellGlobalAliases = {
      CLIP = "| wl-copy";
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
