{
  description = "stats-me: personal statsd as a home-manager module, run under Bun";

  inputs = {
    # Main nixpkgs is the amarbel-llc fork — same source as every
    # other amarbel-llc/* moxin in the eng stack, so stats-me's closure
    # converges with the rest instead of pulling a parallel toolchain
    # from the nixos-25.11 channel. The fork's overlays.default applies
    # automatically; stats-me doesn't use anything the overlay would
    # conflict with (no Go, no bun2nix wrapper — we callPackage the
    # bun2nix helper directly from the source tree below). The bun
    # override later in this file is independent of which nixpkgs is
    # used.
    nixpkgs.url = "github:amarbel-llc/nixpkgs";
    # nixpkgs-master is the SHA-pinned anchor that eng's update-nix-
    # repos recipe cascades. Unused in outputs — left declared so the
    # cascade can see and update a pinned ref.
    nixpkgs-master.url = "github:NixOS/nixpkgs/d233902339c02a9c334e7e593de68855ad26c4cb";
    utils.url = "https://flakehub.com/f/numtide/flake-utils/0.1.102";
  };

  outputs =
    { self, nixpkgs, utils, ... }:
    let
      # Home-manager modules are system-independent and exported at
      # the top level so consumers can wire
      # `inputs.stats-me.homeManagerModules.stats-me` directly. Same
      # shape as amarbel-llc/piggy's flake.
      #
      # Two modules live here:
      #   - stats-me: the statsd daemon (always usable on its own)
      #   - stats-me-victoria-metrics: optional VictoriaMetrics for
      #     persistent time-series storage. Disabled by default. When
      #     enabled, stats-me auto-routes its graphite backend at
      #     VictoriaMetrics's
      #     graphite-listener address — see autowireVictoriaMetrics
      #     option in stats-me.nix for the wiring rule.
      homeManagerModules = {
        stats-me = import ./nix/hm/stats-me.nix;
        stats-me-victoria-metrics = import ./nix/hm/victoria-metrics.nix;
      };
    in
    {
      inherit homeManagerModules;
    }
    // utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # bun2nix helpers from the source tree of the amarbel-llc fork
        # (now also the main nixpkgs above). callPackage the build-
        # support paths directly so we use the exact version pinned
        # by stats-me's lock rather than whatever the overlay exposes.
        cacheEntryCreator = pkgs.callPackage
          "${nixpkgs}/pkgs/build-support/bun2nix/cache-entry-creator"
          { };
        bun2nix = pkgs.callPackage
          "${nixpkgs}/pkgs/build-support/bun2nix"
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
        #
        # We override pkgs.bun rather than hand-rolling the
        # derivation: nixpkgs's bun handles autoPatchelfHook on
        # Linux, codesigning on Darwin, and shell completions. We
        # only swap version + per-platform sources. 25.11's bun
        # uses `rec` scope (not `finalAttrs`), so src must be
        # re-bound explicitly to pick up the new sources map.
        bun-pinned = pkgs.bun.overrideAttrs (old: rec {
          version = "1.3.11";
          passthru = old.passthru // {
            sources = {
              "aarch64-darwin" = pkgs.fetchurl {
                url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-darwin-aarch64.zip";
                hash = "sha256-b1o0Z+2crsR5W/eM1HZQfZ+HDH1XuGyUX8szgSZ3L/w=";
              };
              "x86_64-darwin" = pkgs.fetchurl {
                url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-darwin-x64.zip";
                hash = "sha256-xP4rkkchiwKV8k6JWq7I/uYudEUmeakCa2fqy9YRooY=";
              };
              "x86_64-linux" = pkgs.fetchurl {
                url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-linux-x64.zip";
                hash = "sha256-hhG6k1r4hvBabzh0ChUWAybBXl1dB63vlmEwtEk2B+0=";
              };
              "aarch64-linux" = pkgs.fetchurl {
                url = "https://github.com/oven-sh/bun/releases/download/bun-v${version}/bun-linux-aarch64.zip";
                hash = "sha256-0TlE2hKlPsx0v2pyC9HQTEVVwDjf5CI2U1anvkdpH98=";
              };
            };
          };
          src = passthru.sources.${system}
            or (throw "stats-me bun pin: unsupported system ${system}");
        });

        stats-me = pkgs.callPackage ./default.nix {
          bun = bun-pinned;
        };

        # Bun-runtime zx script wrapping VictoriaMetrics's HTTP query
        # endpoints. Default URL is http://127.0.0.1:8428 — same as
        # VictoriaMetrics's default httpListenAddr — but
        # $STATS_ME_VICTORIA_METRICS_URL
        # or --victoria-metrics-url=URL override that. The HM module
        # sets STATS_ME_VICTORIA_METRICS_URL automatically when
        # stats-me-victoria-metrics is enabled and autowired.
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
