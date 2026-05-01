{
  description = "stats-me POC: prove Bun can run upstream statsd";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    utils.url = "https://flakehub.com/f/numtide/flake-utils/0.1.102";
    # statsd is vendored under ./vendor/statsd so we can patch it.
    # No more github:statsd/statsd input.
  };

  outputs =
    { self, nixpkgs, utils }:
    utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Pinned upstream Bun release. nixos-25.11 ships bun 1.3.3,
        # which predates the macOS dgram fixes from oven-sh/bun#28083
        # (Mar 2026) — bun 1.3.3 silently drops UDP packets on darwin.
        # 1.3.11 contains the fix; 1.3.12 has a separate regression
        # (#29116). Pin to 1.3.11 explicitly. POC-only; production
        # packaging will revisit how to track Bun.
        bunPlatform =
          {
            "aarch64-darwin" = "darwin-aarch64";
            "x86_64-darwin" = "darwin-x64";
            "aarch64-linux" = "linux-aarch64";
            "x86_64-linux" = "linux-x64";
          }.${system}
            or (throw "bun-1311: unsupported system ${system}");

        bun-1311 = pkgs.stdenvNoCC.mkDerivation rec {
          pname = "bun";
          version = "1.3.11";
          src = pkgs.fetchurl {
            url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-${bunPlatform}.zip";
            # FOD hash. Per-platform; if you build on a different
            # system you'll get a hash mismatch and need to add a
            # branch here. POC ships only the aarch64-darwin hash
            # (the only system tested for this spike).
            hash =
              {
                "aarch64-darwin" = "sha256-b1o0Z+2crsR5W/eM1HZQfZ+HDH1XuGyUX8szgSZ3L/w=";
              }.${system}
                or (throw "bun-1311: hash for ${system} not pinned yet");
          };
          nativeBuildInputs = [ pkgs.unzip ];
          dontBuild = true;
          dontPatchELF = true;
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            install -m 0755 bun $out/bin/bun
            ln -s bun $out/bin/bunx
            runHook postInstall
          '';
        };

        exporel = pkgs.buildGoModule {
          pname = "stats-me-exporel";
          version = "0.0.0";
          src = ./.;
          vendorHash = null;
          subPackages = [ "cmd/stats-me-exporel" ];
          # The vendored statsd tree is part of `src`, so we ship a
          # relative path; the driver resolves it against its own
          # working directory at runtime. (Cleaner than baking an
          # absolute store path during build, since `nix run` will
          # cd into a writable workdir we don't control.)
          ldflags = [
            "-X main.bunPath=${bun-1311}/bin/bun"
            "-X main.statsdSrc=${./vendor/statsd}"
          ];
        };
      in
      {
        packages = {
          default = exporel;
          stats-me-exporel = exporel;
          bun = bun-1311;
        };

        devShells.default = pkgs.mkShell {
          packages = [ bun-1311 pkgs.go ];
        };
      }
    );
}
