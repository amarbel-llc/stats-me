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

  # Build the JS config blob. statsd's lib/config.js evals the file as
  # `config = <data>`, so the file body must be a bare JS expression.
  # Use `builtins.toJSON` for the merged object — JSON is a subset of
  # the JS-object literal syntax statsd expects, so it round-trips
  # cleanly.
  generatedConfig =
    let
      merged =
        {
          port = cfg.port;
          flushInterval = cfg.flushInterval;
          backends = cfg.backends;
        }
        // cfg.extraConfig;
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
        configured backends (default: console).
      '';
    };

    backends = mkOption {
      type = types.listOf types.str;
      default = [ "./backends/console" ];
      description = ''
        Statsd backend module paths. Resolved relative to the vendored
        statsd tree under the `stats-me` package's
        `share/stats-me/statsd/` directory. Default is the built-in
        console backend, which writes flush summaries to stdout (and
        thus to the launcher-redirected log file).
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
  };

  config = mkIf cfg.enable {
    launchd.agents.stats-me = mkIf pkgs.stdenv.isDarwin darwinAgent;
    systemd.user.services.stats-me = mkIf pkgs.stdenv.isLinux linuxService;
  };
}
