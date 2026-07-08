# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, inputs, ... }:

let
  noctalia = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  # ESP is ~1 GB and initrd is ~200 MB (NVIDIA modules baked into initrd),
  # so cap retained boot entries or /boot fills up. Raise if you enlarge the ESP.
  boot.loader.systemd-boot.configurationLimit = 3;
  boot.loader.efi.canTouchEfiVariables = true;

  # Early KMS: load drivers in initrd so modesetting happens at boot.
  # i915 drives the internal panel (eDP-1) for a clean high-res fbcon.
  boot.initrd.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" "i915" ];
  # video= locks the panel to its native 1920x1080@144 mode early.
  # quiet + rd.* params: "silent boot" — keep console noise out so
  # Plymouth's splash is the only thing on screen (press Esc to see logs).
  boot.kernelParams = [
    "nvidia-drm.fbdev=1"
    "nvidia-drm.modeset=1"
    "video=eDP-1:1920x1080@144"
    "quiet"
    "rd.udev.log_level=3"
    "rd.systemd.show_status=auto"
  ];

  # Plymouth boot splash (minimal spinner — reliable on NVIDIA proprietary).
  # `boot.plymouth.enable` auto-adds "splash" to kernelParams and symlinks the
  # NixOS snowflake as the spinner's watermark. spinner is built-in, so no
  # themePackages needed. Takes effect on next reboot (initrd rebuild).
  boot.plymouth = {
    enable = true;
    theme = "spinner";
  };
  boot.consoleLogLevel = 3;
  boot.initrd.verbose = false;

  networking.hostName = "nixos"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/Copenhagen";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_DK.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "da_DK.UTF-8";
    LC_IDENTIFICATION = "da_DK.UTF-8";
    LC_MEASUREMENT = "da_DK.UTF-8";
    LC_MONETARY = "da_DK.UTF-8";
    LC_NAME = "da_DK.UTF-8";
    LC_NUMERIC = "da_DK.UTF-8";
    LC_PAPER = "da_DK.UTF-8";
    LC_TELEPHONE = "da_DK.UTF-8";
    LC_TIME = "da_DK.UTF-8";
  };

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Configure console keymap
  console.keyMap = "us";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.bob = {
    isNormalUser = true;
    description = "Bob";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [];
    shell = pkgs.zsh;
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # Zsh: register in /etc/shells so it can be a login shell.
  # Prompt, plugins, and keybinds are managed by home-manager (home.nix).
  programs.zsh.enable = true;

  # Enable Sway
  programs.sway.enable = true;
  programs.sway.extraOptions = [ "--unsupported-gpu" ]; # Required for NVIDIA proprietary driver
  programs.sway.wrapperFeatures.gtk = true; # GTK env vars for app theming
  # Restrict wlroots to the Intel iGPU so Sway never opens the NVIDIA device.
  # Keeps NVIDIA free of holders → RTD3 can power the GPU off when idle.
  # Offload apps still reach the GPU via `nvidia-offload` (PRIME).
  programs.sway.extraSessionCommands = ''
    export WLR_DRM_DEVICES=/dev/dri/intel
  '';

  # Noctalia autostart + IPC keybinds (Sway/Scroll syntax)
  environment.etc."sway/config.d/noctalia.conf".text = ''
    exec ${noctalia}/bin/noctalia

    set $ipc ${noctalia}/bin/noctalia msg
    bindsym $mod+space  exec $ipc panel-toggle launcher
    bindsym $mod+s      exec $ipc panel-toggle control-center
    bindsym $mod+c      exec $ipc panel-toggle clipboard
    bindsym $mod+Shift+e exec $ipc panel-toggle session
    bindsym $mod+comma  exec $ipc settings-toggle
    bindsym --locked XF86AudioRaiseVolume   exec $ipc volume-up
    bindsym --locked XF86AudioLowerVolume   exec $ipc volume-down
    bindsym --locked XF86AudioMute          exec $ipc volume-mute
    bindsym --locked XF86MonBrightnessUp    exec $ipc brightness-up
    bindsym --locked XF86MonBrightnessDown  exec $ipc brightness-down
  '';

  # Declarative Sway config. Overrides NixOS's default
  # (environment.etc."sway/config".source set at mkOptionDefault priority by
  # programs.sway). We ship the upstream default verbatim but:
  #   1. drop the `bar { }` block so Noctalia is the only bar, and
  #   2. set a minimal neutral window-border palette (Noctalia no longer themes Sway).
  environment.etc."sway/config".text = ''
    # Default config for sway
    #
    # Copy this to ~/.config/sway/config and edit it to your liking.
    #
    # Read `man 5 sway` for a complete reference.

    ### Variables
    #
    # Logo key. Use Mod1 for Alt.
    set $mod Mod4
    # Home row direction keys, like vim
    set $left h
    set $down j
    set $up k
    set $right l
    # Your preferred terminal emulator
    set $term foot
    # Your preferred application launcher
    set $menu wmenu-run

    ### Output configuration
    #
    # Default wallpaper (more resolutions are available in /run/current-system/sw/share/backgrounds/sway/)
    output * bg /run/current-system/sw/share/backgrounds/sway/Sway_Wallpaper_Blue_1920x1080.png fill
    #
    # Example configuration:
    #
    #   output HDMI-A-1 resolution 1920x1080 position 1920,0
    #
    # You can get the names of your outputs by running: swaymsg -t get_outputs

    ### Idle configuration
    #
    # Example configuration:
    #
    # exec swayidle -w \
    #          timeout 300 'swaylock -f -c 000000' \
    #          timeout 600 'swaymsg "output * power off"' resume 'swaymsg "output * power on"' \
    #          before-sleep 'swaylock -f -c 000000'
    #
    # This will lock your screen after 300 seconds of inactivity, then turn off
    # your displays after another 300 seconds, and turn your screens back on when
    # resumed. It will also lock your screen before your computer goes to sleep.

    ### Input configuration
    #
    # Example configuration:
    #
    #   input type:touchpad {
    #       dwt enabled
    #       tap enabled
    #       natural_scroll enabled
    #       middle_emulation enabled
    #   }
    #
    #   input type:keyboard {
    #       xkb_layout "eu"
    #   }
    #
    # You can also configure each device individually.
    # Read `man 5 sway-input` for more information about this section.

    # Cursor: phinger (dark baseline). The Noctalia `theme_mode_changed` hook
    # swaps light/dark variants live so the pointer stays visible on any bg.
    # libinput has no edge-motion, so acceleration + drag_lock compensate for
    # running out of touchpad surface when dragging.
    seat * xcursor_theme phinger-cursors-dark 24

    input type:touchpad {
        accel_profile adaptive
        pointer_accel 0.5
        drag enabled
        drag_lock enabled
        tap enabled
    }

    ### Key bindings
    #
    # Basics:
    #
        # Start a terminal
        bindsym $mod+Return exec $term

        # Kill focused window
        bindsym $mod+Shift+q kill

        # Start your launcher
        bindsym $mod+d exec $menu

        # Drag floating windows by holding down $mod and left mouse button.
        # Resize them with right mouse button + $mod.
        # Despite the name, also works for non-floating windows.
        # Change normal to inverse to use left mouse button for resizing and right
        # mouse button for dragging.
        floating_modifier $mod normal

        # Reload the configuration file
        bindsym $mod+Shift+c reload

        # Session menu (lock/suspend/logout/reboot/shutdown) is provided by
        # Noctalia — see /etc/sway/config.d/noctalia.conf ($mod+Shift+e).
    #
    # Moving around:
    #
        # Move your focus around
        bindsym $mod+$left focus left
        bindsym $mod+$down focus down
        bindsym $mod+$up focus up
        bindsym $mod+$right focus right

        # Or use $mod+[up|down|left|right]
        bindsym $mod+Left focus left
        bindsym $mod+Down focus down
        bindsym $mod+Up focus up
        bindsym $mod+Right focus right

        # Move the focused window with the same, but add Shift
        bindsym $mod+Shift+$left move left
        bindsym $mod+Shift+$down move down
        bindsym $mod+Shift+$up move up
        bindsym $mod+Shift+$right move right

        # Ditto, with arrow keys
        bindsym $mod+Shift+Left move left
        bindsym $mod+Shift+Down move down
        bindsym $mod+Shift+Up move up
        bindsym $mod+Shift+Right move right
    #
    # Workspaces:
    #
        # Switch to workspace
        bindsym $mod+1 workspace number 1
        bindsym $mod+2 workspace number 2
        bindsym $mod+3 workspace number 3
        bindsym $mod+4 workspace number 4
        bindsym $mod+5 workspace number 5
        bindsym $mod+6 workspace number 6
        bindsym $mod+7 workspace number 7
        bindsym $mod+8 workspace number 8
        bindsym $mod+9 workspace number 9
        bindsym $mod+0 workspace number 10

        # Move focused container to workspace
        bindsym $mod+Shift+1 move container to workspace number 1
        bindsym $mod+Shift+2 move container to workspace number 2
        bindsym $mod+Shift+3 move container to workspace number 3
        bindsym $mod+Shift+4 move container to workspace number 4
        bindsym $mod+Shift+5 move container to workspace number 5
        bindsym $mod+Shift+6 move container to workspace number 6
        bindsym $mod+Shift+7 move container to workspace number 7
        bindsym $mod+Shift+8 move container to workspace number 8
        bindsym $mod+Shift+9 move container to workspace number 9
        bindsym $mod+Shift+0 move container to workspace number 10

        # Note: workspaces can have any name you want, not just numbers.
        # We just use 1-10 as the default.
    #
    # Layout stuff:
    #
        # You can "split" the current object of your focus with
        # $mod+b or $mod+v, for horizontal and vertical splits
        # respectively.
        bindsym $mod+b splith
        bindsym $mod+v splitv

        # Switch the current container between different layout styles
        bindsym $mod+w layout tabbed
        bindsym $mod+e layout toggle split

        # Make the current focus fullscreen
        bindsym $mod+f fullscreen

        # Toggle the current focus between tiling and floating mode
        bindsym $mod+Shift+space floating toggle

        # Move focus to the parent container
        bindsym $mod+a focus parent
    #
    # Scratchpad:
    #
        # Sway has a "scratchpad", which is a bag of holding for windows.
        # You can send windows there and get them back later.

        # Move the currently focused window to the scratchpad
        bindsym $mod+Shift+minus move scratchpad

        # Show the next scratchpad window or hide the focused scratchpad window.
        # If there are multiple scratchpad windows, this command cycles through them.
        bindsym $mod+minus scratchpad show
    #
    # Resizing containers:
    #
    mode "resize" {
        # left will shrink the containers width
        # right will grow the containers width
        # up will shrink the containers height
        # down will grow the containers height
        bindsym $left resize shrink width 10px
        bindsym $down resize grow height 10px
        bindsym $up resize shrink height 10px
        bindsym $right resize grow width 10px

        # Ditto, with arrow keys
        bindsym Left resize shrink width 10px
        bindsym Down resize grow height 10px
        bindsym Up resize shrink height 10px
        bindsym Right resize grow width 10px

        # Return to default mode
        bindsym Return mode "default"
        bindsym Escape mode "default"
    }
    bindsym $mod+r mode "resize"
    #
    # Utilities:
    #
        bindsym --locked XF86AudioMicMute exec pactl set-source-mute @DEFAULT_SOURCE@ toggle

        # Special key to take a screenshot with grim
        bindsym Print exec grim

    #
    # Status Bar:
    #
    # Default swaybar intentionally disabled — Noctalia provides the bar.
    # Window borders: minimal neutral palette (declarative; replaces Noctalia's blue template).
    client.focused          #8b8f96 #161616 #f2f4f8 #8b8f96 #8b8f96
    client.focused_inactive #2a2d31 #161616 #9b9da2 #2a2d31 #2a2d31
    client.unfocused        #2a2d31 #161616 #9b9da2 #2a2d31 #2a2d31
    client.urgent           #c75b6a #161616 #f2f4f8 #c75b6a #c75b6a
    client.placeholder      #161616 #161616 #9b9da2 #161616 #161616
    client.background       #161616

    include /etc/sway/config.d/*
  '';

  # Make Electron apps use Wayland
  environment.variables.NIXOS_OZONE_WL = "1";

  # Battery Efficiency
  services.power-profiles-daemon.enable = true; # Power profiles (balanced/power-saver/performance)
  services.upower.enable = true; # Battery status reporting via D-Bus

  # Audio
  security.rtkit.enable = true; # Realtime scheduling for PipeWire (low-latency audio)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true; # 32-bit ALSA app compatibility (e.g. some games/Wine)
    pulse.enable = true; # Emulates PulseAudio so modern apps work seamlessly
  };

  # Bluetooth
  hardware.bluetooth.enable = true; # BlueZ stack (daemon + kernel modules)
  hardware.bluetooth.powerOnBoot = true; # Power on adapter automatically at boot

  # Colon-free stable symlink for the Intel iGPU. WLR_DRM_DEVICES uses ':' as a
  # list separator, so the by-path name (pci-0000:00:02.0-card) breaks parsing.
  # Keyed on PCI path → survives card0/card1 enumeration swaps across reboots.
  services.udev.extraRules = ''
    SUBSYSTEM=="drm", ENV{ID_PATH}=="pci-0000:00:02.0", SYMLINK+="dri/intel"
  '';

  # Modern graphics stack
  hardware.graphics.enable = true;

  # NVIDIA (RTX 3050 Mobile, hybrid with Intel iGPU)
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true; # Required for Wayland
    powerManagement.enable = true; # Suspends GPU on sleep
    powerManagement.finegrained = true; # RTD3: powers GPU off when idle
    open = false; # Proprietary kernel module
    package = config.boot.kernelPackages.nvidiaPackages.stable;
    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true; # Provides `nvidia-offload` wrapper
      };
      intelBusId = "PCI:0:2:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  # Essential System Tools
  environment.systemPackages = with pkgs; [
    git
    gh
    nh
    aria2
    curl
    wget
    gitbutler
    podman
    gnutar
    unzip
    wl-clipboard
  ] ++ [ noctalia ];

  fonts.packages = with pkgs; [
    nerd-fonts.commit-mono
    nerd-fonts.departure-mono
    lexend
    noto-fonts
    noto-fonts-cjk-sans
    noto-fonts-color-emoji
    atkinson-hyperlegible-mono
    atkinson-hyperlegible-next
    hubot-sans
    mona-sans
    alegreya
    alegreya-sans
    fraunces
    recursive
  ];

  # The Python Secret Sauce: nix-ld
  # This allows pre-compiled binaries (like those uv/pip download) to run
  programs.nix-ld.enable = true;

  # Nix Settings
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "26.05"; # Did you read the comment?

}
