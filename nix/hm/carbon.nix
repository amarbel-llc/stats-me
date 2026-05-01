# home-manager module for `services.stats-me-carbon` — Graphite's
# carbon-cache daemon. Runs alongside services.stats-me and stores
# whisper time-series files. Disabled by default; enable when you want
# real persistence beyond the console-backend log.
#
# This module deliberately ships its OWN service name
# (`stats-me-carbon`, not `services.stats-me.carbon`) so users who
# want carbon for non-stats-me workloads can still use it standalone.
# The wiring between them lives in stats-me.nix, which adds the
# graphite backend automatically when carbon is enabled.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib)
    concatStringsSep
    mkEnableOption
    mkIf
    mkOption
    mkPackageOption
    types
    ;

  cfg = config.services.stats-me-carbon;

  # Carbon's config files live in CONF_DIR. We point that at the
  # generated config dir so users don't end up with stale .pyc files
  # next to mutable configs in $XDG_CONFIG_HOME. The whisper data
  # dir, log dir, and pid dir are runtime-resolved in the launcher
  # script so they fall under XDG paths regardless of where carbon
  # itself was installed.

  # storage-schemas.conf controls retention. Locked at .wsp creation
  # time — change carefully or run whisper-resize.py on existing
  # files. Default keeps 1 month at 10s precision for stats-me's
  # default 10s flushInterval, plus a year of hourly rollups.
  defaultStorageSchemas = ''
    # carbon's own internal metrics
    [carbon]
    pattern = ^carbon\.
    retentions = 60:90d

    # everything else (the stats-me default)
    [default]
    pattern = .*
    retentions = ${cfg.retentions}
  '';

  # storage-aggregation.conf: how higher-precision points roll up to
  # lower-precision archives. Mirrors upstream carbon defaults; users
  # rarely need to change this.
  defaultStorageAggregation = ''
    [min]
    pattern = \.min$
    xFilesFactor = 0.1
    aggregationMethod = min

    [max]
    pattern = \.max$
    xFilesFactor = 0.1
    aggregationMethod = max

    [sum]
    pattern = \.count$
    xFilesFactor = 0
    aggregationMethod = sum

    [default_average]
    pattern = .*
    xFilesFactor = 0.5
    aggregationMethod = average
  '';

  # Render carbon.conf. Only the [cache] section is needed for our
  # use case (we don't run aggregator or relay). Path settings use
  # GRAPHITE_STORAGE_DIR env var to avoid baking absolute paths into
  # the rendered file — the launcher script sets that from XDG.
  carbonConfText = ''
    [cache]
    DATABASE = whisper
    ENABLE_LOGROTATION = False

    # Paths come from $GRAPHITE_STORAGE_DIR, set in the launcher.
    LOCAL_DATA_DIR = %(STORAGE_DIR)s/whisper/
    PID_DIR        = %(STORAGE_DIR)s/run/

    # Limits — generous for personal use, won't OOM a laptop.
    MAX_CACHE_SIZE = inf
    MAX_UPDATES_PER_SECOND = ${toString cfg.maxUpdatesPerSecond}
    MAX_CREATES_PER_MINUTE = 50

    # Listen ports.
    LINE_RECEIVER_INTERFACE = ${cfg.host}
    LINE_RECEIVER_PORT      = ${toString cfg.port}

    # We intentionally don't enable pickle / cache-query / amqp /
    # manhole. Statsd's graphite backend uses the line receiver only.
    ENABLE_UDP_LISTENER = False
    PICKLE_RECEIVER_PORT = 0
    CACHE_QUERY_PORT = 0
  '';

  carbonConfDir = pkgs.runCommand "stats-me-carbon-conf" { } ''
    mkdir -p $out
    cp ${pkgs.writeText "carbon.conf" carbonConfText}            $out/carbon.conf
    cp ${pkgs.writeText "storage-schemas.conf" defaultStorageSchemas}     $out/storage-schemas.conf
    cp ${pkgs.writeText "storage-aggregation.conf" defaultStorageAggregation} $out/storage-aggregation.conf
  '';

  # Resolve the data root path. NOT shell-expanded if the user
  # supplied an absolute path; otherwise XDG_DATA_HOME-relative
  # default expanded by the launcher.
  defaultDataRootExpr = "\${XDG_DATA_HOME:-$HOME/.local/share}/stats-me/carbon";
  dataRootExpr = if cfg.dataDir != null then cfg.dataDir else defaultDataRootExpr;

  defaultLogPathExpr = "\${XDG_LOG_HOME:-$HOME/.local/log}/stats-me/carbon.log";
  logPathExpr = if cfg.logFile != null then cfg.logFile else defaultLogPathExpr;

  launcherText = ''
    set -eu
    : "''${HOME:?HOME must be set}"
    DATA_ROOT="${dataRootExpr}"
    LOG="${logPathExpr}"
    mkdir -p "$DATA_ROOT/whisper" "$DATA_ROOT/run" "$(dirname "$LOG")"
    export GRAPHITE_STORAGE_DIR="$DATA_ROOT"
    exec ${cfg.package}/bin/carbon-cache.py \
      --config=${carbonConfDir}/carbon.conf \
      --nodaemon \
      --logfile=- \
      start \
      >>"$LOG" 2>&1
  '';

  launcher = pkgs.writeShellScript "stats-me-carbon-launch" launcherText;

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
      Description = "stats-me-carbon: Graphite Carbon for stats-me";
      Documentation = "https://github.com/amarbel-llc/stats-me";
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
  options.services.stats-me-carbon = {
    enable = mkEnableOption "stats-me-carbon, Graphite carbon-cache for stats-me";

    # Carbon lives under python3xxPackages.carbon. Pass the full
    # attr path as a list — mkPackageOption resolves it through pkgs
    # and emits the right defaultText for docs. Consumers without
    # python312Packages.carbon in their pkgs MUST set this manually.
    package = mkPackageOption pkgs "carbon" {
      default = [ "python312Packages" "carbon" ];
    };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Interface carbon's plaintext line receiver binds to. Default
        `127.0.0.1` keeps it local-only; set to `0.0.0.0` to accept
        metrics from other hosts.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 2003;
      description = "TCP port for the plaintext line receiver.";
    };

    retentions = mkOption {
      type = types.str;
      default = "10s:1d,1m:30d,1h:3y";
      example = "60s:1d,5m:30d,1h:3y";
      description = ''
        Default whisper retention schema for any metric not matched
        by `[carbon]`. Format is comma-separated `precision:duration`
        pairs. Locked at `.wsp` creation — use whisper-resize.py to
        change retention on existing files.

        Default `10s:1d,1m:30d,1h:3y` matches stats-me's default
        10s flush interval and gives a day of full-resolution data,
        a month of minute-rollups, and three years of hour-rollups.
      '';
    };

    maxUpdatesPerSecond = mkOption {
      type = types.ints.positive;
      default = 500;
      description = ''
        carbon's MAX_UPDATES_PER_SECOND. Caps disk writes; 500 is
        plenty for personal use.
      '';
    };

    dataDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = lib.literalExpression ''"$XDG_DATA_HOME/stats-me/carbon"'';
      description = ''
        Root directory for whisper files and pid files. When `null`,
        the launcher uses `$XDG_DATA_HOME/stats-me/carbon`. When set
        explicitly, the value is used verbatim — environment
        variables are NOT expanded, so pass an absolute path.
      '';
    };

    logFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = lib.literalExpression ''"$XDG_LOG_HOME/stats-me/carbon.log"'';
      description = ''
        Log file path. Defaults to
        `$XDG_LOG_HOME/stats-me/carbon.log` with the spec'd
        `$HOME/.local/log` fallback.
      '';
    };
  };

  config = mkIf cfg.enable {
    launchd.agents.stats-me-carbon = mkIf pkgs.stdenv.isDarwin darwinAgent;
    systemd.user.services.stats-me-carbon = mkIf pkgs.stdenv.isLinux linuxService;
  };
}
