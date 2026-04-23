# Celeste — GUI file synchronization client (cloud → local)
# Built from the local checkout at /home/santuzius/Git/celeste.
#
# Reuses the project's shell.nix for build & runtime dependencies so that
# changes in the upstream dev-shell are picked up automatically.
#
# The native-go/ crate normally runs `go build` to produce a static Go
# archive, but the Nix sandbox has no network access so Go cannot fetch
# modules.  The repository ships a pre-built libceleste_native.a — we
# patch build.rs to copy it instead of invoking `go build`.
#
# Because src is an absolute path outside the flake, evaluation requires
# impure mode — invoke `nixos-rebuild switch --flake .#<host> --impure`
# (or test standalone with
#   `nix-build -E 'with import <nixpkgs> {}; callPackage ./. {}'`).
{
  lib,
  pkgs,
  rustPlatform,
  makeWrapper,
  celesteSource ? /home/santuzius/Git/celeste,
}:

let
  # Import the project's own dev-shell to stay in sync with its deps.
  celesteShell = import (celesteSource + "/shell.nix") { inherit pkgs; };

  # buildRustPackage provides its own Rust toolchain, so drop rustc/cargo
  # from the shell's nativeBuildInputs to avoid conflicts.
  filteredNativeBuildInputs = builtins.filter (
    p: !(builtins.elem (p.pname or "") [ "rustc" "cargo" ])
  ) celesteShell.nativeBuildInputs;
in

rustPlatform.buildRustPackage {
  pname = "celeste";
  version = "0.9.0";

  # Filter out build artefacts so rebuilds don't invalidate the store path
  # whenever `cargo build` is run outside of Nix.
  src = lib.cleanSourceWith {
    src = celesteSource;
    name = "celeste-source";
    filter =
      path: type:
      let
        base = baseNameOf (toString path);
      in
      !(builtins.elem base [
        "target"
        "result"
      ]);
  };

  cargoLock = {
    lockFile = celesteSource + "/Cargo.lock";
  };

  postPatch = ''
    # ── Skip the Go build inside native-go/build.rs ──────────────────
    # Replace `go build` with `true` (always succeeds, ignores args),
    # then replace the assertion with commands that copy the pre-built
    # Go archive from the source tree into $OUT_DIR.
    substituteInPlace native-go/build.rs \
      --replace-fail \
        'Command::new("go")' \
        'Command::new("true")'

    substituteInPlace native-go/build.rs \
      --replace-fail \
        'assert!(status.success(), "go build failed");' \
        '// Nix: copy pre-built Go archive (sandbox cannot run go build).
    std::fs::copy(manifest_dir.join("libceleste_native.a"), &lib_path)
        .expect("failed to copy pre-built libceleste_native.a");
    std::fs::copy(manifest_dir.join("libceleste_native.h"), &header_path)
        .expect("failed to copy pre-built libceleste_native.h");'
  '';

  # Required because some dependencies rely on unstable Rust features gated
  # behind RUSTC_BOOTSTRAP.
  RUSTC_BOOTSTRAP = 1;

  nativeBuildInputs = filteredNativeBuildInputs ++ [
    makeWrapper
  ];

  buildInputs = celesteShell.buildInputs;

  # Iced/wgpu needs Vulkan + Wayland + X11 libs at runtime.
  # rclone must be on PATH — celeste spawns it as a subprocess.
  postFixup = ''
    wrapProgram $out/bin/celeste \
      --prefix PATH : "${lib.makeBinPath [ pkgs.rclone ]}" \
      --prefix LD_LIBRARY_PATH : "${celesteShell.LD_LIBRARY_PATH}"
  '';

  # Install the menu entry, icons, metainfo, and an XDG autostart entry.
  # /etc/xdg/autostart is picked up by KDE/GNOME at session start because
  # NixOS links $out/etc/xdg/* into /etc/xdg/ via environment.pathsToLink.
  postInstall = ''
    install -Dm 644 assets/com.hunterwittenborn.Celeste.desktop \
      $out/share/applications/com.hunterwittenborn.Celeste.desktop
    install -Dm 644 assets/com.hunterwittenborn.Celeste-regular.svg \
      $out/share/icons/hicolor/scalable/apps/com.hunterwittenborn.Celeste.svg
    install -Dm 644 assets/com.hunterwittenborn.Celeste.metainfo.xml \
      $out/share/metainfo/com.hunterwittenborn.Celeste.metainfo.xml

    for icon in \
      com.hunterwittenborn.Celeste.CelesteTrayLoading-symbolic.svg \
      com.hunterwittenborn.Celeste.CelesteTraySyncing-symbolic.svg \
      com.hunterwittenborn.Celeste.CelesteTrayWarning-symbolic.svg \
      com.hunterwittenborn.Celeste.CelesteTrayDone-symbolic.svg; do
      install -Dm 644 "assets/context/$icon" \
        "$out/share/icons/hicolor/symbolic/apps/$icon"
    done

    # Reuse the menu .desktop as an XDG autostart entry. Point Exec at the
    # wrapped binary in $out/bin so KDE does not rely on PATH resolution.
    install -Dm 644 assets/com.hunterwittenborn.Celeste.desktop \
      $out/etc/xdg/autostart/com.hunterwittenborn.Celeste.desktop
    substituteInPlace $out/etc/xdg/autostart/com.hunterwittenborn.Celeste.desktop \
      --replace-fail 'Exec=celeste' "Exec=$out/bin/celeste"
  '';

  meta = {
    description = "GUI file synchronization client that can sync with any cloud provider";
    homepage = "https://github.com/Santuzius/celeste-nix";
    license = lib.licenses.gpl3Only;
    mainProgram = "celeste";
    platforms = lib.platforms.linux;
  };
}
