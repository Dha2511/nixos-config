{ config, pkgs, lib, noctalia-pkg, ... }:

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

  # Deterministic scratchpad cycle-and-preview. Sway's native
  # `scratchpad show` toggles on the focused window and misbehaves when
  # chained, so these scripts target hide/show explicitly by con_id. Sway
  # marks are globally unique, so membership uses a per-window mark named
  # __scratch_<con_id>, and the transient singleton __scratch_shown flag
  # says which window is currently previewing. Marks survive trips into and
  # out of the scratchpad.
  scratch-min = pkgs.writeShellApplication {
    name = "scratch-min";
    runtimeInputs = [ pkgs.jq pkgs.sway ];
    text = ''
      # Drop a stale previewing flag if minimizing straight out of cycle mode.
      # NOTE: `mark --toggle` wipes ALL marks off the window (sway quirk), so
      # use selective `unmark <name>` instead wherever only one mark should go.
      swaymsg 'unmark __scratch_shown' >/dev/null
      # Identify the focused window through a transient pending mark — sway
      # applies `mark` natively to whatever really has focus, which is more
      # reliable than reading .focused back out of the IPC tree.
      swaymsg 'mark --add __scratch_pending' >/dev/null
      fid=$(swaymsg -t get_tree | jq -r '[.. | objects | select((.marks // []) | index("__scratch_pending")) | .id] | .[0] // ""')
      if [ -n "$fid" ]; then
        swaymsg "[con_id=$fid] unmark __scratch_pending" >/dev/null
        swaymsg "[con_id=$fid] mark --add __scratch_$fid" >/dev/null
      fi
      swaymsg 'move scratchpad' >/dev/null
    '';
  };

  scratch-enter = pkgs.writeShellApplication {
    name = "scratch-enter";
    runtimeInputs = [ pkgs.jq pkgs.sway pkgs.libnotify ];
    text = ''
      shown=$(swaymsg -t get_tree | jq -r '[.. | objects | select((.marks // []) | index("__scratch_shown")) | .id] | .[0] // ""')
      if [ -n "$shown" ]; then
        swaymsg 'mode "scratchpad"' >/dev/null
        exit 0
      fi
      first=$(swaymsg -t get_tree | jq -r '[.. | objects | select([(.marks // [])[]?] | any(test("^__scratch_[0-9]+$"))) | .id] | min // ""')
      if [ -z "$first" ]; then
        notify-send --transient --urgency=low --app-name=scratchpad "Scratchpad" "empty"
        exit 0
      fi
      swaymsg "[con_id=$first] mark --add __scratch_shown" >/dev/null
      swaymsg "[con_id=$first] scratchpad show" >/dev/null
      swaymsg "[con_id=$first] focus" >/dev/null
      swaymsg 'mode "scratchpad"' >/dev/null
    '';
  };

  scratch-next = pkgs.writeShellApplication {
    name = "scratch-next";
    runtimeInputs = [ pkgs.jq pkgs.sway ];
    text = ''
      cur=$(swaymsg -t get_tree | jq -r '[.. | objects | select((.marks // []) | index("__scratch_shown")) | .id] | .[0] // ""')
      if [ -n "$cur" ]; then
        swaymsg "[con_id=$cur] move scratchpad" >/dev/null
        swaymsg "[con_id=$cur] unmark __scratch_shown" >/dev/null
      fi
      ids=$(swaymsg -t get_tree | jq -r '[.. | objects | select([(.marks // [])[]?] | any(test("^__scratch_[0-9]+$"))) | .id] | sort | join(" ")')
      if [ -z "$ids" ]; then
        swaymsg 'mode "default"' >/dev/null
        exit 0
      fi
      read -r -a order <<< "$ids"
      next="''${order[0]}"
      if [ -n "$cur" ]; then
        for i in "''${order[@]}"; do
          if [ "''${i}" -gt "''${cur}" ]; then
            next="$i"
            break
          fi
        done
      fi
      swaymsg "[con_id=$next] mark --add __scratch_shown" >/dev/null
      swaymsg "[con_id=$next] scratchpad show" >/dev/null
      swaymsg "[con_id=$next] focus" >/dev/null
    '';
  };

  scratch-pick = pkgs.writeShellApplication {
    name = "scratch-pick";
    runtimeInputs = [ pkgs.jq pkgs.sway ];
    text = ''
      cur=$(swaymsg -t get_tree | jq -r '[.. | objects | select((.marks // []) | index("__scratch_shown")) | .id] | .[0] // ""')
      if [ -n "$cur" ]; then
        # Take the window out of the cycle set entirely and drop it straight
        # back into the tiling layout.
        swaymsg "[con_id=$cur] unmark" >/dev/null
        swaymsg "[con_id=$cur] floating disable" >/dev/null
      fi
      swaymsg 'mode "default"' >/dev/null
    '';
  };

  scratch-hide = pkgs.writeShellApplication {
    name = "scratch-hide";
    runtimeInputs = [ pkgs.jq pkgs.sway ];
    text = ''
      cur=$(swaymsg -t get_tree | jq -r '[.. | objects | select((.marks // []) | index("__scratch_shown")) | .id] | .[0] // ""')
      if [ -n "$cur" ]; then
        swaymsg "[con_id=$cur] move scratchpad" >/dev/null
        swaymsg "[con_id=$cur] unmark __scratch_shown" >/dev/null
      fi
      swaymsg 'mode "default"' >/dev/null
    '';
  };

  # The custom Graphite XKB layout is installed system-wide by the
  # services.xserver.xkb module in hosts/_common/default.nix (every host is
  # NixOS). US + altgr-intl stays group 0; Graphite is group 1.
  keyboardConfig = ''
    input type:keyboard {
        xkb_layout "us,graphite"
        xkb_variant "altgr-intl,"
    }
  '';
in {
  # Sway config, written to ~/.config/sway/config. Overrides NixOS's
  # system-level /etc/sway/config. Ships the upstream default verbatim but:
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
    # share silently never open.
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

    # Mac-style 3-finger horizontal swipe switches workspaces: fingers move
    # right → content follows → previous workspace (mirrors macOS "natural"
    # scrolling). Pinned to exactly 3 fingers so 4/5-finger swipes stay free.
    bindgesture swipe:3:right workspace prev
    bindgesture swipe:3:left workspace next

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

        # Move the currently focused window to the scratchpad, marking it so
        # the cycle scripts can track it across hide/show trips.
        bindsym $mod+Shift+minus exec ${scratch-min}/bin/scratch-min

        # Cycle-and-preview: $mod+minus surfaces the next scratchpad window
        # (floating + focused) and enters a mode. Each space press advances
        # exactly one window (explicit hide + targeted show — no reliance on
        # sway's toggle semantics). Return picks the current window and drops
        # it from the cycle set (re-tile with $mod+Shift+space); Escape
        # re-minimizes it back.
        mode "scratchpad" {
            bindsym $mod+minus   exec ${scratch-hide}/bin/scratch-hide
            bindsym space        exec ${scratch-next}/bin/scratch-next
            bindsym Return       exec ${scratch-pick}/bin/scratch-pick
            bindsym Escape       exec ${scratch-hide}/bin/scratch-hide
        }
        bindsym $mod+minus       exec ${scratch-enter}/bin/scratch-enter
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
