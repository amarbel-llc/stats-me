# home-manager module for `services.stats-me-vm` — VictoriaMetrics
# as a personal time-series store for stats-me. Single Go binary,
# accepts statsd-via-graphite over TCP/UDP on port 2003 by default,
# stores data natively (no whisper files, no retention-locked-at-
# creation footgun), exposes PromQL via HTTP `/api/v1/query` on port
# 8428.
#
# Disabled by default; enable when you want persistence beyond the
# console-backend log.
#
# Like services.stats-me-carbon used to, this module ships its own
# service name (stats-me-vm) so users who want VM standalone can
# opt in without dragging stats-me along. The wiring between them
# lives in stats-me.nix's autowireVictoriaMetrics option.
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

  cfg = config.services.stats-me-vm;

  # Resolve runtime paths in the launcher script. systemd's
  # ExecStart and launchd's ProgramArguments don't expand env vars,
  # so we own resolution in bash. Same pattern as stats-me.nix.
  defaultDataDirExpr = "\${XDG_DATA_HOME:-$HOME/.local/share}/stats-me/vm";
  dataDirExpr = if cfg.dataDir != null then cfg.dataDir else defaultDataDirExpr;

  defaultLogPathExpr = "\${XDG_LOG_HOME:-$HOME/.local/log}/stats-me/vm.log";
  logPathExpr = if cfg.logFile != null then cfg.logFile else defaultLogPathExpr;

  graphiteAddr = "${cfg.host}:${toString cfg.graphitePort}";
  httpAddr = "${cfg.host}:${toString cfg.httpPort}";

  launcherText = ''
    set -eu
    : "''${HOME:?HOME must be set}"
    DATA_DIR="${dataDirExpr}"
    LOG="${logPathExpr}"
    mkdir -p "$DATA_DIR" "$(dirname "$LOG")"
    exec ${cfg.package}/bin/victoria-metrics \
      -graphiteListenAddr=${graphiteAddr} \
      -httpListenAddr=${httpAddr} \
      -storageDataPath="$DATA_DIR" \
      -retentionPeriod=${cfg.retentionPeriod} \
      -loggerOutput=stdout \
      ${lib.escapeShellArgs cfg.extraArgs} \
      >>"$LOG" 2>&1
  '';

  launcher = pkgs.writeShellScript "stats-me-vm-launch" launcherText;

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
      Description = "stats-me-vm: VictoriaMetrics for stats-me";
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
  options.services.stats-me-vm = {
    enable = mkEnableOption "stats-me-vm, VictoriaMetrics for stats-me";

    package = mkPackageOption pkgs "victoriametrics" { };

    host = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = ''
        Interface VictoriaMetrics binds to for both the graphite
        receiver and the HTTP query endpoint. Default `127.0.0.1`
        keeps both local-only.
      '';
    };

    graphitePort = mkOption {
      type = types.port;
      default = 2003;
      description = ''
        Port for the graphite plaintext receiver (TCP+UDP). statsd's
        graphite backend points here. Default 2003 matches the
        upstream graphite/carbon convention.
      '';
    };

    httpPort = mkOption {
      type = types.port;
      default = 8428;
      description = ''
        Port for the HTTP query endpoint. PromQL via
        `GET /api/v1/query`, Prometheus exposition at
        `/metrics`, etc. Default 8428 matches VM's documented
        default.
      '';
    };

    retentionPeriod = mkOption {
      type = types.str;
      default = "30d";
      example = "1y";
      description = ''
        How long to retain ingested data. VM accepts `s` / `h` /
        `d` / `w` / `M` / `y` suffixes. Default `30d` is a sensible
        personal-stats default. VM's minimum is `24h`. Unlike
        Whisper, VM does NOT lock retention at creation — you can
        change this at any time and the next compaction picks it up.
      '';
    };

    dataDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = lib.literalExpression ''"$XDG_DATA_HOME/stats-me/vm"'';
      description = ''
        Directory for VM's storage data. When `null`, the launcher
        uses `$XDG_DATA_HOME/stats-me/vm`. When set explicitly,
        the value is used verbatim — environment variables are NOT
        expanded, so pass an absolute path.
      '';
    };

    logFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = lib.literalExpression ''"$XDG_LOG_HOME/stats-me/vm.log"'';
      description = ''
        Log file path. Defaults to `$XDG_LOG_HOME/stats-me/vm.log`
        with the spec'd `$HOME/.local/log` fallback.
      '';
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "-search.maxQueryLen=32KB" ];
      description = ''
        Extra command-line flags passed verbatim to victoria-metrics.
        Use this for any of VM's hundreds of options not covered by
        the typed surface above. Run `victoria-metrics -help` to
        see what's available.
      '';
    };
  };

  config = mkIf cfg.enable {
    launchd.agents.stats-me-vm = mkIf pkgs.stdenv.isDarwin darwinAgent;
    systemd.user.services.stats-me-vm = mkIf pkgs.stdenv.isLinux linuxService;
  };
}
