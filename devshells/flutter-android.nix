# Flutter Android devShell. Imported by flake.nix as
# devShells.x86_64-linux.flutter-android — enter with `nix develop .#flutter-android`
# or per-project via direnv (see README "Flutter development").
#
# Why a devShell instead of home.packages: the Android SDK + NDK closure is
# many GB and Google ships linux SDK binaries x86_64-only, so it would bloat
# every host (and be impossible on the aarch64 M2 anyway). The shell keeps
# it opt-in, cached by nix-direnv, and identical across hosts.
#
# NOTE: this shell is x86_64-only by construction — flake.nix only wires it
# into devShells.x86_64-linux. On the M2, target Linux desktop instead.
{ pkgs }:
let
  # Composed Android SDK: platform-tools (adb, fastboot), one build-tools
  # release, the android-36 platform, and the NDK pinned by the flutter
  # template (flutter sets `ndkVersion` in every generated app; AGP tries to
  # auto-install it into the read-only store path otherwise). Flutter 3.44
  # requires SDK >= 36 and buildTools >= 28.0.3. Versions are trivially
  # bumpable here when a project needs newer.
  #
  # extraLicenses: `flutter doctor` runs `sdkmanager --licenses` and counts
  # "N of M SDK package licenses not accepted" — the SDK is a read-only store
  # path, so `flutter doctor --android-licenses` can never persist anything.
  # Accepting every license the repo data knows here (androidenv writes the
  # sha1 hashes into <sdk>/licenses/) is the only way to get that check green
  # on NixOS — and matches `android_sdk.accept_license = true` in flake.nix's
  # pkgsFor, which already signals consent at eval time.
  androidSdk = (pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "36" ];
    buildToolsVersions = [ "36.0.0" ];
    includeNDK = true;
    ndkVersions = [ "28.2.13676358" ];
    # flutter's gradle plugin pins cmake;3.22.1 for debug native builds
    # (configureCMakeDebug) — include it or AGP tries to install it into the
    # read-only store path.
    cmakeVersions = [ "3.22.1" ];
    extraLicenses = [
      "android-sdk-preview-license"
      "android-googletv-license"
      "android-googlexr-license"
      "android-sdk-arm-dbt-license"
      "google-gdk-license"
      "intel-android-extra-license"
      "intel-android-sysimage-license"
      "microxr-sysimage-license"
      "mips-android-sysimage-license"
    ];
  }).androidsdk;

  # AGP (Android Gradle Plugin) tracks specific JDK LTS lines; 21 is the
  # current sweet spot for AGP 8/9.x.
  jdk = pkgs.openjdk21;
in
pkgs.mkShell {
  name = "flutter-android";

  packages = [
    # Self-contained: don't rely on the global home-manager flutter, so the
    # shell also works for other users / CI.
    pkgs.flutter
    jdk
    androidSdk
  ];

  # Gradle and the Flutter tool discover the SDK/JDK through these. Both
  # ANDROID_HOME and ANDROID_SDK_ROOT are set because different tools read
  # different ones (AGP reads the former, some Flutter checks the latter).
  # The composed SDK's real content lives under libexec/android-sdk.
  ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
  ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
  JAVA_HOME = "${jdk}";

  # Two NixOS workarounds live here (both verified against flutter 3.44.4 +
  # the pinned nixpkgs; see README "Flutter development" for background):
  #
  # 1. Gradle's includeBuild. Every flutter app's android/settings.gradle.kts
  #    does includeBuild("$flutterSdkPath/packages/flutter_tools/gradle") —
  #    gradle COMPILES flutter's gradle plugin in place, so that directory
  #    must be writable. The nixpkgs flutter SDK is a read-only store path,
  #    so builds die with "Configuring project with invalid directory".
  #
  # 2. The flutter tool writes flutter.sdk=<its own root> into each app's
  #    local.properties, and derives that root from FLUTTER_ROOT.
  #
  # Fix for both: a mostly-symlink "farm" in ~/.cache with just
  # packages/flutter_tools/gradle materialized writable, plus a bin/flutter
  # wrapper that pins FLUTTER_ROOT to the farm. The farm is rebuilt whenever
  # the underlying store path changes (stamp check), so nixpkgs upgrades
  # invalidate it automatically. Cost: ~10 MB and one plugin compile per SDK
  # bump; everything else stays a symlink.
  shellHook = ''
    sdkRoot="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
    farm="''${FLUTTER_FARM_DIR:-$HOME/.cache/flutter-writable}"
    if [ ! -f "$farm/.farm-stamp" ] || [ "$(cat "$farm/.farm-stamp")" != "$sdkRoot" ]; then
      chmod -R u+w "$farm" 2>/dev/null || true
      rm -rf "$farm"
      mkdir -p "$farm/packages/flutter_tools" "$farm/bin"

      # Everything except packages/ and bin/ stays a top-level symlink.
      find "$sdkRoot" -maxdepth 1 -mindepth 1 \
        ! -name packages ! -name bin -exec ln -s {} "$farm/" \;

      # packages/: symlink all but flutter_tools, whose gradle/ subdir is the
      # one thing gradle must write into — dereference-copy it writable.
      find "$sdkRoot/packages" -maxdepth 1 -mindepth 1 \
        ! -name flutter_tools -exec ln -s {} "$farm/packages/" \;
      find "$sdkRoot/packages/flutter_tools" -maxdepth 1 -mindepth 1 \
        ! -name gradle -exec ln -s {} "$farm/packages/flutter_tools/" \;
      cp -L -r "$sdkRoot/packages/flutter_tools/gradle" "$farm/packages/flutter_tools/gradle"
      chmod -R u+w "$farm/packages/flutter_tools/gradle"

      # bin/: symlink all but `flutter`, which becomes a wrapper pinning
      # FLUTTER_ROOT to the farm so apps' local.properties point gradle at
      # the writable copy.
      find "$sdkRoot/bin" -maxdepth 1 -mindepth 1 \
        ! -name flutter -exec ln -s {} "$farm/bin/" \;
      printf '#!/bin/sh\nexport FLUTTER_ROOT=%s\nexec %s/bin/flutter "$@"\n' \
        "$farm" "$sdkRoot" > "$farm/bin/flutter"
      chmod +x "$farm/bin/flutter"

      printf '%s' "$sdkRoot" > "$farm/.farm-stamp"
    fi

    export FLUTTER_ROOT="$farm"
    export PATH="$farm/bin:$PATH"
  '';
}
