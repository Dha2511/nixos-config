{ pkgs, inputs, ... }: {
  home.username = "bob";
  home.homeDirectory = "/home/bob";

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
  ];

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
  };

  home.stateVersion = "26.05";
}
