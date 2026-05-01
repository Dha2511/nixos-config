{ pkgs, inputs, ... }: {
  home.username = "bob";
  home.homeDirectory = "/home/bob";

  home.packages = [
    # GUI
    inputs.zen-browser.packages.${pkgs.system}.default
    pkgs.zed-editor
    
    # CLI / Dev
    pkgs.helix
    pkgs.ghostty
    pkgs.cargo
    pkgs.uv          # Your Python manager
    pkgs.python3     # Base interpreter
  ];

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
  };

  home.stateVersion = "25.11";
}