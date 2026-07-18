# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, inputs, ... }:

let
  noctalia = inputs.noctalia.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Toggles the keyboard layout group (us <-> graphite) and pops a transient
  # Noctalia notification with the resulting layout name. jq parses the active
  # layout out of `swaymsg get_inputs`; libnotify routes to Noctalia's daemon.
  kb-toggle = pkgs.writeShellApplication {
    name = "kb-toggle";
    runtimeInputs = [ pkgs.jq pkgs.libnotify pkgs.sway ];
    text = ''
      cur=$(swaymsg -t get_inputs | jq -r '
        [ .[] | select(.type == "keyboard") | select(.xkb_layout_names | length > 0)
          | .xkb_layout_names[.xkb_active_layout_index] ] | .[0] // empty')
      swaymsg 'input type:keyboard xkb_switch_layout next' >/dev/null
      if [[ "$cur" == *[Gg]raphite* ]]; then
        notify-send --transient --urgency=low --icon=input-keyboard --app-name=keyboard "Keyboard layout" "QWERTY"
      else
        notify-send --transient --urgency=low --icon=input-keyboard --app-name=keyboard "Keyboard layout" "Graphite"
      fi
    '';
  };
in
{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  # ESP is 1 GB. Each entry ≈ 66 MB (13 MB kernel + 53 MB initrd; NVIDIA is
  # intentionally NOT in the initrd, so it's small). 5 entries ≈ 340 MB,
  # leaving ~680 MB headroom. Stay ≤ ~10.
  boot.loader.systemd-boot.configurationLimit = 5;
  boot.loader.efi.canTouchEfiVariables = true;
  # Boot immediately — no menu shown. Hold Space during boot to open the menu
  # (e.g. to pick a previous generation if a switch fails to boot).
  boot.loader.timeout = 0;

  # Early KMS: load i915 in initrd so modesetting happens at boot.
  # i915 drives the internal panel (eDP-1) for a clean high-res fbcon.
  # NOTE: NVIDIA is intentionally NOT in the initrd. The panel is on Intel,
  # there's no LUKS/decrypt prompt, and loading nvidia in the initrd caused
  # two problems: (1) it bound the dGPU before the main udev was listening,
  # so nixpkgs's bind→power/control=auto fine-grained-PM rule never fired and
  # the GPU could never runtime-suspend; (2) it gave Plymouth a second
  # display-less KMS device (nvidia-drm "Cannot find any crtc") that glitched
  # the splash. nvidia is loaded in the main system via boot.kernelModules.
  boot.initrd.kernelModules = [ "i915" ];
  boot.kernelModules = [ "nvidia" "nvidia_modeset" "nvidia_uvm" "nvidia_drm" "msi-ec" ]; # msi-ec: MSI EC driver (battery charge cap — see "Battery charge cap" below)
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

  # Plymouth boot splash (bgrt theme — OEM/manufacturer logo from the
  # firmware ACPI BGRT table, rendered above a spinner). Reliable on NVIDIA
  # proprietary. `boot.plymouth.enable` auto-adds "splash" to kernelParams;
  # bgrt is built-in so no themePackages needed. Falls back to a plain spinner
  # if the firmware exposes no BGRT. Takes effect on next reboot (initrd rebuild).
  boot.plymouth = {
    enable = true;
    theme = "bgrt";
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

  # Configure keymap (XKB): US(altgr-intl) is the default (group 0), Graphite
  # (custom) is group 1 — both carry the altgr-intl AltGr layer for Danish
  # (ae/oslash/aring) and dead keys. Toggle groups in the Sway config below via
  # xkb_switch_layout (grp:win_space_toggle would collide with Noctalia's $mod+space).
  services.xserver.xkb = {
    layout = "us,graphite";
    variant = "altgr-intl,";
    extraLayouts.graphite = {
      description = "Graphite (intl., with AltGr dead keys)";
      languages = [ "eng" ];
      symbolsFile = ./xkb/graphite;
    };
  };

  # Configure console keymap
  console.keyMap = "us";

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.bob = {
    isNormalUser = true;
    description = "Bob";
    extraGroups = [ "networkmanager" "wheel" "lp" "lpadmin" "scanner" ];
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
    exec foot --server

    exec ${noctalia}/bin/noctalia

    set $ipc ${noctalia}/bin/noctalia msg
    bindsym $mod+space  exec $ipc panel-toggle launcher
    bindsym $mod+s      exec $ipc panel-toggle control-center
    bindsym $mod+c      exec $ipc panel-toggle clipboard
    bindsym $mod+Shift+e exec $ipc panel-toggle session
    bindsym $mod+comma  exec $ipc settings-toggle
    bindsym $mod+t      exec $ipc theme-mode-toggle
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
    set $term footclient
    # Your preferred application launcher
    set $menu wmenu-run

    ### Output configuration
    #
    # Noctalia manages the wallpaper (persisted, via `noctalia msg wallpaper-set`);
    # we intentionally do NOT set `output * bg` here, since Sway's own `swaybg`
    # would override Noctalia's wallpaper on every reload/rebuild.
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

    input type:keyboard {
        xkb_layout "us,graphite"
        xkb_variant "altgr-intl,"
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

        # Toggle keyboard layout: QWERTY <-> Graphite (both keep altgr-intl).
        # slash sits on the same physical key in both layouts, so this is stable.
        bindsym $mod+slash exec ${kb-toggle}/bin/kb-toggle

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

  # Hide the NVIDIA Vulkan/EGL ICDs from the whole session so no app
  # enumerates (and opens) /dev/dri/renderD129 during loader init. Any open
  # render-node FD pins NVIDIA's runtime-PM count > 0 and blocks RTD3, so the
  # dGPU would never sleep (light stays on). With these set, libvulkan/GLVND
  # load Mesa only → only the Intel node is ever opened → RTD3 can engage.
  # PRIME offload still works via the custom `nvidia-offload` wrapper below,
  # which overrides these vars back to the NVIDIA ICDs.
  environment.sessionVariables = {
    VK_ICD_FILENAMES = "${pkgs.mesa}/share/vulkan/icd.d/intel_icd.x86_64.json";
    __EGL_VENDOR_LIBRARY_FILENAMES = "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
  };

  # Battery Efficiency
  services.power-profiles-daemon.enable = true; # Power profiles (balanced/power-saver/performance)
  services.upower.enable = true; # Battery status reporting via D-Bus

  # Compressed RAM swap (zstd). Normally stays empty; under memory pressure the
  # kernel compresses cold pages into RAM instead of hitting the 8.8G disk-swap
  # partition (which stays as a lower-priority fallback). zram is swapon'd with a
  # higher priority, so it's used first and the disk swap only catches overflow.
  # Net effect: stays responsive when RAM fills up instead of grinding on disk.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
  };

  # Firmware updates (LVFS). `fwupdmgr refresh && fwupdmgr get-updates` checks
  # for BIOS/EC updates — an MSI firmware update is the one thing that might
  # officially enable battery charge limiting, so worth having regardless.
  services.fwupd.enable = true;

  # --- Battery charge cap (EXPERIMENTAL) ---
  # The in-kernel msi-ec driver exposes charge-control sysfs attributes, but
  # only for firmware strings on its hard-coded allowlist. The Thin 15 B13UC
  # (MS-16R8, EC firmware 16R8EMS1.*) isn't listed, so the module normally
  # refuses to load. This kernel patch makes it fall back to the GF63 Thin 11UC
  # (CONF12) register map and load anyway — exposing charge_control_end_threshold.
  #
  # CAVEAT: the GF63's register map (charge-control EC addr 0xd7) is ASSUMED, not
  # verified, for this board. If charging doesn't actually cap at 80%, or anything
  # odd happens, remove boot.kernelPatches + the battery-charge-cap service below
  # and rebuild. Reverting is always clean (the EC value resets on EC/BIOS reset).
  #
  # COST: boot.kernelPatches forces a full kernel source build, so every kernel
  # bump re-triggers a ~20-60 min local rebuild (NVIDIA rebuilds against it too).
  boot.kernelPatches = [
    { name = "msi-ec-ms-16r8-fallback"; patch = ./patches/msi-ec-ms-16r8.patch; }
  ];
  # (msi-ec itself is appended to boot.kernelModules up with the NVIDIA modules.)

  # Apply the cap once msi-ec has loaded. Runs after systemd-modules-load (which
  # loads msi-ec) and retries briefly against ordering slack. Only the END
  # threshold is written (one EC write) to minimise writes to the untested reg.
  systemd.services.battery-charge-cap = {
    description = "Cap battery charge at 80% via msi-ec";
    after = [ "systemd-modules-load.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c 'for i in 1 2 3 4 5; do [ -w /sys/class/power_supply/BAT1/charge_control_end_threshold ] && { echo 80 > /sys/class/power_supply/BAT1/charge_control_end_threshold; exit 0; }; sleep 1; done; echo battery-charge-cap: charge_control_end_threshold not writable; exit 0'";
    };
  };

  # Audio
  security.rtkit.enable = true; # Realtime scheduling for PipeWire (low-latency audio)
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true; # 32-bit ALSA app compatibility (e.g. some games/Wine)
    pulse.enable = true; # Emulates PulseAudio so modern apps work seamlessly
    # Bluetooth A2DP codec priority: WirePlumber picks the first codec in the
    # list that the device supports, so high-fidelity codecs (LDAC, aptX HD,
    # aptX, AAC) are tried before falling back to SBC-XQ / SBC. SBC-XQ uses
    # high-bitpool "Dual Channel" mode for near-CD quality on devices that
    # lack aptX/AAC/LDAC — works with virtually every BT headphone.
    wireplumber.configPackages = [
      (pkgs.writeTextDir "share/wireplumber/wireplumber.conf.d/51-bluetooth-codecs.conf" ''
        monitor.bluez.properties = {
          bluez5.roles = [ "a2dp-sink" "hsp-hs" "hfp-hf" ]
          bluez5.codecs = [ "ldac" "aptx_hd" "aptx" "aac" "sbc_xq" "sbc" ]
          bluez5.enable-sbc-xq = true
        }
      '')
    ];
  };

  # Bluetooth
  hardware.bluetooth.enable = true; # BlueZ stack (daemon + kernel modules)
  hardware.bluetooth.powerOnBoot = true; # Power on adapter automatically at boot

  # Colon-free stable symlink for the Intel iGPU. WLR_DRM_DEVICES uses ':' as a
  # list separator, so the by-path name (pci-0000:00:02.0-card) breaks parsing.
  # Keyed on PCI path → survives card0/card1 enumeration swaps across reboots.
  #
  # Also force the NVIDIA dGPU into PCI runtime PM (power/control=auto).
  # nixpkgs's built-in fine-grained rule only matches ACTION=="bind"; that's
  # fragile (and was missed entirely when nvidia used to bind in the initrd).
  # Matching "add|bind" covers coldplug replay too, so control=auto is set
  # reliably → with zero clients the GPU enters RTD3 and powers off.
  services.udev.extraRules = ''
    SUBSYSTEM=="drm", ENV{ID_PATH}=="pci-0000:00:02.0", SYMLINK+="dri/intel"
    ACTION=="add|bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", TEST=="power/control", ATTR{power/control}="auto"
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
        # We ship our own `nvidia-offload` (see environment.systemPackages)
        # that also flips VK_ICD_FILENAMES / EGL vendor to NVIDIA, so offloaded
        # apps punch through the Intel-only loader restriction set above.
        enableOffloadCmd = false;
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
    gsettings-desktop-schemas  # org.gnome.desktop.interface schema → Vivaldi/Chromium reads color-scheme
    # Printing (network HP printer) — CLI tools
    hplipWithPlugin   # hp-setup / hp-info / hp-toolbox / hp-scan (includes the HP binary plugin)
    cups              # lp / lpstat / lpadmin / lpinfo user-facing CLI
    nmap              # network discovery (locate printer IP + general use)
  ] ++ [ noctalia
    # Re-enables the NVIDIA Vulkan/EGL ICDs (overriding the session's
    # Intel-only restriction) for opt-in apps. Usage: nvidia-offload <cmd>.
    (pkgs.writeShellScriptBin "nvidia-offload" ''
      export __NV_PRIME_RENDER_OFFLOAD=1
      export __NV_PRIME_RENDER_OFFLOAD_PROVIDER=NVIDIA-G0
      export __GLX_VENDOR_LIBRARY_NAME=nvidia
      export __VK_LAYER_NV_optimus=NVIDIA_only
      export VK_ICD_FILENAMES="${config.hardware.nvidia.package}/share/vulkan/icd.d/nvidia_icd.json"
      export __EGL_VENDOR_LIBRARY_FILENAMES="${config.hardware.nvidia.package}/share/glvnd/egl_vendor.d/10_nvidia.json"
      exec "$@"
    '')
  ];

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

  # direnv — auto-loads devShells on `cd` into a flake repo (e.g. trellis-lfm).
  # nix-direnv caches `nix develop` results so entry is instant after the first.
  programs.direnv.enable = true;
  programs.direnv.nix-direnv.enable = true;

  # dconf (D-Bus settings store). The Noctalia `color-scheme-sync` hook writes
  # the freedesktop color-scheme here so Chromium-based apps (Vivaldi) follow
  # the active light/dark mode.
  programs.dconf.enable = true;

  # Bridge the dconf color-scheme to the freedesktop portal interface that
  # Chromium-based apps (Vivaldi) query for prefers-color-scheme. Without this
  # the gtk backend never runs, so Vivaldi can't see the value dconf holds.
  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = false;              # keep Vivaldi's own link handling
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = [ "gtk" ];
  };

  # Nix Settings
  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    auto-optimise-store = true;  # hardlink-dedup on every build
  };

  # Weekly GC: drop generations older than 14 days, then collect garbage.
  # At ~2 rebuilds/day keeps ~28 generations — well above the 5 boot-menu
  # entries. Cleans system + home-manager profiles; persistent (default) lets
  # missed runs (laptop suspended) catch up.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  # Periodic full optimise pass (complements auto-optimise-store).
  nix.optimise.automatic = true;

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # --- Printing (network HP printer over Wi-Fi) ---
  # CUPS is the print daemon; hplipWithPlugin provides the HP backend +
  # proprietary plugin most consumer HP printers (DeskJet/Envy/OfficeJet)
  # require to actually print.
  services.printing = {
    enable = true;
    drivers = [ pkgs.hplipWithPlugin ];
  };

  # Avahi: mDNS discovery so the printer is reachable as <hostname>.local
  # and shows up in `lpinfo -v`. Required for driverless IPP discovery.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Scanning via SANE (HP all-in-one). Uses hplipWithPlugin's backend.
  hardware.sane.enable = true;
  hardware.sane.extraBackends = [ pkgs.hplipWithPlugin ];

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
