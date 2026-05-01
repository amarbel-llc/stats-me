# stats-me — wrapper that invokes a vendored statsd via Bun.
#
# Inputs come from callPackage. The wrapper:
#   1. Copies the vendored statsd tree into $out/share/stats-me/statsd
#   2. Copies the default config into $out/share/stats-me/default-config.js
#   3. Emits $out/bin/stats-me, a tiny shell wrapper that:
#        - cd's into the statsd tree (statsd's `require()` calls are
#          relative; running from elsewhere breaks backend loading)
#        - exec's `${bun}/bin/bun stats.js <config>` where <config> is
#          $1 if set, else the bundled default-config.js
{
  lib,
  stdenvNoCC,
  bun,
  makeWrapper,
}:

stdenvNoCC.mkDerivation {
  pname = "stats-me";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./vendor/statsd
      ./config
    ];
  };

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/stats-me
    cp -r vendor/statsd $out/share/stats-me/statsd
    cp config/default-config.js $out/share/stats-me/default-config.js

    # Use a hand-written wrapper instead of makeWrapper: we need the
    # `cd` into the statsd dir AND argument forwarding, which
    # makeWrapper's --add-flags / --run cannot express together.
    cat > $out/bin/stats-me <<EOF
    #!${stdenvNoCC.shell}
    set -eu
    config="\''${1:-$out/share/stats-me/default-config.js}"
    cd "$out/share/stats-me/statsd"
    exec "${bun}/bin/bun" "$out/share/stats-me/statsd/stats.js" "\$config"
    EOF
    chmod +x $out/bin/stats-me

    runHook postInstall
  '';

  meta = {
    description = "stats-me: personal statsd, run under Bun";
    homepage = "https://github.com/amarbel-llc/stats-me";
    license = lib.licenses.mit;
    mainProgram = "stats-me";
    platforms = lib.platforms.darwin ++ lib.platforms.linux;
  };
}
