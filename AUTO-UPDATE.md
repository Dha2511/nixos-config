# Auto-update (deferred)

> **Status: NOT YET APPLIED.** This documents the weekly auto-build + notify
> automation we deliberately deferred. The GC + boot changes in
> `hosts/nixos/configuration.nix` are already active; everything below is additive and can
> be added whenever you want it.

## When to apply this

You deferred this because you're still in an active-setup phase (rebuilding
~2×/day), and weekly `nix flake update` bumps would occasionally muddy your
config testing. Apply this **once your setup stabilizes and you notice yourself
forgetting to update** — i.e. when it actually earns its place.

You do **not** need this to stay secure or un-bricked: your current generation
is permanently GC-protected, and NixOS rollbacks make infrequent manual updates
perfectly safe. This is purely a "patches arrive without me thinking" convenience.

## What it does

A weekly **systemd user** timer (runs as your user, in your Sway session) that:

1. `git pull --ff-only` your latest committed config
2. `nix flake update` — bump all inputs (nixpkgs + noctalia + home-manager)
3. `nixos-rebuild build` — build **only**, never switch
4. `nix store diff-closures` — summarize the package-level changes
5. Notify you via Noctalia (success / offline / failed)

**Nothing applies live.** You review the diff and run `nh os test .` (try it
live, doesn't touch the boot menu) then `nh os switch .` when confident. A
broken unstable/NVIDIA build becomes a *notification*, never a bricked boot —
which is exactly why this is safe alongside `boot.loader.timeout = 0`.

## How to apply

Two edits to `home/default.nix`.

### 1. `libnotify` — already installed

`notify-send` (from libnotify) sends the notification; **Noctalia renders it**
(Noctalia owns the `org.freedesktop.Notifications` D-Bus name). Do **NOT** add
`mako`/`dunst` — they would collide with Noctalia. `pkgs.libnotify` is already
in the `home.packages` list in `home/default.nix` (Utilities group), so this
step is done — skip to step 2.

### 2. Add the service + timer

Paste these into the `in { ... }` body (e.g. just before `programs.zsh` or
near the end, before `home.stateVersion`):

```nix
  # Weekly auto-build: pull + bump inputs + build (NEVER switch), then notify
  # via Noctalia. You review the diff and run `nh os test .` / `nh os switch .`
  # yourself — so a broken unstable/NVIDIA build is a notification, not a brick.
  # On success it auto-commits the flake.lock bump to main (never pushes); on
  # failure it reverts the lock so main never holds a broken bump.
  systemd.user.services.nixos-autobuild = {
    Unit.Description = "NixOS auto-build (pull + flake update + build, no switch)";
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "nixos-autobuild" ''
        set +e
        cd /home/bob/nixos-config || exit 0
        diff=~/.cache/nixos-autobuild.diff
        mkdir -p "$(dirname "$diff")"
        : > "$diff"

        net_ok=1
        echo "=== git pull ===" >> "$diff"
        GIT_TERMINAL_PROMPT=0 git pull --ff-only origin main >> "$diff" 2>&1 || net_ok=0
        echo "=== nix flake update ===" >> "$diff"
        nix flake update >> "$diff" 2>&1 || net_ok=0
        echo "=== nixos-rebuild build ===" >> "$diff"
        nixos-rebuild build --flake .#nixos >> "$diff" 2>&1
        build_rc=$?
        echo "=== diff-closures (current -> built) ===" >> "$diff"
        nix store diff-closures /run/current-system result >> "$diff" 2>&1

        if [ "$build_rc" -ne 0 ]; then
          git checkout flake.lock >/dev/null 2>&1
          notify-send -u critical "NixOS auto-build FAILED" "See: less $diff"
        elif [ "$net_ok" -eq 0 ]; then
          notify-send -u normal "NixOS build ready (offline)" \
            "Couldn't reach network — built from current state. See: less $diff"
        else
          git add flake.lock
          git diff --cached --quiet \
            || git commit -m "auto: bump flake.lock (weekly autobuild OK)" >/dev/null 2>&1
          notify-send -u normal "NixOS build ready" \
            "Inputs bumped, built, lock committed. Review: less $diff — then: nh os test . / nh os switch ."
        fi
      ''}";
    };
  };

  systemd.user.timers.nixos-autobuild = {
    Timer = {
      OnCalendar = "weekly";
      Persistent = true;           # catch up after suspend/power-off
      RandomizedDelaySec = "10m";  # spread load off the exact top-of-the-hour
    };
    Install = { WantedBy = [ "timers.target" ]; };
  };
```

Apply with `nh os switch .` (home-manager will enable the timer).

## Verify it works

Trigger a one-off run immediately (don't wait a week):

```sh
systemctl --user start nixos-autobuild.service
# watch a Noctalia notification fire, then:
less ~/.cache/nixos-autobuild.diff
systemctl --user status nixos-autobuild.service
systemctl --user list-timers nixos-autobuild.timer   # confirm next-fire time
```

You should see a Noctalia notification and, on success, a new
`auto: bump flake.lock (weekly autobuild OK)` commit (local, not pushed).

## Behavior reference

| Situation | What happens | Notification |
|---|---|---|
| Build OK, network OK | lock bump committed to main (not pushed) | "build ready" (normal) |
| Build OK, **offline** | builds from current state; lock unchanged | "ready (offline)" (normal) |
| Build **FAILED** | lock bump reverted; main untouched | "FAILED, see log" (critical) |

### What happens if I shut down mid-build?
Nothing bad. The job never switches, so your running system is untouched.
Nix builds are atomic/resumable — interrupted work is discarded and the next
run picks up where it left off. Worst case: a wasted partial build and a dirty
flake.lock that the next run sorts out. No corruption, no bricked boot.

## Tuning knobs

- **Cadence:** change `OnCalendar`. `weekly` is the default; `daily` is more
  responsive; `monthly` if you rarely want updates.
- **Input scope:** `nix flake update` bumps *all* inputs. To bump only nixpkgs
  (stabler; slower noctalia fixes): change it to `nix flake update nixpkgs`.
- **A "build started" notification:** not included — interrupting is harmless
  and Noctalia is quiet-by-design. Add a `notify-send` after the `cd` line if
  you want a heads-up (e.g. to explain fan noise) before the build runs.
- **Retention interplay:** GC (`--delete-older-than 14d`) and this auto-build
  are independent. Each successful manual `nh os switch .` creates a generation;
  GC ages them out past 14 days. Auto-build alone creates **no** generation
  (only `switch` does) — it just keeps builds warm.

## Notes

- **Auto-commits to main:** success records `auto: bump flake.lock ...` locally
  on `main` (never pushed). This keeps the tree clean and records patches, at
  the cost of ~52 such commits/year in your (otherwise handcrafted) history.
  Push when you do your normal git workflow.
- **Notifications only fire while logged into Sway** (it's a user session
  service). Noctalia is therefore always running when a notification is sent.
  If you enable `loginctl enable-linger bob`, the timer could run pre-login —
  but then notify-send would have no daemon to reach, so don't.
- **`GIT_TERMINAL_PROMPT=0`** makes `git pull` fail fast (no hanging) if your
  GitHub HTTPS credentials aren't available — that surfaces as the "offline"
  outcome rather than a stuck service.

## To disable / remove

Delete the `systemd.user.services.nixos-autobuild` and
`systemd.user.timers.nixos-autobuild` blocks and the `pkgs.libnotify` line from
`home/default.nix`, then `nh os switch .`. The `~/.cache/nixos-autobuild.diff` log can
be deleted manually.
