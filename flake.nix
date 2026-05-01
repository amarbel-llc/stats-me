{
  description = "stats-me: personal statsd as a home-manager module, run under Bun";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    utils.url = "https://flakehub.com/f/numtide/flake-utils/0.1.102";
    # amarbel-llc/nixpkgs is a flake-as-source-tree input — we want
    # the bun2nix build-support helpers (specifically
    # buildZxScriptFromFile) for packaging cli/stats-me-query.ts.
    # We do NOT apply its overlay; instead we callPackage the helper
    # directly. flake = false because we just need the source files.
    nixpkgs-amarbel = {
      url = "github:amarbel-llc/nixpkgs";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, nixpkgs-amarbel, utils }:
    let
      # Home-manager modules are system-independent and exported at
      # the top level so consumers can wire
      # `inputs.stats-me.homeManagerModules.stats-me` directly. Same
      # shape as amarbel-llc/piggy's flake.
      #
      # Two modules live here:
      #   - stats-me: the statsd daemon (always usable on its own)
      #   - stats-me-vm: optional VictoriaMetrics for persistent
      #     time-series storage. Disabled by default. When enabled,
      #     stats-me auto-routes its graphite backend at VM's
      #     graphite-listener address — see autowireVictoriaMetrics
      #     option in stats-me.nix for the wiring rule.
      homeManagerModules = {
        stats-me = import ./nix/hm/stats-me.nix;
        stats-me-vm = import ./nix/hm/victoriametrics.nix;
      };
    in
    {
      inherit homeManagerModules;
    }
    // utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # bun2nix helpers from amarbel-llc/nixpkgs, hand-wired without
        # the overlay. We callPackage the build-support paths
        # directly so the rest of pkgs stays untouched.
        cacheEntryCreator = pkgs.callPackage
          "${nixpkgs-amarbel}/pkgs/build-support/bun2nix/cache-entry-creator"
          { };
        bun2nix = pkgs.callPackage
          "${nixpkgs-amarbel}/pkgs/build-support/bun2nix"
          {
            inherit cacheEntryCreator;
            bun = bun-pinned;
          };

        # Bun pinned to an upstream release. nixos-25.11 ships
        # bun-1.3.3, which silently drops the first UDP packet after
        # `bind()` on darwin (oven-sh/bun#28083 area). 1.3.11 is the
        # first release with the relevant macOS dgram fixes; 1.3.12
        # has a separate Linux regression (#29116). Pin to 1.3.11
        # explicitly until nixpkgs catches up.
        bunPlatform =
          {
            "aarch64-darwin" = "darwin-aarch64";
            "x86_64-darwin" = "darwin-x64";
            "aarch64-linux" = "linux-aarch64";
            "x86_64-linux" = "linux-x64";
          }
          .${system}
            or (throw "stats-me bun pin: unsupported system ${system}");

        bun-pinned = pkgs.stdenvNoCC.mkDerivation rec {
          pname = "bun";
          version = "1.3.11";
          src = pkgs.fetchurl {
            url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-${bunPlatform}.zip";
            # Per-platform FOD hash. Add a branch when porting to
            # another system; nix prints the right hash on first
            # build.
            hash =
              {
                "aarch64-darwin" = "sha256-b1o0Z+2crsR5W/eM1HZQfZ+HDH1XuGyUX8szgSZ3L/w=";
              }
              .${system}
                or (throw "stats-me bun pin: hash for ${system} not pinned yet");
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

        stats-me = pkgs.callPackage ./default.nix {
          bun = bun-pinned;
        };

        # Bun-runtime zx script wrapping VM's HTTP query endpoints.
        # Default VM URL is http://127.0.0.1:8428 — same as VM's
        # default httpListenAddr — but $STATS_ME_VM_URL or
        # --vm-url=URL override that. The HM module sets
        # STATS_ME_VM_URL automatically when stats-me-vm is enabled
        # and autowired (TODO: actually do this in stats-me.nix).
        stats-me-query = bun2nix.buildZxScriptFromFile {
          pname = "stats-me-query";
          version = "0.1.0";
          script = ./cli/stats-me-query.ts;
        };
      in
      {
        packages = {
          default = stats-me;
          stats-me = stats-me;
          stats-me-query = stats-me-query;
          bun = bun-pinned;
        };

        devShells.default = pkgs.mkShell {
          packages = [
            bun-pinned
            stats-me-query
          ];
        };

        # Smoke-build check: ensures the package and its bun
        # dependency continue to build. The HM module's eval is
        # validated separately by `nix flake check` consumers.
        checks = {
          stats-me = stats-me;
          stats-me-query = stats-me-query;
        };
      }
    );
}
