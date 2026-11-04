{
  description = "SDL3 dev shell (C build + TLA+/Lean formal verification tools)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        # x86_64-darwin is no longer supported by nixpkgs-unstable (26.11).
        "aarch64-darwin"
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          inherit (pkgs) lib stdenv;
          # Optional backends SDL's CMake probes for on Linux. On macOS SDL only
          # needs the system frameworks from the SDK.
          linuxLibs = with pkgs; [
            libx11
            libxext
            libxcursor
            libxrandr
            libxi
            libxkbcommon
            wayland
            wayland-scanner
            libdecor
            libGL
            libdrm
            libgbm
            alsa-lib
            libpulseaudio
            pipewire
            dbus
            systemdLibs # libudev
          ];
        in
        {
          default = pkgs.mkShell.override { stdenv = pkgs.clangStdenv; } {
            packages = [
              pkgs.cmake
              pkgs.ninja
              pkgs.pkg-config
              pkgs.python3 # src/dynapi/gendynapi.py, build-scripts/*.py
              pkgs.perl # build-scripts/*.pl
              pkgs.llvmPackages.clang-tools # clang-format, clangd
              pkgs.ccache

              # Formal verification (verification/)
              pkgs.tlaplus # tlc, tlasany, pcal
              pkgs.elan # Lean toolchain manager; the version is pinned by verification/lean/lean-toolchain
            ]
            ++ lib.optionals stdenv.hostPlatform.isLinux linuxLibs;
          };
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
