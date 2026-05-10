# Celeste — GUI file synchronization client (cloud → local)
# Built from a local checkout of the Celeste source tree. Defaults to a
# sibling directory under $HOME/Git (i.e. ~/Git/celeste) so that cloning
# this repo alongside celeste/ "just works":
#
#   ~/Git/celeste        ← source checkout
#   ~/Git/celeste-nix    ← this repo
#
# Callers that hold the source elsewhere should pass `celesteSource`
# explicitly (e.g. from a NixOS flake module).
#
# Reuses the project's shell.nix for build & runtime dependencies so that
# changes in the upstream dev-shell are picked up automatically.
#
# The native-go/ crate normally runs `go build` to produce a static Go
# archive, but the Nix sandbox has no network access so Go cannot fetch
# modules.  The repository ships a pre-built libceleste_go.a — we
# patch build.rs to copy it instead of invoking `go build`.
#
# Because src resolves to a path outside the Nix store, evaluation
# requires impure mode — invoke `nixos-rebuild switch --flake .#<host>
# --impure` (or test standalone with
#   `nix-build -E 'with import <nixpkgs> {}; callPackage ./. {}' --impure`).
{
  lib,
  pkgs,
  rustPlatform,
  makeWrapper,
  # Nix path (not string) — required by cargoLock.lockFile and
  # lib.cleanSourceWith.src below. `/. + "…"` coerces the interpolated
  # $HOME string into a path literal.
  celesteSource ? /. + "${builtins.getEnv "HOME"}/Git/celeste",
}:

let
  # Import the project's own dev-shell to stay in sync with its deps.
  celesteShell = import (celesteSource + "/shell.nix") { inherit pkgs; };

  # buildRustPackage provides its own Rust toolchain, so drop rustc/cargo
  # from the shell's nativeBuildInputs to avoid conflicts.
  filteredNativeBuildInputs = builtins.filter (
    p: !(builtins.elem (p.pname or "") [ "rustc" "cargo" ])
  ) celesteShell.nativeBuildInputs;

  # The upstream tree no longer ships a .desktop file — generate one
  # here so the menu entry and the XDG autostart hook still work.
  # `Exec=celeste` is rewritten to the wrapped binary in $out/bin
  # for the autostart copy below.
  desktopFile = pkgs.writeText "Celeste.desktop" ''
    [Desktop Entry]
    Type=Application
    Name=Celeste
    GenericName=File Synchronization Client
    Comment=Sync local folders with Google Drive or Proton Drive
    Exec=celeste
    Icon=celeste-icon
    Terminal=false
    Categories=Utility;FileTransfer;Network;
    StartupNotify=true
    StartupWMClass=celeste
    Keywords=sync;cloud;backup;rclone;
  '';
in

rustPlatform.buildRustPackage {
  pname = "celeste";
  version = "0.14.0";

  # Filter out build artefacts *and* VCS/editor cruft so rebuilds don't
  # invalidate the store path whenever `cargo build` runs outside Nix or
  # `.git/` changes (commits, fetches, even the odd index stat).
  # lib.cleanSourceFilter drops .git, editor backups, and result symlinks.
  src = lib.cleanSourceWith {
    src = celesteSource;
    name = "celeste-source";
    filter =
      path: type:
      lib.cleanSourceFilter path type
      && !(builtins.elem (baseNameOf (toString path)) [
        "target"
        "result"
      ]);
  };

  cargoLock = {
    lockFile = celesteSource + "/Cargo.lock";
  };

  postPatch = ''
    # ── Skip the Go build inside src/go/build.rs ──────────────────
    # Replace `go build` with `true` (always succeeds, ignores args),
    # then replace the assertion with commands that copy the pre-built
    # Go archive from the source tree into $OUT_DIR.
    substituteInPlace src/go/build.rs \
      --replace-fail \
        'Command::new("go")' \
        'Command::new("true")'

    substituteInPlace src/go/build.rs \
      --replace-fail \
        'assert!(status.success(), "go build failed");' \
        '// Nix: copy pre-built Go archive (sandbox cannot run go build).
    std::fs::copy(manifest_dir.join("libceleste_go.a"), &lib_path)
        .expect("failed to copy pre-built libceleste_go.a");
    std::fs::copy(manifest_dir.join("libceleste_go.h"), &header_path)
        .expect("failed to copy pre-built libceleste_go.h");'
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

  # Install the menu entry, icon, and an XDG autostart entry.
  # /etc/xdg/autostart is picked up by KDE/GNOME at session start because
  # NixOS links $out/etc/xdg/* into /etc/xdg/ via environment.pathsToLink.
  # Tray pixmaps and the metainfo file no longer ship in assets/ — the
  # tray icons are embedded via icondata at build time, and metainfo is
  # only relevant to the upstream Flatpak/AppStream build.
  postInstall = ''
    install -Dm 644 ${desktopFile} \
      $out/share/applications/Celeste.desktop
    install -Dm 644 assets/celeste-icon.svg \
      $out/share/icons/hicolor/scalable/apps/celeste-icon.svg

    # Reuse the menu .desktop as an XDG autostart entry. Point Exec at the
    # wrapped binary in $out/bin so KDE does not rely on PATH resolution.
    install -Dm 644 ${desktopFile} \
      $out/etc/xdg/autostart/Celeste.desktop
    substituteInPlace $out/etc/xdg/autostart/Celeste.desktop \
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
