{ pkgs, inputs, ... }: {
  home.username = "bob";
  home.homeDirectory = "/home/bob";

  home.packages = [
    # GUI
    inputs.zen-browser.packages.${pkgs.system}.default
    inputs.forgecode.packages.${pkgs.system}.default
    pkgs.zed-editor
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
    pkgs.ghostty
    pkgs.cargo
    pkgs.uv
    pkgs.python3
    pkgs.git
    pkgs.gh
    pkgs.gitbutler
    pkgs.podman

    # Online search
    pkgs.surfraw
    pkgs.ddgr
    pkgs.w3m
    pkgs.searxng # We likely need to set up a service for this

    # Utilities
    pkgs.aria2
    pkgs.curl
    pkgs.wget
    pkgs.timg
    pkgs.tar
    pkgs.unzip
    pkgs.tmux
    pkgs.ripgrep
    pkgs.ripgrep-all
    pkgs.fzf
    pkgs.fd
  ];

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
  };

  home.stateVersion = "25.11";
}