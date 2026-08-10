# home-manager module for `services.stats-me`. Single-instance for v1;
# multi-instance can follow piggy's pattern when needed.
#
# Runs under launchd (Darwin) or systemd-user (Linux) via a launcher
# script that resolves XDG_LOG_HOME at runtime — neither service
# manager expands shell variables in StandardErrorPath / ExecStart, so
# the launcher owns the log path expansion.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    types
    ;

  cfg = config.services.stats-me;

  # VictoriaMetrics autowire: when the user imports
  # nix/hm/victoria-metrics.nix and turns on
  # services.stats-me-victoria-metrics, route stats-me's graphite
  # backend at VictoriaMetrics's host:port automatically. The defensive
  # `(config.services ? stats-me-victoria-metrics)` guard means
  # stats-me still evaluates standalone (when only this module is
  # imported) — we only auto-route if the VictoriaMetrics module surface is
  # actually present.
  victoriaMetricsAutowireEnabled =
    cfg.autowireVictoriaMetrics
    && (config.services ? stats-me-victoria-metrics)
    && config.services.stats-me-victoria-metrics.enable;

  victoriaMetricsCfg = config.services.stats-me-victoria-metrics or null;
  victoriaMetricsGraphiteHost =
    if victoriaMetricsAutowireEnabled then victoriaMetricsCfg.host else null;
  victoriaMetricsGraphitePort =
    if victoriaMetricsAutowireEnabled then victoriaMetricsCfg.graphitePort else null;

  # Effective backend list. The console backend is included only when
  # `cfg.console.enable` is set — it prints a full metrics dump to
  # stdout on every flush, and under the HM launcher's log redirect that
  # grew stats-me.log to 11G with no rotation (issue #9), so it is off by
  # default. The graphite backend is added when we're autowiring
  # VictoriaMetrics AND the user hasn't already listed it in
  # `cfg.backends`. The string check matches statsd's lookup — its
  # backends list is paths relative to the statsd dir.
  effectiveBackends =
    let
      hasGraphite = builtins.any (
        b: b == "./backends/graphite" || b == "./backends/graphite.js"
      ) cfg.backends;
      withConsole = (lib.optional cfg.console.enable "./backends/console") ++ cfg.backends;
    in
    if victoriaMetricsAutowireEnabled && !hasGraphite then
      withConsole ++ [ "./backends/graphite" ]
    else
      withConsole;

  # Build the JS config blob. statsd's lib/config.js evals the file as
  # `config = <data>`, so the file body must be a bare JS expression.
  # Use `builtins.toJSON` for the merged object — JSON is a subset of
  # the JS-object literal syntax statsd expects, so it round-trips
  # cleanly.
  generatedConfig =
    let
      autowired = lib.optionalAttrs victoriaMetricsAutowireEnabled {
        graphiteHost = victoriaMetricsGraphiteHost;
        graphitePort = victoriaMetricsGraphitePort;
      };
      merged = {
        port = cfg.port;
        flushInterval = cfg.flushInterval;
        backends = effectiveBackends;
      }
      // autowired
      // cfg.extraConfig; # explicit user values still win
    in
    pkgs.writeText "stats-me-config.js" (builtins.toJSON merged);

  effectiveConfig = if cfg.configFile != null then cfg.configFile else generatedConfig;

  # Default log file expression. The launcher does the XDG fallback in
  # bash because systemd's StandardOutput=file: and launchd's
  # StandardErrorPath won't expand env vars. When `cfg.logFile` is set
  # explicitly, it's used as-is — no shell expansion of user input.
  defaultLogPathExpr = "\${XDG_LOG_HOME:-$HOME/.local/log}/stats-me/stats-me.log";
  logPathExpr = if cfg.logFile != null then cfg.logFile else defaultLogPathExpr;

  launcherText = ''
    set -eu
    : "''${HOME:?HOME must be set}"
    LOG="${logPathExpr}"
    mkdir -p "$(dirname "$LOG")"
  ''
  + lib.optionalString (cfg.maxLogSize != null) ''
    # Belt-and-suspenders (issue #9): cap the log at (re)start so a
    # chatty backend can't refill the disk between restarts. wc -c is
    # portable across GNU/BSD; the daemon isn't running yet here, so an
    # in-place truncate is safe. Restart-granularity only — a floor
    # guard, not continuous rotation.
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt ${toString cfg.maxLogSize} ]; then
      : > "$LOG"
    fi
  ''
  + ''
    exec ${cfg.package}/bin/stats-me ${effectiveConfig} >>"$LOG" 2>&1
  '';

  launcher = pkgs.writeShellScript "stats-me-launch" launcherText;

  darwinAgent = {
    enable = true;
    config = {
      ProgramArguments = [ "${launcher}" ];
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
    };
  };

  linuxService = {
    Unit = {
      Description = "stats-me: personal statsd";
      Documentation = "https://code.linenisgreat.com/stats-me";
    };
    Service = {
      ExecStart = "${launcher}";
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install = {
      WantedBy = [ "default.target" ];
    };
  };
in
{
  options.services.stats-me = {
    enable = mkEnableOption "stats-me, a personal statsd";

    # mkPackageOption defaults to `pkgs.stats-me`. Most consumers will
    # not have stats-me in their nixpkgs and MUST set
    # `package = inputs.stats-me.packages.${system}.default`. There's
    # no silent fallback.
    package = mkPackageOption pkgs "stats-me" { };

    port = mkOption {
      type = types.port;
      default = 8125;
      description = "UDP port the statsd daemon listens on.";
    };

    flushInterval = mkOption {
      type = types.ints.positive;
      default = 10000;
      description = ''
        Flush interval in milliseconds. Each flush triggers the
        configured backends (none by default — enable
        {option}`services.stats-me.console.enable` or the VictoriaMetrics
        graphite autowire).
      '';
    };

    autowireVictoriaMetrics = mkOption {
      type = types.bool;
      default = true;
      description = ''
        When `true` (default) and
        `services.stats-me-victoria-metrics.enable` is also `true`,
        stats-me automatically:

          1. Adds `./backends/graphite` to {option}`backends` (if it
             isn't already there).
          2. Sets `graphiteHost` / `graphitePort` in the generated
             config to point at the VictoriaMetrics daemon's graphite-listener
             host:port.
          3. Exports `STATS_ME_VICTORIA_METRICS_URL`,
             `STATS_ME_VICTORIA_METRICS_GRAPHITE_HOST`, and
             `STATS_ME_VICTORIA_METRICS_GRAPHITE_PORT` via
             {option}`home.sessionVariables` so client tooling
             (`stats-me-query`, downstream agents, direct graphite
             pushers) auto-discovers the local VictoriaMetrics
             endpoints. See *stats-me-victoria-metrics-clients(7)*.

        Set to `false` to wire the graphite backend manually via
        {option}`backends` and {option}`extraConfig`. The autowire
        loses to anything in {option}`extraConfig`, so explicit
        overrides always win.

        No effect if `services.stats-me-victoria-metrics` is not
        enabled or the VictoriaMetrics module is not imported at all — stats-me
        still works standalone (quiet by default; set
        {option}`services.stats-me.console.enable` for a per-flush stdout
        dump).
      '';
    };

    console.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to run the statsd console backend, which prints a full
        metrics dump to stdout — and thus into the launcher-redirected
        log file — on every flush. Off by default: the per-flush dump is
        unbounded and grew stats-me.log to 11G over a few weeks of
        continuous running, filling the disk (issue #9). Turn it on only
        for interactive debugging; durable metrics belong in
        VictoriaMetrics via the graphite backend.
      '';
    };

    backends = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Additional statsd backend module paths, resolved relative to the
        vendored statsd tree under the `stats-me` package's
        `share/stats-me/statsd/` directory. Empty by default: the console
        backend is gated behind {option}`services.stats-me.console.enable`
        (issue #9), and the graphite backend is added automatically by
        the VictoriaMetrics autowire (see
        {option}`services.stats-me.autowireVictoriaMetrics`). Use this
        only for extra or custom backends.
      '';
    };

    effectiveBackends = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      default = effectiveBackends;
      description = ''
        The backend list actually written to the generated statsd
        config, after gating the console backend behind
        {option}`services.stats-me.console.enable` and adding the
        graphite backend for the VictoriaMetrics autowire. Read-only;
        exposed for introspection and the module eval-test.
      '';
    };

    extraConfig = mkOption {
      type = types.attrs;
      default = { };
      description = ''
        Extra fields merged into the generated statsd config. Loses
        to {option}`configFile` if both are set. Use this for
        backend-specific options (e.g.
        `{ graphiteHost = "localhost"; graphitePort = 2003; }`).
      '';
    };

    configFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Path to a complete statsd config file. When set, this replaces
        the generated config wholesale and {option}`port` /
        {option}`flushInterval` / {option}`backends` /
        {option}`extraConfig` are ignored. Use only when the option
        surface above isn't expressive enough.
      '';
    };

    logFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = lib.literalExpression ''"$XDG_LOG_HOME/stats-me/stats-me.log"'';
      description = ''
        Log file path. When `null` (default), the launcher writes to
        `$XDG_LOG_HOME/stats-me/stats-me.log`, with the XDG-spec
        fallback to `$HOME/.local/log/stats-me/stats-me.log` if
        `$XDG_LOG_HOME` is unset. When set explicitly, the value is
        used verbatim — environment variables in the user-supplied
        string are NOT expanded, so pass an absolute path.
      '';
    };

    maxLogSize = mkOption {
      type = types.nullOr types.ints.positive;
      default = 50 * 1024 * 1024;
      example = null;
      description = ''
        Belt-and-suspenders log-size cap, in bytes (default 50 MiB).
        Before (re)starting the daemon, the launcher truncates the log
        file in place if it already exceeds this size, so a chatty
        backend can't fill the disk the way the console backend did in
        issue #9. This runs only at (re)start — a floor guard at restart
        granularity, not continuous rotation. Set to `null` to disable
        the guard.
      '';
    };
  };

  config = mkIf cfg.enable {
    launchd.agents.stats-me = mkIf pkgs.stdenv.isDarwin darwinAgent;
    systemd.user.services.stats-me = mkIf pkgs.stdenv.isLinux linuxService;

    # Client port-discovery: export the de-facto statsd ecosystem env
    # vars so client libraries (hot-shots, python-statsd, cadence, ...)
    # auto-detect the endpoint with no per-app configuration. See
    # stats-me-clients(7) for the resolution contract; in particular,
    # STATSD_HOST is always loopback regardless of the daemon's bind
    # address, since this module ships a per-user statsd.
    #
    # STATS_ME_VICTORIA_METRICS_* are exported only when the
    # VictoriaMetrics autowire is active
    # (`victoriaMetricsAutowireEnabled`) — i.e. the VictoriaMetrics
    # module is imported, enabled, and the user hasn't opted out
    # via autowireVictoriaMetrics = false. That keeps the env vars
    # aligned with where stats-me is actually flushing.
    #
    # _URL is the HTTP query endpoint (PromQL, /api/v1/export, etc.).
    # _GRAPHITE_HOST / _GRAPHITE_PORT are the graphite-plaintext
    # ingestion endpoint, for clients that want to push to
    # VictoriaMetrics directly without going through stats-me's flush
    # cycle. See stats-me-victoria-metrics-clients(7) for the contract.
    home.sessionVariables = {
      STATSD_HOST = "127.0.0.1";
      STATSD_PORT = toString cfg.port;
    }
    // lib.optionalAttrs victoriaMetricsAutowireEnabled {
      STATS_ME_VICTORIA_METRICS_URL = "http://${victoriaMetricsCfg.host}:${toString victoriaMetricsCfg.httpPort}";
      STATS_ME_VICTORIA_METRICS_GRAPHITE_HOST = victoriaMetricsCfg.host;
      STATS_ME_VICTORIA_METRICS_GRAPHITE_PORT = toString victoriaMetricsCfg.graphitePort;
    };
  };
}
