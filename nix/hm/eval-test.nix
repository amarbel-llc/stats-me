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
    && !(enabledDarwin.home.sessionVariables ? STATS_ME_VICTORIA_METRICS_GRAPHITE_HOST);

  # Expose the launcher script path so verification can dump its
  # contents and confirm the XDG_LOG_HOME shape. The mkIf wrapper
  # leaves the agent body under `.content` (loose attrs merge).
  launcher =
    let
      agent = enabledDarwin.launchd.agents.stats-me;
      body = if agent ? content then agent.content else agent;
    in
    builtins.head body.config.ProgramArguments;

  # Same idea, but for the VictoriaMetrics launcher.
  victoriaMetricsLauncher =
    let
      agent = victoriaMetricsEnabled.launchd.agents.stats-me-victoria-metrics;
      body = if agent ? content then agent.content else agent;
    in
    builtins.head body.config.ProgramArguments;

  # The autowired stats-me launcher under the both-enabled scenario.
  # Used by verification to confirm the generated config.js inside
  # the launcher contains `graphiteHost` pointing at VictoriaMetrics.
  autowiredStatsMeLauncher =
    let
      agent = victoriaMetricsEnabled.launchd.agents.stats-me;
      body = if agent ? content then agent.content else agent;
    in
    builtins.head body.config.ProgramArguments;
}
