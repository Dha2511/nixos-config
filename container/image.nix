# Dev-container image: the headless home tier (Blender CLI, ComfyUI, Unsloth,
# vLLM via uv, full CLI/dev setup) plus a flakes-enabled nix, packaged for
# podman. Built on any host with nix, loaded into podman:
#
#   nix build --extra-experimental-features "nix-command flakes" .#container-image -o result-container
#   ./result-container | podman load
#   container/run.sh                    # sane defaults (GPU, mounts, ports)
#   podman exec -it lab-dev zsh         # enter over SSH to the host
#
# Design notes:
# - The home environment is MATERIALIZED INTO THE IMAGE: home-manager is
#   evaluated standalone (flake.nix wraps ./home with isContainer=true) and
#   the activation package ships in the image. The entrypoint syncs
#   home-files into the (bind-mounted) /home/bob on start — no runtime nix
#   evaluation, so container start is offline and instant. Updating the env =
#   rebuild the image + recreate the container; bootstrapped state
#   (~/.vllm, ~/comfy, ~/.unsloth, models) lives in the home volume and
#   survives recreation.
# - nix inside the container exists for PROJECT work (direnv flakes, uv,
#   nixpkgs#...). sandbox = false: an unprivileged/rootless container cannot
#   create build user-namespaces. Acceptable for a trusted dev image.
# - A nix registry pins `nixpkgs` to the flake's locked source (also baked
#   into the image), so `nixpkgs#...` resolves offline.
# - GPU: the host injects driver libs + device nodes via the NVIDIA container
#   toolkit (CDI, `--device nvidia.com/gpu=all`). The entrypoint links the
#   injected lib dir to /run/opengl-driver/lib — the exact path every
#   launcher in home/scripts.nix already expects — so blender/comfyui/
#   unsloth/vllm work in the container with zero script changes.

{ pkgs, hm, nixpkgsSrc }:

let
  inherit (pkgs) lib;

  user = "bob";
  homeDir = "/home/bob";

  # Standalone home-manager activation package (from flake.nix). Its
  # `home-files/` mirrors $HOME contents; `home-path/` is the env of all
  # home.packages. Including it in `contents` pulls the entire user
  # environment closure into the image.
  activation = hm.home.activationPackage;

  # Full locale archive — the image's glibc ships no compiled locales.
  localeArchive = "${pkgs.glibcLocales}/lib/locale/locale-archive";

  # Pin the `nixpkgs` registry entry to the flake's locked source, which is
  # baked into the image (see contents). Keeps `nixpkgs#hello`, default
  # registry lookups and project flakes that reference `nixpkgs` offline.
  # Schema: flake registry v2 ("flakes" list).
  nixRegistry = pkgs.writeText "registry.json" (builtins.toJSON {
    version = 2;
    flakes = [
      {
        from = { type = "indirect"; id = "nixpkgs"; };
        to = { type = "path"; path = nixpkgsSrc; };
      }
    ];
  });

  # Container entrypoint: GPU shim + home materialization. Runs on every
  # `podman run`; `podman exec` skips it (image Env carries the essentials).
  # With explicit args (e.g. `podman run -it lab-dev zsh`) it execs them
  # instead of the keep-alive sleep.
  entrypoint = pkgs.writeShellScriptBin "entrypoint" ''
    set -euo pipefail
    export HOME=${homeDir}
    export XDG_RUNTIME_DIR=/tmp/xdg-runtime
    mkdir -p "$XDG_RUNTIME_DIR" "$HOME/.local/bin" "$HOME/.cache/lab-container"
    chmod 700 "$XDG_RUNTIME_DIR"

    # --- GPU shim ----------------------------------------------------------
    # Link the NVIDIA container toolkit's injected driver lib dir to the path
    # every launcher in home/scripts.nix expects. Skipped when no driver was
    # injected (plain CPU run) — a dangling /run/opengl-driver/lib is
    # harmless: LD_LIBRARY_PATH entries that don't resolve are ignored.
    libcuda=""
    for d in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib /usr/local/nvidia/lib; do
      if [ -e "$d/libcuda.so.1" ]; then libcuda="$d"; break; fi
    done
    if [ -n "$libcuda" ]; then
      mkdir -p /run/opengl-driver
      ln -sfn "$libcuda" /run/opengl-driver/lib
      echo "container: GPU driver libs at $libcuda -> /run/opengl-driver/lib"
    fi

    # --- Materialize the home environment ----------------------------------
    # Idempotent: only (re)copies when the baked activation differs from what
    # the home volume already has. Managed files are overwritten in place;
    # hand-edits to managed paths are lost on env updates (rebuild+recreate is
    # the update path), while bootstrapped state (~/.vllm, ~/comfy, ~/.unsloth)
    # is never touched.
    marker="$HOME/.cache/lab-container/home-version"
    if [ ! -f "$marker" ] || [ "$(cat "$marker")" != "${activation}" ]; then
      echo "container: materializing home-manager environment"
      echo "container:   ${activation}"
      cp -a ${activation}/home-files/. "$HOME/"
      # Store paths ship read-only (dirs 555, files 444) — copied verbatim by
      # cp -a that would leave the home unwritable even for the container
      # root. Give the owning user back rw on everything (X: +x only where
      # already a dir / executable).
      chmod -R u+rwX "$HOME"
      ln -sfn ${activation}/home-path "$HOME/.nix-profile"
      printf '%s' "${activation}" > "$marker"
    fi

    # Interactive use: `podman run -it lab-dev zsh` execs the args; detached
    # (`podman run -d`) sleeps forever so `podman exec` can attach.
    if [ "$#" -gt 0 ]; then
      exec "$@"
    fi
    exec ${pkgs.coreutils}/bin/sleep infinity
  '';
in
pkgs.dockerTools.streamLayeredImage {
  name = "lab-dev";
  tag = "latest";
  created = "now";

  # nix (project flakes + registry), the shell/toolchain baseline, and the
  # whole home-manager user environment closure.
  contents = with pkgs; [
    nix
    bashInteractive
    zsh
    coreutils
    # Core Unix tools users/scripts expect on PATH. home-path carries the
    # home.packages tier; these fill the classic-tooling gap around it.
    gnugrep
    gnused
    findutils
    gawk
    diffutils
    less
    gzip
    bzip2
    xz
    cacert
    glibcLocales
    dockerTools.usrBinEnv # /usr/bin/env
    dockerTools.binSh     # /bin/sh
    nixpkgsSrc            # locked nixpkgs source for the offline registry
    activation
  ];

  # Static /etc for the container: users, nix.conf, nsswitch, CA bundle.
  extraCommands = ''
    mkdir -p etc/nix etc/ssl/certs home/bob tmp root
    chmod 1777 tmp
    cat > etc/passwd <<'EOF_PASSWD'
    root:x:0:0:root:/root:/bin/sh
    bob:x:1000:1000::/home/bob:/bin/sh
    EOF_PASSWD
    cat > etc/group <<'EOF_GROUP'
    root:x:0:
    users:x:100:bob
    nogroup:x:65534:
    EOF_GROUP
    cat > etc/nix/nix.conf <<'EOF_NIXCONF'
    experimental-features = nix-command flakes
    # Rootless containers cannot create build user-namespaces.
    sandbox = false
    # No nixbld group exists in the container; root runs builds directly.
    build-users-group =
    auto-optimise-store = true
    show-trace = true
    EOF_NIXCONF
    cat > etc/nsswitch.conf <<'EOF_NSS'
    hosts: files dns
    EOF_NSS
    ln -s ${nixRegistry} etc/nix/registry.json
  '';

  config = {
    Env = [
      "HOME=${homeDir}"
      "USER=${user}"
      "LANG=en_DK.UTF-8"
      "LOCALE_ARCHIVE=${localeArchive}"
      "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      # Project flakes with unfree deps just work (dev-image convenience).
      "NIXPKGS_ALLOW_UNFREE=1"
      "XDG_RUNTIME_DIR=/tmp/xdg-runtime"
      # glibc.bin/bin carries locale/iconv/ldd (this glibc's out output has no bin).
      "PATH=${homeDir}/.nix-profile/bin:${homeDir}/.local/bin:${pkgs.nix}/bin:${pkgs.coreutils}/bin:${pkgs.glibc.bin}/bin:${pkgs.gnugrep}/bin:${pkgs.gnused}/bin:${pkgs.findutils}/bin:${pkgs.gawk}/bin:${pkgs.diffutils}/bin:${pkgs.less}/bin:${pkgs.gzip}/bin:${pkgs.bzip2}/bin:${pkgs.xz}/bin:${pkgs.bashInteractive}/bin:${pkgs.zsh}/bin"
    ];
    WorkingDir = homeDir;
    Entrypoint = [ "${entrypoint}/bin/entrypoint" ];
    Cmd = [
      "${pkgs.coreutils}/bin/sleep"
      "infinity"
    ];
  };
}
