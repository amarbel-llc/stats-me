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
  vmModule = import ./victoriametrics.nix;

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

  evalConfigWithVm =
    extraConfig:
    lib.evalModules {
      modules = [
        stubOptions
        argsModule
        module
        vmModule
        extraConfig
      ];
    };

  vmEnabled =
    (evalConfigWithVm {
      services.stats-me.enable = true;
      services.stats-me.package = pkgs.hello;
      services.stats-me-vm.enable = true;
      services.stats-me-vm.package = pkgs.hello;
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
  darwinAgentDefined =
    pkgs.stdenv.isDarwin -> (enabledDarwin.launchd.agents ? stats-me);

  # extraConfig flows through.
  extraConfigPropagated = enabledWithExtra.services.stats-me.extraConfig.graphitePort == 2003;

  # Aggregate pass/fail.
  pass =
    enabledDarwin.services.stats-me.enable
    && (pkgs.stdenv.isDarwin -> (enabledDarwin.launchd.agents ? stats-me))
    && enabledWithExtra.services.stats-me.extraConfig.graphitePort == 2003
    && vmEnabled.services.stats-me-vm.enable
    && (pkgs.stdenv.isDarwin -> (vmEnabled.launchd.agents ? stats-me-vm));

  # Expose the launcher script path so verification can dump its
  # contents and confirm the XDG_LOG_HOME shape. The mkIf wrapper
  # leaves the agent body under `.content` (loose attrs merge).
  launcher =
    let
      agent = enabledDarwin.launchd.agents.stats-me;
      body = if agent ? content then agent.content else agent;
    in
    builtins.head body.config.ProgramArguments;

  # Same idea, but for the VM launcher.
  vmLauncher =
    let
      agent = vmEnabled.launchd.agents.stats-me-vm;
      body = if agent ? content then agent.content else agent;
    in
    builtins.head body.config.ProgramArguments;

  # The autowired stats-me launcher under the both-enabled scenario.
  # Used by verification to confirm the generated config.js inside
  # the launcher contains `graphiteHost` pointing at VM.
  autowiredStatsMeLauncher =
    let
      agent = vmEnabled.launchd.agents.stats-me;
      body = if agent ? content then agent.content else agent;
    in
    builtins.head body.config.ProgramArguments;
}
