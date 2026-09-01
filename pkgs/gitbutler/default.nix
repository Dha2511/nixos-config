{ stdenvNoCC, makeBinaryWrapper, fetchurl, dbus, zlib, lib }:
let
  # Pinned to an immutable release build (not "latest") so the fetch is
  # reproducible. To update: bump version, re-prefetch both hashes.
  version = "0.22.3-3234";
  # GitButler's release host names arches "x86_64" / "aarch64" (no -linux).
  arch = if stdenvNoCC.hostPlatform.isx86_64 then "x86_64" else "aarch64";
  hashes = {
    "x86_64" = "sha256-P09UOmzNkxzmyGxIQFjb5eKUOVl9AB9qCpwo2eUz6hg=";
    "aarch64" = "sha256-MVoL554hxmzXJ4XuR3Xq0Z2qqZKhsixJAiBg/olYHus=";
  };
  # Official prebuilt `but` CLI — the artifact the install.sh script would drop
  # into ~/.local/bin. We fetch it directly rather than run the installer,
  # which is non-hermetic (network + minisig check + writes to $HOME).
  but = fetchurl {
    url = "https://releases.gitbutler.com/releases/release/${version}/linux/${arch}/but";
    sha256 = hashes.${arch};
  };
in
stdenvNoCC.mkDerivation {
  pname = "gitbutler";
  inherit version;

  src = but;
  nativeBuildInputs = [ makeBinaryWrapper ];
  dontUnpack = true;
  dontBuild = true;
  dontConfigure = true;

  installPhase = ''
    # Explicit destination: `install -t` would keep the store's
    # <hash>-but filename instead of installing it as `but`.
    install -Dm755 ${but} $out/bin/but
    # Prebuilt binary is dynamically linked. glibc/libgcc_s resolve from the
    # system; dbus and zlib do not, so point the loader at them or it fails
    # with "error while loading shared libraries" (libdbus-1.so.3 / libz.so.1).
    wrapProgram $out/bin/but \
      --suffix LD_LIBRARY_PATH : "${dbus.lib}/lib:${zlib}/lib"
  '';

  meta = {
    description = "GitButler CLI (but) — official prebuilt binary";
    homepage = "https://gitbutler.com";
    license = lib.licenses.fsl11Mit;
    mainProgram = "but";
    platforms = [ "x86_64-linux" "aarch64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNonNix ];
  };
}
