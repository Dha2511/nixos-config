# Official ChatGPT Linux desktop app (closed-source Electron, preview build).
# Vendor of NixOS/nixpkgs PR #551713 ("chatgpt: support linux"), adapted to
# this repo's single-file package style and bumped to 26.1002.51308.
#
# Version/source tracking: OpenAI publishes immutable versioned .deb files
# (never the mutable `latest/` path) per architecture:
#   <dir>/dists/stable/main/binary-amd64/Packages.gz  (and binary-arm64)
# To update: bump `version`, re-prefetch both .deb hashes.
#
# Why all the plumbing (beyond dpkg-deb + autoPatchelfHook):
#   - autoPatchelf relocates PT_INTERP past detect-libc's 2 KiB scan window; its
#     process.report fallback then trips Electron CFI -> SIGILL in the git repo
#     watcher (@parcel/watcher). The app.asar patch forces the glibc watcher.
#   - Electron dlopens several libs at runtime (libGL/libsecret/pipewire/...);
#     those go in `runtimeDependencies` (RPATH), not just buildInputs.
#   - Bundled plugin manifests are rewritten by Electron, so they need a
#     writable copy; the launcher stages one in $XDG_CACHE_HOME.
#   - Wayland flags must be built per-session (NIXOS_OZONE_WL && WAYLAND_DISPLAY),
#     not via literal `${…:+…}` in makeWrapper --add-flags (that was a bug in the
#     earlier NUR derivation).
{ lib
, stdenv
, fetchurl
, dpkg
, autoPatchelfHook
, makeWrapper
, wrapGAppsHook3
, qt6
, writeShellApplication
, flock
  # Electron runtime build inputs
, alsa-lib
, at-spi2-atk
, at-spi2-core
, atk
, cairo
, cups
, dbus
, dconf
, expat
, gdk-pixbuf
, glib
, gtk3
, libgbm
, libnotify
, libusb1
, libx11
, libxcb
, libxcomposite
, libxdamage
, libxext
, libxfixes
, libxkbcommon
, libxrandr
, nspr
, nss
, pango
, systemdLibs
  # Runtime deps
, bubblewrap
, coreutils
, gitMinimal
, libGL
, libpulseaudio
, libsecret
, lsb-release
, nodejs-slim
, pipewire
, ripgrep
, tectonic-unwrapped
, vulkan-loader
, xdg-utils
  # Set to pkgs.codex to swap in the nixpkgs-pinned CLI for the Codex panel;
  # null keeps the codex CLI the app bundles.
, codex ? null
}:

let
  version = "26.1002.51308";

  inherit (stdenv.hostPlatform.node) arch;

  sources = {
    x86_64-linux = {
      url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${version}_amd64.deb";
      sha256 = "sha256-zlmmG5Te9JzJIdaU75Uh7BdOuLZf2wwoXjuo5FIxoh8=";
    };
    aarch64-linux = {
      url = "https://persistent.oaistatic.com/codex-app-prod/linux/deb/pool/main/c/chatgpt/chatgpt_${version}_arm64.deb";
      sha256 = "sha256-+S77ypCqNC2L+T+bpY7HUuz4DJ4pHCC6Rd7k2i39xSk=";
    };
  };

  source = sources.${stdenv.hostPlatform.system}
    or (throw "chatgpt is not supported on ${stdenv.hostPlatform.system}");

  # The app needs a writable copy of its bundled plugins (Electron rewrites
  # their manifests at runtime, which fails in the read-only store). This
  # launcher keeps them on the main binary, not on the wrapped wrapper, so
  # `chatgpt` in the desktop entry and `nix run` behave identically.
  launcher = writeShellApplication {
    name = "chatgpt-launcher";
    runtimeInputs = [ flock ];
    text = ''
      : "''${CHATGPT_EXECUTABLE:?}"
      : "''${CHATGPT_RESOURCES_SOURCE:?}"
      : "''${CHATGPT_RESOURCES_CACHE_LABEL:?}"

      cacheHome="''${XDG_CACHE_HOME:-''${HOME:?XDG_CACHE_HOME and HOME are unset}/.cache}"
      cacheRoot="$cacheHome/chatgpt/bundled-plugins"
      resourcesSourceHash=$(printf '%s' "$CHATGPT_RESOURCES_SOURCE" | sha256sum)
      resourcesSourceHash="''${resourcesSourceHash%% *}"
      cacheKey="$CHATGPT_RESOURCES_CACHE_LABEL-$resourcesSourceHash"
      resourcesPath="$cacheRoot/$cacheKey"

      mkdir -p "$cacheRoot/.locks"
      resourcesLockPath="$cacheRoot/.locks/$cacheKey.lock"
      exec {resourcesLockFd}> "$resourcesLockPath"
      flock --shared "$resourcesLockFd"

      stagingLockPath="$cacheRoot/.locks/staging-v1.lock"
      exec {stagingCleanupLockFd}> "$stagingLockPath"
      if flock --exclusive --nonblock "$stagingCleanupLockFd"; then
        for abandonedStagingPath in "$cacheRoot"/.chatgpt-staging-v1-*; do
          if [[ -d "$abandonedStagingPath" ]] && ! rm -rf -- "$abandonedStagingPath"; then
            echo "Failed to remove abandoned ChatGPT bundled-plugin staging directory: $abandonedStagingPath" >&2
          fi
        done
      fi
      exec {stagingCleanupLockFd}>&-

      requiredResourcePaths=()
      for requiredResourceName in codex codex-code-mode-host cua_node native rg; do
        requiredResourcePath="$CHATGPT_RESOURCES_SOURCE/$requiredResourceName"
        if [[ ! -e "$requiredResourcePath" ]]; then
          echo "Missing ChatGPT bundled-plugin resource: $requiredResourcePath" >&2
          exit 1
        fi
        requiredResourcePaths+=("$requiredResourcePath")
      done

      if [[ -d "$CHATGPT_RESOURCES_SOURCE/tectonic" ]]; then
        requiredResourcePaths+=("$CHATGPT_RESOURCES_SOURCE/tectonic")
      fi

      if [[ ! -f "$resourcesPath/.complete" ]]; then
        exec {stagingWriterLockFd}> "$stagingLockPath"
        flock --shared "$stagingWriterLockFd"
        stagingPath=$(mktemp -d "$cacheRoot/.chatgpt-staging-v1-$cacheKey.XXXXXXXX")
        trap 'rm -rf -- "$stagingPath"' EXIT

        ln -s "''${requiredResourcePaths[@]}" "$stagingPath"
        cp -R "$CHATGPT_RESOURCES_SOURCE/plugins" "$stagingPath/plugins"
        chmod -R u+w "$stagingPath/plugins"
        touch "$stagingPath/.complete"

        # Flush the payload and commit marker before exposing the cache atomically.
        sync --file-system "$stagingPath"

        if mv -T "$stagingPath" "$resourcesPath" 2>/dev/null; then
          sync --file-system "$cacheRoot"
          trap - EXIT
        elif [[ -f "$resourcesPath/.complete" ]]; then
          rm -rf -- "$stagingPath"
          trap - EXIT
        else
          echo "Failed to publish ChatGPT's writable bundled-plugin resources" >&2
          exit 1
        fi
        exec {stagingWriterLockFd}>&-
      fi

      # Only lock-aware published caches can be removed safely.
      for obsoletePath in "$cacheRoot"/*; do
        if [[ "$obsoletePath" != "$resourcesPath" && -f "$obsoletePath/.complete" ]]; then
          obsoleteKey="''${obsoletePath##*/}"
          obsoleteLockPath="$cacheRoot/.locks/$obsoleteKey.lock"

          # Caches without a lock predate this protocol and may still be in use.
          if [[ -f "$obsoleteLockPath" ]]; then
            exec {obsoleteLockFd}> "$obsoleteLockPath"
            if flock --exclusive --nonblock "$obsoleteLockFd"; then
              if ! rm -rf -- "$obsoletePath"; then
                echo "Failed to remove obsolete ChatGPT bundled-plugin cache: $obsoletePath" >&2
              fi
            fi
            exec {obsoleteLockFd}>&-
          fi
        fi
      done

      export CODEX_ELECTRON_BUNDLED_PLUGINS_RESOURCES_PATH="$resourcesPath"

      waylandFlags=()
      if [[ -n "''${NIXOS_OZONE_WL:-}" && -n "''${WAYLAND_DISPLAY:-}" ]]; then
        waylandFlags=(
          --ozone-platform=wayland
          --enable-features=WaylandWindowDecorations
          --enable-wayland-ime=true
        )
      fi

      exec "$CHATGPT_EXECUTABLE" "''${waylandFlags[@]}" "$@"
    '';
  };
in
stdenv.mkDerivation {
  pname = "chatgpt";
  inherit version;

  src = fetchurl {
    inherit (source) url sha256;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    dpkg
    makeWrapper
    qt6.wrapQtAppsHook
    wrapGAppsHook3
  ];

  buildInputs = [
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    cairo
    cups
    dbus
    dconf
    expat
    gdk-pixbuf
    glib
    gtk3
    libgbm
    libnotify
    libusb1
    libx11
    libxcb
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxkbcommon
    libxrandr
    nspr
    nss
    pango
    qt6.qtbase
    stdenv.cc.cc.lib
    systemdLibs
  ];

  # Electron dlopens these at runtime; autoPatchelfHook alone can't see them,
  # so they get baked into the RPATH.
  runtimeDependencies = [
    libGL
    libnotify
    libpulseaudio
    libsecret
    pipewire
    vulkan-loader
  ];

  # We set the app's wrapper args manually in postFixup, so the generic hooks
  # must not double-wrap (they'd take their own process away from the launcher).
  dontWrapGApps = true;
  dontWrapQtApps = true;

  # dpkg-deb extracts to a top-level `root/` (usr/, opt/, share/, ...). Older
  # nixpkgs revs have no automatic `.deb` unpack handler, hence the explicit
  # unpackPhase + sourceRoot.
  unpackPhase = ''
    runHook preUnpack
    dpkg-deb -x "$src" root
    runHook postUnpack
  '';

  sourceRoot = "root";

  postPatch = ''
    # Force the glibc watcher (see header comment re: detect-libc + CFI).
    grep -aFq 'const family = familySync();' usr/lib/chatgpt/resources/app.asar
    sed -i "s|const family = familySync();|const family = 'glibc'     ;|" usr/lib/chatgpt/resources/app.asar
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    cp -r usr/* "$out"

    # Remove the unused Qt 5 fallback shim.
    rm -f "$out/lib/chatgpt/libqt5_shim.so"

    # Keep only the native prebuild for this platform and architecture, and
    # drop the musl prebuilds (autoPatchelf cannot resolve their deps).
    resources="$out/lib/chatgpt/resources"
    find "$resources" -type d -name prebuilds -print0 | while IFS= read -r -d "" prebuildsPath; do
      find "$prebuildsPath" -mindepth 1 -maxdepth 1 \
        ! -name "*linux-${arch}" \
        -exec rm -rf -- {} +
    done
    find "$resources" -type f -name '*.musl.node' -delete

    # Substitute store-pinned tools for the ones the app bundles (the store
    # ones are already patched into the same glibc), so autoPatchelf and the
    # loader don't fight over them.
    mkdir -p "$resources/tectonic"
    ln -sf ${lib.getExe tectonic-unwrapped} "$resources/tectonic/tectonic"
    ln -sf ${lib.getExe ripgrep} "$resources/rg"
    mkdir -p "$resources/cua_node/bin"
    ln -sf ${lib.getExe nodejs-slim} "$resources/cua_node/bin/node"

    install -Dm755 ${launcher}/bin/chatgpt-launcher "$out/bin/chatgpt"

    runHook postInstall
  '';

  postFixup = ''
    wrapProgram "$out/bin/chatgpt" \
      "''${gappsWrapperArgs[@]}" \
      "''${qtWrapperArgs[@]}" \
      --set CHATGPT_EXECUTABLE "$out/lib/chatgpt/ChatGPT" \
      --set CHATGPT_RESOURCES_SOURCE "$out/lib/chatgpt/resources" \
      --set CHATGPT_RESOURCES_CACHE_LABEL "${version}-${stdenv.hostPlatform.system}" \
      --prefix PATH : ${
        lib.makeBinPath [
          bubblewrap
          coreutils
          gitMinimal
          lsb-release
          nodejs-slim
          xdg-utils
        ]
      } \
      --set-default CODEX_BROWSER_USE_NODE_PATH ${lib.getExe nodejs-slim} \
      --set-default NODE_REPL_NODE_PATH ${lib.getExe nodejs-slim}
  '';

  dontStrip = true;

  meta = {
    description = "Desktop application for the ChatGPT / Codex app (official Linux build)";
    homepage = "https://developers.openai.com/codex/app";
    changelog = "https://learn.chatgpt.com/docs/changelog";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    mainProgram = "chatgpt";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}