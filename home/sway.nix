{ config, pkgs, lib, noctalia-pkg, isNixOS, ... }:

let
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

  # On NixOS, the custom Graphite XKB layout is installed system-wide by the
  # services.xserver.xkb module. On Ubuntu it doesn't exist — use plain US
  # with altgr-intl (still gives Danish ae/oslash/aring via AltGr).
  keyboardConfig = if isNixOS then ''
    input type:keyboard {
        xkb_layout "us,graphite"
        xkb_variant "altgr-intl,"
    }
  '' else ''
    input type:keyboard {
        xkb_layout "us"
        xkb_variant "altgr-intl"
    }
  '';

  # kb-toggle only makes sense when graphite is available (NixOS only).
  kbToggleBinding = lib.optionalString isNixOS ''
        # Toggle keyboard layout: QWERTY <-> Graphite (both keep altgr-intl).
        # slash sits on the same physical key in both layouts, so this is stable.
        bindsym $mod+slash exec ${kb-toggle}/bin/kb-toggle
  '';
in {
  # Sway config, written to ~/.config/sway/config (portable across NixOS + Ubuntu).
  # Overrides NixOS's system-level /etc/sway/config and Ubuntu's /etc/sway/config.
  # Ships the upstream default verbatim but:
  #   1. drops the `bar { }` block so Noctalia is the only bar, and
  #   2. sets a minimal neutral window-border palette (Noctalia no longer themes Sway).
  xdg.configFile."sway/config".text = ''
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

    # Publish Wayland/XDG env to the systemd user manager AND the D-Bus
    # activation environment. Portal backends (xdg-desktop-portal-gtk /
    # -wlr) are D-Bus/systemd-activated, so they start with the user
    # manager's environment — which has no WAYLAND_DISPLAY unless we export
    # it here. Without this they can't reach the compositor: the gtk backend
    # fails with "startup job failed" and wlr is skipped on its
    # ConditionEnvironment=WAYLAND_DISPLAY check, so file pickers / screen
    # share silently never open. Portable across NixOS and Ubuntu.
    exec systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP DISPLAY XDG_SESSION_TYPE
    exec dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP

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

    ${keyboardConfig}

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

    ${kbToggleBinding}

        # Drag floating windows by holding down $mod and left mouse button.
        # Resize them with right mouse button + $mod.
        # Despite the name, also works for non-floating windows.
        # Change normal to inverse to use left mouse button for resizing and right
        # mouse button for dragging.
        floating_modifier $mod normal

        # Reload the configuration file
        bindsym $mod+Shift+c reload

        # Session menu (lock/suspend/logout/reboot/shutdown) is provided by
        # Noctalia — see config.d/noctalia.conf ($mod+Shift+e).
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

    include config.d/*
  '';

  # Noctalia autostart + IPC keybinds (Sway/Scroll syntax), written to
  # ~/.config/sway/config.d/noctalia.conf — included by the main config above.
  xdg.configFile."sway/config.d/noctalia.conf".text = ''
    exec foot --server

    exec ${noctalia-pkg}/bin/noctalia

    set $ipc ${noctalia-pkg}/bin/noctalia msg
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
}
