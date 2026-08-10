# Synthetic eval test for the stats-me HM modules. Instantiates the
# modules against a minimal home-manager-shaped config and confirms the
# expected attributes land where the README claims they do.
#
# Run via:
#   nix-instantiate --eval --strict --json -A pass nix/hm/eval-test.nix
# or wrap in a derivation under flake checks.
{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
}:

let
  module = import ./stats-me.nix;
  victoriaMetricsModule = import ./victoria-metrics.nix;

  # Minimal HM-ish stubs: just enough launchd / systemd options for
  # the modules to evaluate. evalModules rejects mixing `options`,
  # `config._module`, and user config in a single anonymous module —
  # split them into three.
  stubOptions = {
    options.launchd.agents = lib.mkOption {
      type = lib.types.attrs;
      default = { };
    };
    options.systemd.user.services = lib.mkOption {
      type = lib.types.attrs;
      default = { };
    };
    # Stub for home-manager's `home.sessionVariables`. In a real HM
    # configuration this is provided by home-manager itself; in the
    # synthetic eval test we only need somewhere for the module's
    # writes to land so we can assert against them.
    options.home.sessionVariables = lib.mkOption {
      type = lib.types.attrs;
      default = { };
    };
  };

  argsModule = {
    config._module.args = { inherit pkgs; };
  };

  evalConfig =
    extraConfig:
    lib.evalModules {
      modules = [
        stubOptions
        argsModule
        module
        extraConfig
      ];
    };

  evalConfigWithVictoriaMetrics =
    extraConfig:
    lib.evalModules {
      modules = [
        stubOptions
        argsModule
        module
        victoriaMetricsModule
        extraConfig
      ];
    };

  victoriaMetricsEnabled =
    (evalConfigWithVictoriaMetrics {
      services.stats-me.enable = true;
      services.stats-me.package = pkgs.hello;
      services.stats-me-victoria-metrics.enable = true;
      services.stats-me-victoria-metrics.package = pkgs.hello;
    }).config;

  enabledDarwin =
    (evalConfig {
      services.stats-me.enable = true;
      services.stats-me.package = pkgs.hello; # any derivation works for eval
    }).config;

  enabledWithExtra =
    (evalConfig {
      services.stats-me.enable = true;
      services.stats-me.package = pkgs.hello;
      services.stats-me.port = 9125;
      services.stats-me.extraConfig = {
        graphiteHost = "localhost";
        graphitePort = 2003;
      };
    }).config;

  # stats-me with the console backend explicitly opted back in
  # (console.enable = true). Used to confirm the opt-in path still
  # wires the console backend after issue #9 made it off-by-default.
  consoleEnabled =
    (evalConfig {
      services.stats-me.enable = true;
      services.stats-me.package = pkgs.hello;
      services.stats-me.console.enable = true;
    }).config;

  # Extract the launcher store path from an evaluated module config,
  # regardless of platform: launchd carries it in ProgramArguments on
  # Darwin, systemd in Service.ExecStart on Linux. `nix flake check`
  # runs on whichever platform the gate host is (Linux on the eng
  # fleet), so the extraction must not assume Darwin. The `.content`
  # unwrap handles the mkIf wrapper the stub `types.attrs` options
  # leave in place (a real home-manager submodule resolves it, the
  # loose stub does not).
  resolveMkIf = v: if v ? content then v.content else v;
  launcherPathOf =
    evaluated: serviceName:
    if pkgs.stdenv.isDarwin then
      builtins.head (resolveMkIf evaluated.launchd.agents.${serviceName}).config.ProgramArguments
    else
      (resolveMkIf evaluated.systemd.user.services.${serviceName}).Service.ExecStart;
in
{
  # The module does not crash when enabled with defaults.
  evalsWithDefaults = enabledDarwin.services.stats-me.enable == true;

  # On darwin, launchd.agents.stats-me is populated.
  darwinAgentDefined = pkgs.stdenv.isDarwin -> (enabledDarwin.launchd.agents ? stats-me);

  # extraConfig flows through.
  extraConfigPropagated = enabledWithExtra.services.stats-me.extraConfig.graphitePort == 2003;

  # Client port-discovery env vars land in home.sessionVariables and
  # track services.stats-me.port (see stats-me-clients(7)).
  statsdHostExported = enabledDarwin.home.sessionVariables.STATSD_HOST == "127.0.0.1";
  statsdPortDefaultExported = enabledDarwin.home.sessionVariables.STATSD_PORT == "8125";
  statsdPortCustomExported = enabledWithExtra.home.sessionVariables.STATSD_PORT == "9125";

  # STATS_ME_VICTORIA_METRICS_* env vars are only exported when the
  # autowire is active (VictoriaMetrics module imported, enabled,
  # autowire not disabled).
  victoriaMetricsUrlExportedWhenAutowired =
    victoriaMetricsEnabled.home.sessionVariables.STATS_ME_VICTORIA_METRICS_URL
    == "http://127.0.0.1:8428";
  victoriaMetricsGraphiteHostExportedWhenAutowired =
    victoriaMetricsEnabled.home.sessionVariables.STATS_ME_VICTORIA_METRICS_GRAPHITE_HOST == "127.0.0.1";
  victoriaMetricsGraphitePortExportedWhenAutowired =
    victoriaMetricsEnabled.home.sessionVariables.STATS_ME_VICTORIA_METRICS_GRAPHITE_PORT == "2003";
  victoriaMetricsUrlAbsentWhenStandalone =
    !(enabledDarwin.home.sessionVariables ? STATS_ME_VICTORIA_METRICS_URL);
  victoriaMetricsGraphiteHostAbsentWhenStandalone =
    !(enabledDarwin.home.sessionVariables ? STATS_ME_VICTORIA_METRICS_GRAPHITE_HOST);

  # Issue #9 prong 1: the console backend is off by default, so a
  # standalone stats-me writes an empty backend list (no per-flush dump
  # into the unbounded log). It is opt-in via console.enable, and the
  # VictoriaMetrics autowire routes graphite WITHOUT re-introducing
  # console.
  standaloneConsoleOff = enabledDarwin.services.stats-me.effectiveBackends == [ ];
  consoleOptInWorks = consoleEnabled.services.stats-me.effectiveBackends == [ "./backends/console" ];
  autowireDropsConsole =
    victoriaMetricsEnabled.services.stats-me.effectiveBackends == [ "./backends/graphite" ];

  # Issue #9 prong 2: the launcher log-size guard is on by default.
  maxLogSizeDefaulted = enabledDarwin.services.stats-me.maxLogSize == 50 * 1024 * 1024;

  # Aggregate pass/fail.
  pass =
    enabledDarwin.services.stats-me.enable
    && (pkgs.stdenv.isDarwin -> (enabledDarwin.launchd.agents ? stats-me))
    && enabledWithExtra.services.stats-me.extraConfig.graphitePort == 2003
    && victoriaMetricsEnabled.services.stats-me-victoria-metrics.enable
    && (pkgs.stdenv.isDarwin -> (victoriaMetricsEnabled.launchd.agents ? stats-me-victoria-metrics))
    && enabledDarwin.home.sessionVariables.STATSD_HOST == "127.0.0.1"
    && enabledDarwin.home.sessionVariables.STATSD_PORT == "8125"
    && enabledWithExtra.home.sessionVariables.STATSD_PORT == "9125"
    &&
      victoriaMetricsEnabled.home.sessionVariables.STATS_ME_VICTORIA_METRICS_URL
      == "http://127.0.0.1:8428"
    &&
      victoriaMetricsEnabled.home.sessionVariables.STATS_ME_VICTORIA_METRICS_GRAPHITE_HOST == "127.0.0.1"
    && victoriaMetricsEnabled.home.sessionVariables.STATS_ME_VICTORIA_METRICS_GRAPHITE_PORT == "2003"
    && !(enabledDarwin.home.sessionVariables ? STATS_ME_VICTORIA_METRICS_URL)
    && !(enabledDarwin.home.sessionVariables ? STATS_ME_VICTORIA_METRICS_GRAPHITE_HOST)
    && enabledDarwin.services.stats-me.effectiveBackends == [ ]
    && consoleEnabled.services.stats-me.effectiveBackends == [ "./backends/console" ]
    && victoriaMetricsEnabled.services.stats-me.effectiveBackends == [ "./backends/graphite" ]
    && enabledDarwin.services.stats-me.maxLogSize == 50 * 1024 * 1024;

  # Launcher script store paths for verification (dump contents,
  # confirm the XDG_LOG_HOME shape, grep for the issue-#9 size guard,
  # confirm the generated config's backend list). Platform-agnostic —
  # see launcherPathOf above.
  launcher = launcherPathOf enabledDarwin "stats-me";
  victoriaMetricsLauncher = launcherPathOf victoriaMetricsEnabled "stats-me-victoria-metrics";
  autowiredStatsMeLauncher = launcherPathOf victoriaMetricsEnabled "stats-me";
}
